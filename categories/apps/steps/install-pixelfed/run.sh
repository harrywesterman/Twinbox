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

pixelfed_db_username="pixelfed"
pixelfed_db_password="$(openssl rand -hex 24)"
pixelfed_app_key="base64:$(openssl rand -base64 32 | tr -d '\n')"

existing_pixelfed_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_pixelfed_secret_json="$(openbao_read_global_secret_json pixelfed 2>/dev/null || true)"
fi

if [[ -n "$existing_pixelfed_secret_json" ]]; then
  existing_app_key="$(jq -r '.APP_KEY // empty' <<<"$existing_pixelfed_secret_json" || true)"
  existing_db_username="$(jq -r '.PIXELFED_POSTGRESQL__USERNAME // empty' <<<"$existing_pixelfed_secret_json" || true)"
  existing_db_password="$(jq -r '.PIXELFED_POSTGRESQL__PASSWORD // empty' <<<"$existing_pixelfed_secret_json" || true)"

  [[ -n "$existing_app_key" ]] && pixelfed_app_key="$existing_app_key"
  [[ -n "$existing_db_username" ]] && pixelfed_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && pixelfed_db_password="$existing_db_password"
fi

pixelfed_secret_file="$(mktemp "${TMPDIR:-/tmp}/pixelfed-bootstrap.XXXXXX.json")"
pixelfed_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/pixelfed-application.XXXXXX.yaml")"
trap 'rm -f "$pixelfed_secret_file" "$pixelfed_rendered_manifest"' EXIT

jq -n \
  --arg APP_KEY "$pixelfed_app_key" \
  --arg PIXELFED_POSTGRESQL__USERNAME "$pixelfed_db_username" \
  --arg PIXELFED_POSTGRESQL__PASSWORD "$pixelfed_db_password" \
  '{
    APP_KEY: $APP_KEY,
    PIXELFED_POSTGRESQL__USERNAME: $PIXELFED_POSTGRESQL__USERNAME,
    PIXELFED_POSTGRESQL__PASSWORD: $PIXELFED_POSTGRESQL__PASSWORD
  }' >"$pixelfed_secret_file"

log "Writing Pixelfed bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "pixelfed" \
  --json-file "$pixelfed_secret_file" \
  --required-keys "APP_KEY,PIXELFED_POSTGRESQL__USERNAME,PIXELFED_POSTGRESQL__PASSWORD"

log "Applying Pixelfed database manifests"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/cluster.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/pooler-ro.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/pooler-rw.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/pooler-rw-session.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/scheduled-backup.yaml"

wait_for_resource_ready "databases" "externalsecret/pixelfed-db-credentials" "Ready" "Pixelfed database ExternalSecret"
wait_for_resource_ready "databases" "cluster/pixelfed-db" "Ready" "Pixelfed CloudNativePG cluster"
wait_for_resource_ready "databases" "deployment/pixelfed-db-pooler-ro" "Available" "Pixelfed read-only pooler"
wait_for_resource_ready "databases" "deployment/pixelfed-db-pooler-rw" "Available" "Pixelfed read-write pooler"
wait_for_resource_ready "databases" "deployment/pixelfed-db-pooler-rw-session" "Available" "Pixelfed session pooler"

log "Applying Pixelfed Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/pixelfed.yaml" >"$pixelfed_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$pixelfed_rendered_manifest" \
  --application "pixelfed" \
  --destination-namespace "pixelfed"

kubectl -n pixelfed rollout status deployment/pixelfed --timeout=10m >/dev/null

log "Bootstrapping Pixelfed federation and OAuth keys"
kubectl -n pixelfed exec deployment/pixelfed -- php artisan instance:actor

if ! kubectl -n pixelfed exec deployment/pixelfed -- test -f /var/www/html/storage/oauth-private.key >/dev/null 2>&1; then
  kubectl -n pixelfed exec deployment/pixelfed -- php artisan passport:keys --force
fi

kubectl -n pixelfed exec deployment/pixelfed -- php artisan config:cache
kubectl -n pixelfed exec deployment/pixelfed -- php artisan route:cache
kubectl -n pixelfed exec deployment/pixelfed -- php artisan view:cache

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "pixelfed" \
    --arg public_url "https://pixelfed.${public_zone_name}" \
    --arg database "pixelfed-db" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database
    }' >"$STEP_RESULT_FILE"
fi
