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

  existing_pk="$(find_oauth2_provider_pk_by_name "AFFiNE")"
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

  existing_json="$(find_application_json_by_slug "affine" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/affine/" "$application_payload" >/dev/null
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
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

authentik_ensure_token
authentik_setup_forward

AFFINE_HOST="https://affine.${public_zone_name}"
AFFINE_REDIRECT_URI="${AFFINE_HOST}/oauth/callback"
AUTHENTIK_ISSUER="https://authentik.${public_zone_name}/application/o/affine/"

affine_db_username="affine"
affine_db_password="$(openssl rand -hex 24)"
affine_private_key="$(openssl rand -hex 32)"
affine_oauth_client_id="$(openssl rand -hex 16)"
affine_oauth_client_secret="$(openssl rand -hex 24)"
affine_database_url="postgresql://${affine_db_username}:${affine_db_password}@affine-db-pooler-rw-session.databases.svc.cluster.local:5432/affine"
affine_server_host="affine.${public_zone_name}"

existing_affine_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_affine_secret_json="$(openbao_read_global_secret_json affine 2>/dev/null || true)"
fi

if [[ -n "$existing_affine_secret_json" ]]; then
  existing_db_username="$(jq -r '.AFFINE_POSTGRESQL__USERNAME // empty' <<<"$existing_affine_secret_json")"
  existing_db_password="$(jq -r '.AFFINE_POSTGRESQL__PASSWORD // empty' <<<"$existing_affine_secret_json")"
  existing_database_url="$(jq -r '.DATABASE_URL // empty' <<<"$existing_affine_secret_json")"
  existing_private_key="$(jq -r '.AFFINE_PRIVATE_KEY // empty' <<<"$existing_affine_secret_json")"
  existing_oauth_client_id="$(jq -r '.OAUTH_OIDC_CLIENT_ID // empty' <<<"$existing_affine_secret_json")"
  existing_oauth_client_secret="$(jq -r '.OAUTH_OIDC_CLIENT_SECRET // empty' <<<"$existing_affine_secret_json")"

  [[ -n "$existing_db_username" ]] && affine_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && affine_db_password="$existing_db_password"
  [[ -n "$existing_database_url" ]] && affine_database_url="$existing_database_url"
  [[ -n "$existing_private_key" ]] && affine_private_key="$existing_private_key"
  [[ -n "$existing_oauth_client_id" ]] && affine_oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && affine_oauth_client_secret="$existing_oauth_client_secret"
fi

affine_secret_file="$(mktemp "${TMPDIR:-/tmp}/affine-bootstrap-XXXXXX")"
affine_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/affine-application-XXXXXX")"
trap 'rm -f "$affine_secret_file" "$affine_rendered_manifest"' EXIT

jq -n \
  --arg AFFINE_POSTGRESQL__USERNAME "$affine_db_username" \
  --arg AFFINE_POSTGRESQL__PASSWORD "$affine_db_password" \
  --arg DATABASE_URL "$affine_database_url" \
  --arg AFFINE_PRIVATE_KEY "$affine_private_key" \
  --arg OAUTH_OIDC_CLIENT_ID "$affine_oauth_client_id" \
  --arg OAUTH_OIDC_CLIENT_SECRET "$affine_oauth_client_secret" \
  --arg AFFINE_SERVER_EXTERNAL_URL "$AFFINE_HOST" \
  --arg AFFINE_SERVER_HOST "$affine_server_host" \
  --arg OAUTH_OIDC_ISSUER "$AUTHENTIK_ISSUER" \
  '{
    AFFINE_POSTGRESQL__USERNAME: $AFFINE_POSTGRESQL__USERNAME,
    AFFINE_POSTGRESQL__PASSWORD: $AFFINE_POSTGRESQL__PASSWORD,
    DATABASE_URL: $DATABASE_URL,
    AFFINE_PRIVATE_KEY: $AFFINE_PRIVATE_KEY,
    OAUTH_OIDC_CLIENT_ID: $OAUTH_OIDC_CLIENT_ID,
    OAUTH_OIDC_CLIENT_SECRET: $OAUTH_OIDC_CLIENT_SECRET,
    AFFINE_SERVER_EXTERNAL_URL: $AFFINE_SERVER_EXTERNAL_URL,
    AFFINE_SERVER_HOST: $AFFINE_SERVER_HOST,
    OAUTH_OIDC_ISSUER: $OAUTH_OIDC_ISSUER
  }' >"$affine_secret_file"

log "Writing AFFiNE bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "affine" \
  --json-file "$affine_secret_file" \
  --required-keys "AFFINE_POSTGRESQL__USERNAME,AFFINE_POSTGRESQL__PASSWORD,DATABASE_URL,AFFINE_PRIVATE_KEY,OAUTH_OIDC_CLIENT_ID,OAUTH_OIDC_CLIENT_SECRET,AFFINE_SERVER_EXTERNAL_URL,AFFINE_SERVER_HOST,OAUTH_OIDC_ISSUER"

log "Provisioning Authentik OIDC client for AFFiNE"
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
    --arg name "AFFiNE" \
    --arg client_id "$affine_oauth_client_id" \
    --arg client_secret "$affine_oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$AFFINE_REDIRECT_URI" \
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
      grant_types: ["authorization_code"],
      issuer_mode: "per_provider"
    }'
)"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for AFFiNE"

application_payload="$(
  jq -n \
    --arg name "AFFiNE" \
    --arg slug "affine" \
    --arg launch_url "$AFFINE_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for AFFiNE"

log "Applying AFFiNE Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/affine.yaml" >"$affine_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$affine_rendered_manifest" \
  --application "affine" \
  --destination-namespace "affine"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "affine" \
  --host "affine-db-pooler-rw-session.databases.svc.cluster.local"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "affine" \
    --arg public_url "$AFFINE_HOST" \
    --arg database "affine-db" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "affine" \
  --service-domain "affine.${public_zone_name}" \
  --service-path /
