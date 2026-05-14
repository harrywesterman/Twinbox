#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --app NAME --state enabled|disabled [--secret-name NAME]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

APP_NAME=""
STATE=""
SECRET_NAME="in-cluster-local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_NAME="$2"
      shift 2
      ;;
    --state)
      STATE="$2"
      shift 2
      ;;
    --secret-name)
      SECRET_NAME="$2"
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
[[ -n "$APP_NAME" ]] || { usage; fail "--app is required"; }
[[ -n "$STATE" ]] || { usage; fail "--state is required"; }

case "$STATE" in
  enabled|disabled)
    ;;
  *)
    usage
    fail "--state must be enabled or disabled"
    ;;
esac

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

export KUBECONFIG="$KUBECONFIG_FILE"

label_key="twinbox.io/app-${APP_NAME}"

case "$STATE" in
  enabled)
    log "Enabling optional app ${APP_NAME} on Argo CD cluster secret ${SECRET_NAME}"
    kubectl -n argocd label secret "$SECRET_NAME" "$label_key=enabled" --overwrite
    ;;
  disabled)
    log "Disabling optional app ${APP_NAME} on Argo CD cluster secret ${SECRET_NAME}"
    kubectl -n argocd label secret "$SECRET_NAME" "${label_key}-" --overwrite
    ;;
esac
