#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${APP_NAME:?missing APP_NAME}"
: "${MANIFEST_PATH:?missing MANIFEST_PATH}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

if [[ ! -f "$MANIFEST_PATH" ]]; then
  fail "manifest not found: $MANIFEST_PATH"
fi

platform_app_dir="$WORKSPACE_ROOT/gitops/platform-apps/$APP_NAME"
database_app_dir="$WORKSPACE_ROOT/gitops/databases/$APP_NAME"

manifest_kind="$(awk '/^kind:/{print $2; exit}' "$MANIFEST_PATH")"
manifest_name="$(awk '
  $1 == "metadata:" { in_metadata = 1; next }
  in_metadata && $1 == "name:" { print $2; exit }
  in_metadata && $1 !~ /^[[:space:]]/ { in_metadata = 0 }
' "$MANIFEST_PATH")"

application_set_name="${APPLICATION_SET_NAME:-}"
if [[ -z "$application_set_name" && "$manifest_kind" == "ApplicationSet" ]]; then
  application_set_name="${manifest_name:-${APP_NAME}-set}"
fi

log "Deleting Argo CD application ${APP_NAME}"
kubectl delete application "$APP_NAME" -n argocd --ignore-not-found=true >/dev/null 2>&1 || true
kubectl -n argocd wait --for=delete "application/${APP_NAME}" --timeout=5m >/dev/null 2>&1 || true

if [[ "$manifest_kind" == "ApplicationSet" || -n "$application_set_name" ]]; then
  if [[ -z "$application_set_name" ]]; then
    application_set_name="${manifest_name:-${APP_NAME}-set}"
  fi
  log "Deleting Argo CD applicationset ${application_set_name}"
  kubectl delete applicationset "$application_set_name" -n argocd --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl -n argocd wait --for=delete "applicationset/${application_set_name}" --timeout=5m >/dev/null 2>&1 || true
fi

if [[ -d "$platform_app_dir" ]]; then
  log "Deleting platform resources from ${platform_app_dir}"
  kubectl delete -k "$platform_app_dir" >/dev/null 2>&1 || true
fi

if [[ -d "$database_app_dir" ]]; then
  log "Deleting database resources from ${database_app_dir}"
  kubectl delete -f "$database_app_dir" >/dev/null 2>&1 || true
fi

log "App ${APP_NAME} removed"
