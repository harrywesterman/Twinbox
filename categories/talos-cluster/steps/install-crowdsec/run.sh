#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_resource_ready() {
  local namespace="$1"
  local resource="$2"
  local condition="$3"
  local label="$4"
  local attempts=60
  local attempt=1

  while true; do
    if kubectl -n "$namespace" get "$resource" >/dev/null 2>&1; then
      if kubectl -n "$namespace" wait --for="condition=${condition}" "$resource" --timeout=5s >/dev/null 2>&1; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} to become ready"
    else
      log "Waiting for ${label} to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not become ready after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

manifest_path="$WORKSPACE_ROOT/gitops/apps/crowdsec.yaml"
bouncer_secret_file="$(mktemp "${TMPDIR:-/tmp}/crowdsec-bouncer.XXXXXX.json")"
trap 'rm -f "$bouncer_secret_file"' EXIT

bouncer_key="$(openssl rand -hex 32)"
existing_bouncer_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_bouncer_secret_json="$(openbao_read_global_secret_json crowdsec-bouncer 2>/dev/null || true)"
fi

if [[ -n "$existing_bouncer_secret_json" ]]; then
  existing_bouncer_key="$(jq -r '.lapi_key // empty' <<<"$existing_bouncer_secret_json")"
  [[ -n "$existing_bouncer_key" ]] && bouncer_key="$existing_bouncer_key"
fi

jq -n --arg lapi_key "$bouncer_key" '{lapi_key: $lapi_key}' >"$bouncer_secret_file"

log "Writing CrowdSec bouncer key to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "crowdsec-bouncer" \
  --json-file "$bouncer_secret_file" \
  --required-keys "lapi_key"

log "Applying CrowdSec and Traefik bouncer ExternalSecrets"
kubectl create namespace crowdsec --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/crowdsec/bouncer-externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/traefik/crowdsec-bouncer-externalsecret.yaml"

wait_for_resource_ready "crowdsec" "externalsecret/crowdsec-bouncer-keys" "Ready" "CrowdSec bouncer ExternalSecret"
wait_for_resource_ready "traefik" "externalsecret/traefik-crowdsec-bouncer" "Ready" "Traefik CrowdSec bouncer ExternalSecret"

log "Applying CrowdSec Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "crowdsec" \
  --destination-namespace "crowdsec"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "crowdsec" \
    --arg manifest_path "$manifest_path" \
    '{
      application: $application,
      manifest_path: $manifest_path,
      openbao_secret: "crowdsec-bouncer"
    }' >"$STEP_RESULT_FILE"
fi
