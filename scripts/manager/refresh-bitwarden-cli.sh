#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [--bitwarden-namespace NAME] [--deployment NAME]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

BITWARDEN_NAMESPACE="bitwarden"
DEPLOYMENT_NAME="bitwarden-cli"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --bitwarden-namespace)
      BITWARDEN_NAMESPACE="$2"
      shift 2
      ;;
    --deployment)
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${KUBECONFIG_FILE:-}" ]] || { usage; fail "KUBECONFIG_FILE is required"; }
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

require_cmd kubectl

export KUBECONFIG="$KUBECONFIG_FILE"

pod_name="$(
  kubectl -n "$BITWARDEN_NAMESPACE" get pod \
    -l app.kubernetes.io/name="$DEPLOYMENT_NAME" \
    -o jsonpath='{.items[0].metadata.name}'
)"

[[ -n "$pod_name" ]] || fail "Unable to find a running ${DEPLOYMENT_NAME} pod in ${BITWARDEN_NAMESPACE}"

log "Refreshing Bitwarden CLI sync state in pod ${pod_name}"
kubectl -n "$BITWARDEN_NAMESPACE" exec "$pod_name" -- /bin/bash -lc '
  set -euo pipefail
  bw config server "${BW_HOST}"
  bw_status="$(bw status | jq -r '"'"'.status // "unauthenticated"'"'"')"
  if [[ "$bw_status" == "unauthenticated" ]]; then
    bw login --apikey >/dev/null
  fi
  export BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)"
  bw sync --session "${BW_SESSION}" >/dev/null
'

log "Bitwarden CLI sync refresh completed"
