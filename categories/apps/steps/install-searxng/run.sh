#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

resolve_kubeconfig_file() {
  if [[ -z "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE is required"
  fi

  if [[ ! -f "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE does not exist at ${KUBECONFIG_FILE:-}"
  fi

  printf '%s\n' "$KUBECONFIG_FILE"
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

searxng_secret="$(openssl rand -hex 32)"
existing_searxng_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_searxng_secret_json="$(openbao_read_global_secret_json searxng 2>/dev/null || true)"
fi

if [[ -n "$existing_searxng_secret_json" ]]; then
  existing_secret="$(jq -r '.SEARXNG_SECRET // empty' <<<"$existing_searxng_secret_json" || true)"
  [[ -n "$existing_secret" ]] && searxng_secret="$existing_secret"
fi

searxng_secret_file="$(mktemp "${TMPDIR:-/tmp}/searxng-bootstrap-XXXXXX.json")"
searxng_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/searxng-application-XXXXXX.yaml")"
trap 'rm -f "$searxng_secret_file" "$searxng_rendered_manifest"' EXIT

jq -n \
  --arg SEARXNG_SECRET "$searxng_secret" \
  '{
    SEARXNG_SECRET: $SEARXNG_SECRET
  }' >"$searxng_secret_file"

log "Writing SearXNG bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "searxng" \
  --json-file "$searxng_secret_file" \
  --required-keys "SEARXNG_SECRET"

manifest_path="$WORKSPACE_ROOT/gitops/apps/searxng.yaml"
log "Applying SearXNG Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$manifest_path" >"$searxng_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$searxng_rendered_manifest" \
  --application "searxng"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "searxng" \
    --arg manifest_path "$manifest_path" \
    '{
      application: $application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi
