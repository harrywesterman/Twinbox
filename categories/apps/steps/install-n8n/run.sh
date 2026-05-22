#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

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

wait_for_deployment_rollout() {
  local namespace="$1"
  local deployment="$2"
  local label="${3:-$deployment}"
  local attempts=120
  local attempt=1
  local status_json=""
  local desired_replicas=""
  local updated_replicas=""
  local ready_replicas=""
  local available_replicas=""

  while true; do
    if status_json="$(kubectl -n "$namespace" get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}"
    else
      log "Waiting for ${label} deployment to appear (${attempt}/${attempts})"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for ${label}"
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

n8n_secret_file="$(mktemp "${TMPDIR:-/tmp}/n8n-bootstrap-XXXXXX")"
n8n_rendered_app_manifest="$(mktemp "${TMPDIR:-/tmp}/n8n-application-XXXXXX")"
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

log "Applying n8n Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/n8n.yaml" >"$n8n_rendered_app_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$n8n_rendered_app_manifest" \
  --application "n8n"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "n8n" \
  --host "n8n-db-pooler-rw-session.databases.svc.cluster.local"

log "Waiting for n8n deployment to be ready"
wait_for_resource_ready "n8n" "externalsecret/n8n-bootstrap" "Ready" "n8n ExternalSecret"
wait_for_deployment_rollout "n8n" "n8n" "n8n"

log "Configuring Authentik proxy provider for n8n"

authentik_ensure_token
authentik_setup_forward

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
admins_group_id="$(authentik_find_group_id "admins")"

lookup_response="$(authentik_api_request GET "/providers/proxy/?page_size=100")"
provider_pk="$(jq -r '.results[]? | select(.name == "n8n") | .pk // .id // .uuid // empty' <<<"$lookup_response")"

if [[ -z "$provider_pk" || "$provider_pk" == "null" ]]; then
  provider_payload="$(
    jq -n \
      --arg name "n8n" \
      --arg external_host "https://n8n.${public_zone_name}" \
      --arg authorization_flow "$authorization_flow_id" \
      --arg invalidation_flow "$invalidation_flow_id" \
      '{
        name: $name,
        external_host: $external_host,
        authorization_flow: $authorization_flow,
        invalidation_flow: $invalidation_flow,
        mode: "forward_single"
      }'
  )"
  provider_response="$(authentik_api_request POST "/providers/proxy/" "$provider_payload")"
  provider_pk="$(jq -r '.pk // .id // .uuid // empty' <<<"$provider_response")"
fi

[[ -n "$provider_pk" && "$provider_pk" != "null" ]] || fail "Could not determine Authentik proxy provider PK"

app_response="$(authentik_api_request GET "/core/applications/n8n/" 2>/dev/null || true)"
app_pk="$(jq -r '.pk // .id // .uuid // empty' <<<"$app_response")"

if [[ -z "$app_pk" || "$app_pk" == "null" ]]; then
  application_payload="$(
    jq -n \
      --arg name "n8n" \
      --arg slug "n8n" \
      --arg launch_url "https://n8n.${public_zone_name}" \
      --arg provider_pk "$provider_pk" \
      '{
        name: $name,
        slug: $slug,
        meta_launch_url: $launch_url,
        provider: ($provider_pk | tonumber)
      }'
  )"
  app_response="$(authentik_api_request POST "/core/applications/" "$application_payload")"
  app_pk="$(jq -r '.pk // .id // .uuid // empty' <<<"$app_response")"
fi

[[ -n "$app_pk" && "$app_pk" != "null" ]] || fail "Could not determine Authentik application PK"

existing_bindings="$(authentik_api_request GET "/policies/bindings/?page_size=100" 2>/dev/null || true)"
binding_exists="$(
  jq -e --arg target "$app_pk" --arg group "$admins_group_id" '
    .results[]? | select(.target == $target and .group == $group)
  ' <<<"$existing_bindings" >/dev/null 2>&1 && echo "true" || echo "false"
)"

if [[ "$binding_exists" != "true" ]]; then
  binding_payload="$(
    jq -n \
      --arg target_uuid "$app_pk" \
      --arg group_id "$admins_group_id" \
      '{target: $target_uuid, group: $group_id, order: 1, enabled: true}'
  )"
  authentik_api_request POST "/policies/bindings/" "$binding_payload" >/dev/null
  log "Policy binding created"
else
  log "Policy binding already exists"
fi

outpost_response="$(authentik_api_request GET "/outposts/instances/?page_size=100")"
outpost_id="$(jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' <<<"$outpost_response")"
current_providers="$(jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []' <<<"$outpost_response")"

if ! jq -e --arg pk "$provider_pk" 'map(tostring) | index($pk) != null' <<<"$current_providers" >/dev/null 2>&1; then
  updated_providers="$(jq -c --argjson pk "$provider_pk" '. + [$pk] | map(tostring) | unique' <<<"$current_providers")"
  authentik_api_request PATCH "/outposts/instances/${outpost_id}/" \
    "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
fi

authentik_teardown_forward

log "n8n proxy provider configured in Authentik"

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

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "n8n" \
  --service-domain "n8n.${public_zone_name}" \
  --service-path /
