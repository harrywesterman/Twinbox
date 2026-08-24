#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_MANAGER_WEB_DIR="${REPO_ROOT}/manager-web"
DEFAULT_CONFIG_FILE="${REPO_ROOT}/.env.vm-preview.local"
CONFIG_FILE="${TWINBOX_VM_PREVIEW_CONFIG_FILE:-${DEFAULT_CONFIG_FILE}}"

SSH_TARGET=""
REMOTE_DIR=""
REMOTE_PREVIEW_DIR=""
IMAGE_TAG=""
PASSWORD=""

SSH_CMD=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target user@host] [--remote-dir /opt/twinbox] [--image-tag latest]

Preview the local manager-web on a running Management VM without committing or
pushing first. The script syncs only ./manager-web to a temporary directory on
the VM, builds the manager-web image there, and recreates only the manager-web
container.

Configuration can come from ${CONFIG_FILE} or these environment variables:
  TWINBOX_VM_PREVIEW_TARGET
  TWINBOX_VM_PREVIEW_REMOTE_DIR
  TWINBOX_VM_PREVIEW_REMOTE_TMP
  TWINBOX_VM_PREVIEW_IMAGE_TAG
  TWINBOX_VM_PREVIEW_PASSWORD

If the VM uses a non-default TWINBOX_IMAGE_TAG in its .env, pass the same tag
here via --image-tag or TWINBOX_VM_PREVIEW_IMAGE_TAG.
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
  local env_target="${TWINBOX_VM_PREVIEW_TARGET-}"
  local env_remote_dir="${TWINBOX_VM_PREVIEW_REMOTE_DIR-}"
  local env_remote_tmp="${TWINBOX_VM_PREVIEW_REMOTE_TMP-}"
  local env_image_tag="${TWINBOX_VM_PREVIEW_IMAGE_TAG-}"
  local env_password="${TWINBOX_VM_PREVIEW_PASSWORD-}"

  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    set -a
    . "${CONFIG_FILE}"
    set +a
  fi

  if [[ -n "${env_target}" ]]; then
    TWINBOX_VM_PREVIEW_TARGET="${env_target}"
  fi
  if [[ -n "${env_remote_dir}" ]]; then
    TWINBOX_VM_PREVIEW_REMOTE_DIR="${env_remote_dir}"
  fi
  if [[ -n "${env_remote_tmp}" ]]; then
    TWINBOX_VM_PREVIEW_REMOTE_TMP="${env_remote_tmp}"
  fi
  if [[ -n "${env_image_tag}" ]]; then
    TWINBOX_VM_PREVIEW_IMAGE_TAG="${env_image_tag}"
  fi
  if [[ -n "${env_password}" ]]; then
    TWINBOX_VM_PREVIEW_PASSWORD="${env_password}"
  fi

  SSH_TARGET="${TWINBOX_VM_PREVIEW_TARGET:-}"
  REMOTE_DIR="${TWINBOX_VM_PREVIEW_REMOTE_DIR:-}"
  REMOTE_PREVIEW_DIR="${TWINBOX_VM_PREVIEW_REMOTE_TMP:-/tmp/twinbox-manager-web-preview}"
  IMAGE_TAG="${TWINBOX_VM_PREVIEW_IMAGE_TAG:-sha-a8448c8}"
  PASSWORD="${TWINBOX_VM_PREVIEW_PASSWORD:-}"
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
      --remote-preview-dir)
        [[ $# -ge 2 ]] || die "--remote-preview-dir requires a value"
        REMOTE_PREVIEW_DIR="$2"
        shift 2
        ;;
      --image-tag)
        [[ $# -ge 2 ]] || die "--image-tag requires a value"
        IMAGE_TAG="$2"
        shift 2
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
  for cmd in bash ssh tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done

  if [[ -n "${PASSWORD}" ]]; then
    command -v sshpass >/dev/null 2>&1 || die "TWINBOX_VM_PREVIEW_PASSWORD requires sshpass to be installed locally."
  fi
}

validate_inputs() {
  [[ -d "${LOCAL_MANAGER_WEB_DIR}" ]] || die "Local manager-web directory not found: ${LOCAL_MANAGER_WEB_DIR}"
  [[ -f "${LOCAL_MANAGER_WEB_DIR}/Dockerfile" ]] || die "Local manager-web Dockerfile not found."
  [[ -n "${SSH_TARGET}" ]] || die "Set TWINBOX_VM_PREVIEW_TARGET in ${CONFIG_FILE} or pass --target."
  [[ -n "${REMOTE_DIR}" ]] || die "Set TWINBOX_VM_PREVIEW_REMOTE_DIR in ${CONFIG_FILE} or pass --remote-dir."
  [[ -n "${IMAGE_TAG}" ]] || die "Image tag must not be empty."
}

setup_ssh_cmd() {
  SSH_CMD=()

  if [[ -n "${PASSWORD}" ]]; then
    SSH_CMD+=(sshpass -p "${PASSWORD}")
    SSH_CMD+=(ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password)
  else
    SSH_CMD+=(ssh)
  fi

  SSH_CMD+=(-o StrictHostKeyChecking=accept-new)
}

run_remote() {
  local remote_cmd="$1"
  "${SSH_CMD[@]}" "${SSH_TARGET}" "${remote_cmd}"
}

upload_preview_tree() {
  local quoted_preview_dir=""

  quoted_preview_dir="$(quote_for_sh "${REMOTE_PREVIEW_DIR}")"

  tar -C "${REPO_ROOT}" -czf - manager-web \
    | "${SSH_CMD[@]}" "${SSH_TARGET}" "rm -rf ${quoted_preview_dir} && mkdir -p ${quoted_preview_dir} && tar -xzf - -C ${quoted_preview_dir}"
}

build_and_restart_remote() {
  local quoted_remote_dir=""
  local quoted_preview_dir=""
  local quoted_image_tag=""

  quoted_remote_dir="$(quote_for_sh "${REMOTE_DIR}")"
  quoted_preview_dir="$(quote_for_sh "${REMOTE_PREVIEW_DIR}")"
  quoted_image_tag="$(quote_for_sh "${IMAGE_TAG}")"

  run_remote "
    set -euo pipefail
    cd ${quoted_remote_dir}
    docker build -t ghcr.io/harrywesterman/twinbox-manager-web:${quoted_image_tag} ${quoted_preview_dir}/manager-web
    docker compose up -d --no-deps --force-recreate manager-web
    docker compose ps manager-web
    rm -rf ${quoted_preview_dir}
  "
}

main() {
  load_config
  parse_args "$@"
  check_deps
  validate_inputs
  setup_ssh_cmd
  upload_preview_tree
  build_and_restart_remote

  echo "Preview deployed to ${SSH_TARGET}"
  echo "Remote repo untouched at ${REMOTE_DIR}"
  echo "Open: http://${SSH_TARGET#*@}:3000"
}

main "$@"
