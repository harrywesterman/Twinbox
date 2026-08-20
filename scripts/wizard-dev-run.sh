#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_WIZARD_PATH="${REPO_ROOT}/wizard/setup-wizard.sh"
WIZARD_UPLOAD_PATH="${LOCAL_WIZARD_PATH}"
DEFAULT_CONFIG_FILE="${REPO_ROOT}/.env.vm-preview.local"
CONFIG_FILE="${WIZARD_DEV_CONFIG_FILE:-${DEFAULT_CONFIG_FILE}}"
DEFAULT_REMOTE_DIR="/tmp/twinbox-dev"
GHCR_OWNER=""
GITHUB_REPO=""
IMAGE_TAG_WAIT_TIMEOUT_SECONDS=""
IMAGE_TAG_WAIT_INTERVAL_SECONDS=""
WIZARD_SOURCE=""
MANAGER_IMAGE_REPOSITORIES=(
  "twinbox-manager-api"
  "twinbox-manager-worker"
  "twinbox-manager-web"
)

SSH_TARGET=""
REMOTE_DIR=""
REMOTE_SCRIPT_PATH=""
DEBUG_MODE=0
TMP_DIR=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target user@host] [--remote-dir /path] [--debug]

Uploads the current Proxmox bootstrap wizard from origin/main and runs it as
root on the remote host with an interactive TTY, so whiptail keeps working. The
uploaded copy is patched with the matching published manager image tag before
it is sent. Set WIZARD_DEV_SOURCE=local to test unpushed local wizard changes.
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
  local env_ghcr_owner="${WIZARD_DEV_GHCR_OWNER-}"
  local env_github_repo="${WIZARD_DEV_GITHUB_REPO-}"
  local env_image_tag_wait_timeout="${WIZARD_DEV_IMAGE_TAG_WAIT_TIMEOUT_SECONDS-}"
  local env_image_tag_wait_interval="${WIZARD_DEV_IMAGE_TAG_WAIT_INTERVAL_SECONDS-}"
  local env_wizard_source="${WIZARD_DEV_SOURCE-}"

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
  if [[ -n "${env_ghcr_owner}" ]]; then
    WIZARD_DEV_GHCR_OWNER="${env_ghcr_owner}"
  fi
  if [[ -n "${env_github_repo}" ]]; then
    WIZARD_DEV_GITHUB_REPO="${env_github_repo}"
  fi
  if [[ -n "${env_image_tag_wait_timeout}" ]]; then
    WIZARD_DEV_IMAGE_TAG_WAIT_TIMEOUT_SECONDS="${env_image_tag_wait_timeout}"
  fi
  if [[ -n "${env_image_tag_wait_interval}" ]]; then
    WIZARD_DEV_IMAGE_TAG_WAIT_INTERVAL_SECONDS="${env_image_tag_wait_interval}"
  fi
  if [[ -n "${env_wizard_source}" ]]; then
    WIZARD_DEV_SOURCE="${env_wizard_source}"
  fi

  SSH_TARGET="${WIZARD_DEV_SSH_TARGET:-}"
  REMOTE_DIR="${WIZARD_DEV_REMOTE_DIR:-${DEFAULT_REMOTE_DIR}}"
  GHCR_OWNER="${WIZARD_DEV_GHCR_OWNER:-harrywesterman}"
  GITHUB_REPO="${WIZARD_DEV_GITHUB_REPO:-harrywesterman/Twinbox}"
  IMAGE_TAG_WAIT_TIMEOUT_SECONDS="${WIZARD_DEV_IMAGE_TAG_WAIT_TIMEOUT_SECONDS:-1200}"
  IMAGE_TAG_WAIT_INTERVAL_SECONDS="${WIZARD_DEV_IMAGE_TAG_WAIT_INTERVAL_SECONDS:-10}"
  WIZARD_SOURCE="${WIZARD_DEV_SOURCE:-origin-main}"
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
  for cmd in bash curl git python3 ssh scp; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

validate_inputs() {
  [[ -f "${LOCAL_WIZARD_PATH}" ]] || die "Local wizard not found: ${LOCAL_WIZARD_PATH}"
  [[ -n "${SSH_TARGET}" ]] || die "Set WIZARD_DEV_SSH_TARGET=root@<proxmox-ip> in .env.vm-preview.local, or pass WIZARD_DEV_SSH_TARGET as env var."
}

run_local_checks() {
  bash -n "${WIZARD_UPLOAD_PATH}"
}

extract_wizard_image_tag() {
  awk -F'"' '/TWINBOX_IMAGE_TAG="(latest|sha-[0-9a-f]{7})"/ { print $2; exit }' "$1"
}

ensure_tmp_dir() {
  TMP_DIR="${TMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/twinbox-wizard-dev.XXXXXX")}"
}

refresh_origin_main() {
  git -C "$REPO_ROOT" fetch --quiet origin main:refs/remotes/origin/main
}

origin_main_sha() {
  git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null
}

write_origin_wizard_source() {
  local source_path=""

  ensure_tmp_dir
  source_path="${TMP_DIR}/setup-wizard.origin-main.sh"
  git -C "$REPO_ROOT" show origin/main:wizard/setup-wizard.sh >"$source_path"
  printf '%s\n' "$source_path"
}

write_wizard_with_image_tag() {
  local source_path="$1"
  local image_tag="$2"

  ensure_tmp_dir
  WIZARD_UPLOAD_PATH="${TMP_DIR}/setup-wizard.sh"
  python3 - "$source_path" "$WIZARD_UPLOAD_PATH" "$image_tag" <<'PY'
import pathlib
import re
import sys

source_path = pathlib.Path(sys.argv[1])
target_path = pathlib.Path(sys.argv[2])
image_tag = sys.argv[3]

content = source_path.read_text(encoding="utf-8")
content, count = re.subn(
    r'TWINBOX_IMAGE_TAG="(?:latest|sha-[0-9a-f]{7})"',
    f'TWINBOX_IMAGE_TAG="{image_tag}"',
    content,
)
if count == 0:
    raise SystemExit("no TWINBOX_IMAGE_TAG assignment found")
target_path.write_text(content, encoding="utf-8")
PY
  chmod +x "$WIZARD_UPLOAD_PATH"
}

commit_is_image_bump() {
  git -C "$REPO_ROOT" log -1 --format=%s "$1" 2>/dev/null \
    | grep -Eq '^chore: bump image tags to sha-[0-9a-f]{7} \[skip ci\]$'
}

ghcr_token() {
  local repository="$1"

  curl --fail --silent --show-error \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${GHCR_OWNER}/${repository}:pull" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("token", ""))'
}

manager_images_exist() {
  local image_tag="$1"
  local repository=""
  local token=""

  for repository in "${MANAGER_IMAGE_REPOSITORIES[@]}"; do
    token="$(ghcr_token "$repository")"
    [[ -n "$token" ]] || return 1
    curl --fail --silent \
      --output /dev/null \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/${GHCR_OWNER}/${repository}/manifests/${image_tag}" \
      || return 1
  done
}

wait_for_manager_images() {
  local image_tag="$1"
  local deadline=$((SECONDS + IMAGE_TAG_WAIT_TIMEOUT_SECONDS))

  echo "Waiting for manager images ${image_tag} to be published" >&2
  while ((SECONDS < deadline)); do
    if manager_images_exist "$image_tag"; then
      echo "Manager images ${image_tag} are published" >&2
      return 0
    fi
    sleep "$IMAGE_TAG_WAIT_INTERVAL_SECONDS"
  done

  return 1
}

ci_run_status_for_commit() {
  local commit_sha="$1"
  local api_url="https://api.github.com/repos/${GITHUB_REPO}/actions/runs?head_sha=${commit_sha}&per_page=10"

  curl --silent --show-error --max-time 10 "$api_url" 2>/dev/null \
    | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if not isinstance(data, dict) or "workflow_runs" not in data:
    sys.exit(0)

for run in data["workflow_runs"]:
    if run.get("name") == "Publish Docker Images":
        print(run.get("conclusion") or run.get("status") or "")
        break
' || true
}

resolve_wizard_image_tag() {
  local source_path="$1"
  local source_sha="$2"
  local source_tag=""
  local expected_source_tag=""
  local ci_status=""

  source_tag="$(extract_wizard_image_tag "$source_path")"
  [[ -n "$source_tag" ]] || die "Could not determine TWINBOX_IMAGE_TAG in ${source_path}"

  expected_source_tag="sha-${source_sha:0:7}"
  if [[ -n "$source_sha" ]] \
    && ! commit_is_image_bump "$source_sha" \
    && [[ "$source_tag" != "$expected_source_tag" ]]; then
    ci_status="$(ci_run_status_for_commit "$source_sha")"
    if [[ "$ci_status" == "failure" || "$ci_status" == "cancelled" || "$ci_status" == "timed_out" ]]; then
      echo "Warning: manager image publish for ${expected_source_tag} failed (CI status: ${ci_status}). Using last published tag ${source_tag}." >&2
      printf '%s\n' "$source_tag"
      return
    fi

    if wait_for_manager_images "$expected_source_tag"; then
      printf '%s\n' "$expected_source_tag"
      return
    fi

    echo "Warning: manager images ${expected_source_tag} were not published within ${IMAGE_TAG_WAIT_TIMEOUT_SECONDS}s. Using last published tag ${source_tag}." >&2
    printf '%s\n' "$source_tag"
    return
  fi

  printf '%s\n' "$source_tag"
}

select_wizard_source() {
  local source_sha=""

  case "${WIZARD_SOURCE}" in
    origin|origin-main)
      if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if ! refresh_origin_main; then
          echo "Warning: could not refresh origin/main; using cached origin/main if available" >&2
        fi
        source_sha="$(origin_main_sha || true)"
        [[ -n "$source_sha" ]] || die "Could not resolve origin/main. The wizard was not uploaded from a potentially stale checkout."
        printf '%s\t%s\n' "$(write_origin_wizard_source)" "$source_sha"
        return
      fi
      die "WIZARD_DEV_SOURCE=origin-main requires a git checkout with origin/main."
      ;;
    local)
      source_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
      printf '%s\t%s\n' "$LOCAL_WIZARD_PATH" "$source_sha"
      ;;
    *)
      die "Unsupported WIZARD_DEV_SOURCE=${WIZARD_SOURCE}. Use origin-main or local."
      ;;
  esac
}

prepare_wizard_upload() {
  local image_tag=""
  local source_path=""
  local source_sha=""
  local source_spec=""

  if [[ "${WIZARD_DEV_SKIP_IMAGE_TAG_SYNC:-}" == "1" ]]; then
    image_tag="$(extract_wizard_image_tag "$LOCAL_WIZARD_PATH")"
    echo "Using local TWINBOX_IMAGE_TAG=${image_tag} for uploaded wizard"
    return 0
  fi

  source_spec="$(select_wizard_source)"
  IFS=$'\t' read -r source_path source_sha <<<"$source_spec"
  [[ -n "$source_path" ]] || die "Could not determine wizard source"

  image_tag="$(resolve_wizard_image_tag "$source_path" "$source_sha")"
  [[ -n "$image_tag" ]] || die "Could not determine TWINBOX_IMAGE_TAG for wizard upload"

  write_wizard_with_image_tag "$source_path" "$image_tag"
  echo "Uploading ${WIZARD_SOURCE} wizard with TWINBOX_IMAGE_TAG=${image_tag}"
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

  echo "Uploading wizard to ${SSH_TARGET}:${REMOTE_SCRIPT_PATH}"
  ssh -n "${SSH_TARGET}" "mkdir -p ${quoted_remote_dir}"
  scp -q "${WIZARD_UPLOAD_PATH}" "${SSH_TARGET}:${REMOTE_SCRIPT_PATH}" </dev/null
  echo "Running wizard as root on ${SSH_TARGET}"
  ssh -tt "${SSH_TARGET}" "chmod +x ${quoted_remote_script} && TERM=xterm-256color ${remote_bash} ${quoted_remote_script}"
}

report_retained_remote_copy() {
  local exit_code=$?

  if [[ "${exit_code}" -ne 0 && -n "${SSH_TARGET}" && -n "${REMOTE_SCRIPT_PATH}" ]]; then
    echo "Remote wizard copy retained at ${SSH_TARGET}:${REMOTE_SCRIPT_PATH}" >&2
  fi

  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi

  exit "${exit_code}"
}

main() {
  trap report_retained_remote_copy EXIT

  load_config
  parse_args "$@"
  check_deps
  validate_inputs
  prepare_wizard_upload
  run_local_checks
  upload_and_run_remote

  echo "Remote wizard copy: ${SSH_TARGET}:${REMOTE_SCRIPT_PATH}"
}

main "$@"
