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

render_template() {
  local template_file="$1"
  local rendered_file="$2"
  shift 2

  python3 - "$template_file" "$rendered_file" "$@" <<'PY'
from pathlib import Path
import sys

template = Path(sys.argv[1]).read_text(encoding="utf-8")
rendered = template
for item in sys.argv[3:]:
    key, value = item.split("=", 1)
    rendered = rendered.replace(key, value)
Path(sys.argv[2]).write_text(rendered, encoding="utf-8")
PY
}

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?page_size=200")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local response

  response="$(authentik_api_get "/core/applications/?page_size=200")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug)' <<<"$response" | head -n1
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Outline")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_payload="$1"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "outline" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/outline/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
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
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

authentik_ensure_token
authentik_setup_forward

OUTLINE_HOST="https://outline.${public_zone_name}"
OUTLINE_REDIRECT_URI="${OUTLINE_HOST}/auth/oidc.callback"

outline_db_username="outline"
outline_db_password="$(openssl rand -hex 24)"
outline_redis_url="redis://outline-redis:6379"
outline_secret_key="$(openssl rand -hex 32)"
outline_utils_secret="$(openssl rand -hex 32)"
outline_oauth_client_id="$(openssl rand -hex 16)"
outline_oauth_client_secret="$(openssl rand -hex 24)"
outline_database_url="postgresql://${outline_db_username}:${outline_db_password}@outline-db-pooler-rw-session.databases.svc.cluster.local:5432/outline"

existing_outline_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_outline_secret_json="$(openbao_read_global_secret_json outline 2>/dev/null || true)"
fi

if [[ -n "$existing_outline_secret_json" ]]; then
  existing_db_username="$(jq -r '.OUTLINE_POSTGRESQL__USERNAME // empty' <<<"$existing_outline_secret_json")"
  existing_db_password="$(jq -r '.OUTLINE_POSTGRESQL__PASSWORD // empty' <<<"$existing_outline_secret_json")"
  existing_database_url="$(jq -r '.DATABASE_URL // empty' <<<"$existing_outline_secret_json")"
  existing_redis_url="$(jq -r '.REDIS_URL // empty' <<<"$existing_outline_secret_json")"
  existing_secret_key="$(jq -r '.SECRET_KEY // empty' <<<"$existing_outline_secret_json")"
  existing_utils_secret="$(jq -r '.UTILS_SECRET // empty' <<<"$existing_outline_secret_json")"
  existing_oauth_client_id="$(jq -r '.OIDC_CLIENT_ID // empty' <<<"$existing_outline_secret_json")"
  existing_oauth_client_secret="$(jq -r '.OIDC_CLIENT_SECRET // empty' <<<"$existing_outline_secret_json")"

  [[ -n "$existing_db_username" ]] && outline_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && outline_db_password="$existing_db_password"
  [[ -n "$existing_database_url" ]] && outline_database_url="$existing_database_url"
  [[ -n "$existing_redis_url" ]] && outline_redis_url="$existing_redis_url"
  [[ -n "$existing_secret_key" ]] && outline_secret_key="$existing_secret_key"
  [[ -n "$existing_utils_secret" ]] && outline_utils_secret="$existing_utils_secret"
  [[ -n "$existing_oauth_client_id" ]] && outline_oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && outline_oauth_client_secret="$existing_oauth_client_secret"
fi

outline_secret_file="$(mktemp "${TMPDIR:-/tmp}/outline-bootstrap-XXXXXX")"
outline_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/outline-application-XXXXXX")"
outline_rendered_deployment="$(mktemp "${TMPDIR:-/tmp}/outline-deployment-XXXXXX")"
outline_rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/outline-ingressroute-XXXXXX")"
trap 'rm -f "$outline_secret_file" "$outline_rendered_manifest" "$outline_rendered_deployment" "$outline_rendered_ingressroute"' EXIT

jq -n \
  --arg OUTLINE_POSTGRESQL__USERNAME "$outline_db_username" \
  --arg OUTLINE_POSTGRESQL__PASSWORD "$outline_db_password" \
  --arg DATABASE_URL "$outline_database_url" \
  --arg REDIS_URL "$outline_redis_url" \
  --arg SECRET_KEY "$outline_secret_key" \
  --arg UTILS_SECRET "$outline_utils_secret" \
  --arg OIDC_CLIENT_ID "$outline_oauth_client_id" \
  --arg OIDC_CLIENT_SECRET "$outline_oauth_client_secret" \
  '{
    OUTLINE_POSTGRESQL__USERNAME: $OUTLINE_POSTGRESQL__USERNAME,
    OUTLINE_POSTGRESQL__PASSWORD: $OUTLINE_POSTGRESQL__PASSWORD,
    DATABASE_URL: $DATABASE_URL,
    REDIS_URL: $REDIS_URL,
    SECRET_KEY: $SECRET_KEY,
    UTILS_SECRET: $UTILS_SECRET,
    OIDC_CLIENT_ID: $OIDC_CLIENT_ID,
    OIDC_CLIENT_SECRET: $OIDC_CLIENT_SECRET
  }' >"$outline_secret_file"

log "Writing Outline bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "outline" \
  --json-file "$outline_secret_file" \
  --required-keys "OUTLINE_POSTGRESQL__USERNAME,OUTLINE_POSTGRESQL__PASSWORD,DATABASE_URL,REDIS_URL,SECRET_KEY,UTILS_SECRET,OIDC_CLIENT_ID,OIDC_CLIENT_SECRET"

log "Provisioning Authentik OIDC client for Outline"
authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"

property_mappings_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "Outline" \
    --arg client_id "$outline_oauth_client_id" \
    --arg client_secret "$outline_oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$OUTLINE_REDIRECT_URI" \
    --argjson property_mappings "$property_mappings_json" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      redirect_uris: [
        {
          matching_mode: "strict",
          url: $redirect_uri
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      issuer_mode: "per_provider"
    }'
)"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Outline"

application_payload="$(
  jq -n \
    --arg name "Outline" \
    --arg slug "outline" \
    --arg launch_url "$OUTLINE_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Outline"

log "Applying Outline Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/outline.yaml" >"$outline_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$outline_rendered_manifest" \
  --application "outline" \
  --destination-namespace "outline"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "outline" \
  --host "outline-db-pooler-rw-session.databases.svc.cluster.local"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "outline" \
    --arg public_url "$OUTLINE_HOST" \
    --arg database "outline-db" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "outline" \
  --service-domain "outline.${public_zone_name}" \
  --service-path /
