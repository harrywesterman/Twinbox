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

vaultwarden_admin_token="$(openssl rand -hex 48)"
vaultwarden_db_username="vaultwarden"
vaultwarden_db_password="$(openssl rand -hex 24)"
vaultwarden_database_url="postgresql://${vaultwarden_db_username}:${vaultwarden_db_password}@vaultwarden-db-pooler-rw.databases.svc.cluster.local:5432/vaultwarden"
vaultwarden_host="https://vaultwarden.${public_zone_name}"
vaultwarden_secret_file="$(mktemp "${TMPDIR:-/tmp}/vaultwarden-bootstrap.XXXXXX.json")"
vaultwarden_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/vaultwarden-application.XXXXXX.yaml")"
trap 'rm -f "$vaultwarden_secret_file" "$vaultwarden_rendered_manifest"' EXIT

existing_vaultwarden_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_vaultwarden_secret_json="$(openbao_read_global_secret_json vaultwarden 2>/dev/null || true)"
fi

if [[ -n "$existing_vaultwarden_secret_json" ]]; then
  existing_admin_token="$(jq -r '.VAULTWARDEN_ADMIN_TOKEN // empty' <<<"$existing_vaultwarden_secret_json")"
  existing_db_username="$(jq -r '.VAULTWARDEN_POSTGRESQL__USERNAME // empty' <<<"$existing_vaultwarden_secret_json")"
  existing_db_password="$(jq -r '.VAULTWARDEN_POSTGRESQL__PASSWORD // empty' <<<"$existing_vaultwarden_secret_json")"
  existing_database_url="$(jq -r '.VAULTWARDEN_DATABASE_URL // empty' <<<"$existing_vaultwarden_secret_json")"

  [[ -n "$existing_admin_token" ]] && vaultwarden_admin_token="$existing_admin_token"
  [[ -n "$existing_db_username" ]] && vaultwarden_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && vaultwarden_db_password="$existing_db_password"
  if [[ -n "$existing_database_url" ]]; then
    vaultwarden_database_url="$existing_database_url"
  else
    vaultwarden_database_url="postgresql://${vaultwarden_db_username}:${vaultwarden_db_password}@vaultwarden-db-pooler-rw.databases.svc.cluster.local:5432/vaultwarden"
  fi
fi

jq -n \
  --arg VAULTWARDEN_ADMIN_TOKEN "$vaultwarden_admin_token" \
  --arg VAULTWARDEN_POSTGRESQL__USERNAME "$vaultwarden_db_username" \
  --arg VAULTWARDEN_POSTGRESQL__PASSWORD "$vaultwarden_db_password" \
  --arg VAULTWARDEN_DATABASE_URL "$vaultwarden_database_url" \
  '{
    VAULTWARDEN_ADMIN_TOKEN: $VAULTWARDEN_ADMIN_TOKEN,
    VAULTWARDEN_POSTGRESQL__USERNAME: $VAULTWARDEN_POSTGRESQL__USERNAME,
    VAULTWARDEN_POSTGRESQL__PASSWORD: $VAULTWARDEN_POSTGRESQL__PASSWORD,
    VAULTWARDEN_DATABASE_URL: $VAULTWARDEN_DATABASE_URL
  }' >"$vaultwarden_secret_file"

log "Writing Vaultwarden bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "vaultwarden" \
  --json-file "$vaultwarden_secret_file" \
  --required-keys "VAULTWARDEN_ADMIN_TOKEN,VAULTWARDEN_POSTGRESQL__USERNAME,VAULTWARDEN_POSTGRESQL__PASSWORD,VAULTWARDEN_DATABASE_URL"

log "Applying Vaultwarden database manifests"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/vaultwarden/externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/vaultwarden/cluster.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/vaultwarden/pooler-ro.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/vaultwarden/pooler-rw.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/vaultwarden/scheduled-backup.yaml"

wait_for_resource_ready "databases" "externalsecret/vaultwarden-db-credentials" "Ready" "Vaultwarden database ExternalSecret"
wait_for_resource_ready "databases" "cluster/vaultwarden-db" "Ready" "Vaultwarden CloudNativePG cluster"
wait_for_resource_ready "databases" "deployment/vaultwarden-db-pooler-rw" "Available" "Vaultwarden rw pooler"
wait_for_resource_ready "databases" "deployment/vaultwarden-db-pooler-ro" "Available" "Vaultwarden ro pooler"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "vaultwarden" \
  --host "vaultwarden-db-pooler-rw.databases.svc.cluster.local"

log "Applying Vaultwarden Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/vaultwarden.yaml" >"$vaultwarden_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$vaultwarden_rendered_manifest" \
  --application "vaultwarden" \
  --destination-namespace "vaultwarden"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "vaultwarden" \
    --arg public_url "$vaultwarden_host" \
    --arg database "vaultwarden-db" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database
    }' >"$STEP_RESULT_FILE"
fi
