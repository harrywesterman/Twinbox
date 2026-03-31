#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

usage() {
  cat <<USAGE
Usage: $0 --manifest PATH --application NAME
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_application_ready() {
  local application="$1"
  local status_json=""
  local sync_status=""
  local health_status=""
  local operation_phase=""
  local attempt=1
  local attempts=180

  has_unhealthy_resources() {
    jq -e '
      any(
        .status.resources[]?;
        (.health.status // "") == "Degraded"
        or (.health.status // "") == "Missing"
        or (.health.status // "") == "Progressing"
      )
    ' >/dev/null 2>&1
  }

  while true; do
    if status_json="$(kubectl -n argocd get application "$application" -o json 2>/dev/null)"; then
      sync_status="$(jq -r '.status.sync.status // "Unknown"' <<<"$status_json")"
      health_status="$(jq -r '.status.health.status // "Unknown"' <<<"$status_json")"
      operation_phase="$(jq -r '.status.operationState.phase // "Unknown"' <<<"$status_json")"
      log "Waiting for application/${application}: sync=${sync_status}, health=${health_status}, phase=${operation_phase}"

      if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" && "$operation_phase" != "Running" && "$operation_phase" != "Terminating" ]]; then
        log "Application/${application} is Synced and Healthy"
        return 0
      fi

      if [[ "$sync_status" == "Synced" && "$operation_phase" != "Running" && "$operation_phase" != "Terminating" && "$health_status" == "Degraded" ]]; then
        if ! has_unhealthy_resources <<<"$status_json"; then
          log "Application/${application} is Synced and has no unhealthy resources; accepting aggregate health=${health_status}"
          return 0
        fi
      fi
    else
      log "Waiting for application/${application} to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      return 1
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

MANIFEST_PATH=""
APPLICATION_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      MANIFEST_PATH="$2"
      shift 2
      ;;
    --application)
      APPLICATION_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
[[ -n "$MANIFEST_PATH" ]] || { usage; fail "manifest required"; }
[[ -n "$APPLICATION_NAME" ]] || { usage; fail "application required"; }
[[ -f "$MANIFEST_PATH" ]] || fail "manifest not found at ${MANIFEST_PATH}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

export KUBECONFIG="$KUBECONFIG_FILE"

repo_url="${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
target_rev="${TWINBOX_GIT_TARGET_REVISION:-main}"

rendered_manifest="$(sed "s|__REPO_URL__|${repo_url}|g; s|__TARGET_REVISION__|${target_rev}|g" "$MANIFEST_PATH")"

log "Applying Argo CD application manifest ${MANIFEST_PATH}"
printf '%s\n' "$rendered_manifest" | kubectl apply --validate=false -f -
wait_for_application_ready "$APPLICATION_NAME"
