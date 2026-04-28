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

wait_for_resource_ready() {
  local namespace="$1"
  local resource="$2"
  local condition="$3"
  local label="$4"
  local attempts=120
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

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

n8n_db_username="n8n"
n8n_db_password="$(openssl rand -hex 24)"
n8n_encryption_key="$(openssl rand -base64 32)"

existing_n8n_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_n8n_secret_json="$(openbao_read_global_secret_json n8n 2>/dev/null || true)"
fi

if [[ -n "$existing_n8n_secret_json" ]]; then
  existing_db_username="$(jq -r '.N8N_POSTGRESQL__USERNAME // empty' <<<"$existing_n8n_secret_json")"
  existing_db_password="$(jq -r '.N8N_POSTGRESQL__PASSWORD // empty' <<<"$existing_n8n_secret_json")"
  existing_encryption_key="$(jq -r '.N8N_ENCRYPTION_KEY // empty' <<<"$existing_n8n_secret_json")"

  [[ -n "$existing_db_username" ]] && n8n_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && n8n_db_password="$existing_db_password"
  [[ -n "$existing_encryption_key" ]] && n8n_encryption_key="$existing_encryption_key"
fi

n8n_secret_file="$(mktemp "${TMPDIR:-/tmp}/n8n-bootstrap.XXXXXX.json")"
n8n_rendered_app_manifest="$(mktemp "${TMPDIR:-/tmp}/n8n-application.XXXXXX.yaml")"
trap 'rm -f "$n8n_secret_file" "$n8n_rendered_app_manifest"' EXIT

jq -n \
  --arg n8n_db_username "$n8n_db_username" \
  --arg n8n_db_password "$n8n_db_password" \
  --arg n8n_encryption_key "$n8n_encryption_key" \
  '{
    N8N_POSTGRESQL__USERNAME: $n8n_db_username,
    N8N_POSTGRESQL__PASSWORD: $n8n_db_password,
    N8N_ENCRYPTION_KEY: $n8n_encryption_key
  }' >"$n8n_secret_file"

log "Syncing n8n bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "n8n" \
  --json-file "$n8n_secret_file" \
  --required-keys "N8N_POSTGRESQL__USERNAME,N8N_POSTGRESQL__PASSWORD,N8N_ENCRYPTION_KEY"

log "Applying n8n namespace and ExternalSecret"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/n8n/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/n8n/externalsecret.yaml"
wait_for_resource_ready "n8n" "externalsecret/n8n-bootstrap" "Ready" "n8n application ExternalSecret"

log "Applying n8n database manifests"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/n8n/cluster.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/n8n/externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/n8n/pooler-ro.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/n8n/pooler-rw.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/n8n/pooler-rw-session.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/n8n/scheduled-backup.yaml"

wait_for_resource_ready "databases" "cluster/n8n-db" "Ready" "n8n CloudNativePG cluster"
wait_for_resource_ready "databases" "externalsecret/n8n-db-credentials" "Ready" "n8n database ExternalSecret"
wait_for_resource_ready "databases" "deployment/n8n-db-pooler-ro" "Available" "n8n read-only pooler deployment"
wait_for_resource_ready "databases" "deployment/n8n-db-pooler-rw" "Available" "n8n read-write pooler deployment"
wait_for_resource_ready "databases" "deployment/n8n-db-pooler-rw-session" "Available" "n8n session pooler deployment"

log "Applying n8n Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/n8n.yaml" >"$n8n_rendered_app_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$n8n_rendered_app_manifest" \
  --application "n8n"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "n8n" \
    --arg public_url "https://n8n.${public_zone_name}" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url
    }' >"$STEP_RESULT_FILE"
fi
