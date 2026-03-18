#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_WIZARD_PATH="${REPO_ROOT}/wizard/setup-wizard.sh"
DEFAULT_CONFIG_FILE="${REPO_ROOT}/.env.wizard.local"
CONFIG_FILE="${WIZARD_DEV_CONFIG_FILE:-${DEFAULT_CONFIG_FILE}}"
DEFAULT_REMOTE_DIR="/root/twinbox-dev"

SSH_TARGET=""
REMOTE_DIR=""
REMOTE_SCRIPT_PATH=""
DEBUG_MODE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target root@host] [--remote-dir /path] [--debug]

Uploads the local Proxmox wizard to a remote host over SSH and runs it there
with an interactive TTY, so whiptail keeps working.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

quote_for_sh() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

load_config() {
  local env_target="${WIZARD_DEV_SSH_TARGET-}"
  local env_remote_dir="${WIZARD_DEV_REMOTE_DIR-}"

  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    set -a
    . "${CONFIG_FILE}"
    set +a
  fi

  if [[ -n "${env_target}" ]]; then
    WIZARD_DEV_SSH_TARGET="${env_target}"
  fi
  if [[ -n "${env_remote_dir}" ]]; then
    WIZARD_DEV_REMOTE_DIR="${env_remote_dir}"
  fi

  SSH_TARGET="${WIZARD_DEV_SSH_TARGET:-}"
  REMOTE_DIR="${WIZARD_DEV_REMOTE_DIR:-${DEFAULT_REMOTE_DIR}}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || die "--target requires a value"
        SSH_TARGET="$2"
        shift 2
        ;;
      --remote-dir)
        [[ $# -ge 2 ]] || die "--remote-dir requires a value"
        REMOTE_DIR="$2"
        shift 2
        ;;
      --debug)
        DEBUG_MODE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

check_deps() {
  local cmd=""
  for cmd in bash ssh scp; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

validate_inputs() {
  [[ -f "${LOCAL_WIZARD_PATH}" ]] || die "Local wizard not found: ${LOCAL_WIZARD_PATH}"
  [[ -n "${SSH_TARGET}" ]] || die "Set WIZARD_DEV_SSH_TARGET in .env.wizard.local or pass --target."
}

run_local_checks() {
  bash -n "${LOCAL_WIZARD_PATH}"
}

upload_and_run_remote() {
  local quoted_remote_dir=""
  local quoted_remote_script=""
  local remote_bash="bash"

  REMOTE_SCRIPT_PATH="${REMOTE_DIR%/}/setup-wizard.sh"
  quoted_remote_dir="$(quote_for_sh "${REMOTE_DIR}")"
  quoted_remote_script="$(quote_for_sh "${REMOTE_SCRIPT_PATH}")"

  if [[ "${DEBUG_MODE}" -eq 1 ]]; then
    remote_bash="bash -x"
  fi

  ssh -n "${SSH_TARGET}" "mkdir -p ${quoted_remote_dir}"
  scp -q "${LOCAL_WIZARD_PATH}" "${SSH_TARGET}:${REMOTE_SCRIPT_PATH}" </dev/null
  ssh -tt "${SSH_TARGET}" "chmod +x ${quoted_remote_script} && TERM=xterm-256color ${remote_bash} ${quoted_remote_script}"
}

report_retained_remote_copy() {
  local exit_code=$?

  if [[ "${exit_code}" -ne 0 && -n "${SSH_TARGET}" && -n "${REMOTE_SCRIPT_PATH}" ]]; then
    echo "Remote wizard copy retained at ${SSH_TARGET}:${REMOTE_SCRIPT_PATH}" >&2
  fi

  exit "${exit_code}"
}

main() {
  trap report_retained_remote_copy EXIT

  load_config
  parse_args "$@"
  check_deps
  validate_inputs
  run_local_checks
  upload_and_run_remote

  echo "Remote wizard copy: ${SSH_TARGET}:${REMOTE_SCRIPT_PATH}"
}

main "$@"
