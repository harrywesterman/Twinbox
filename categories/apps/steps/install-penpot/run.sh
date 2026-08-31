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
  authentik_api_get "/providers/oauth2/?page_size=200" \
    | jq -r --arg provider_name "$provider_name" '.results[]? | select((.name // "") == $provider_name) | .pk // .id // empty' \
    | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  authentik_api_get "/core/applications/?page_size=200" \
    | jq -c --arg application_slug "$application_slug" '.results[]? | select((.slug // "") == $application_slug)' \
    | head -n1
}

create_or_update_provider() {
  local provider_name="$1"
  local provider_payload="$2"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk=""
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  fi

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
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

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

authentik_ensure_token
authentik_setup_forward

penpot_db_username="penpot"
penpot_db_password="$(openssl rand -hex 24)"
penpot_secret_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(64))')"
penpot_oidc_client_id="$(openssl rand -hex 16)"
penpot_oidc_client_secret="$(openssl rand -hex 32)"

existing_penpot_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_penpot_secret_json="$(openbao_read_global_secret_json penpot 2>/dev/null || true)"
fi

if [[ -n "$existing_penpot_secret_json" ]]; then
  existing_db_username="$(jq -r '.PENPOT_POSTGRESQL__USERNAME // empty' <<<"$existing_penpot_secret_json" || true)"
  existing_db_password="$(jq -r '.PENPOT_POSTGRESQL__PASSWORD // empty' <<<"$existing_penpot_secret_json" || true)"
  existing_secret_key="$(jq -r '.PENPOT_SECRET_KEY // empty' <<<"$existing_penpot_secret_json" || true)"
  existing_oidc_client_id="$(jq -r '.PENPOT_OIDC_CLIENT_ID // empty' <<<"$existing_penpot_secret_json" || true)"
  existing_oidc_client_secret="$(jq -r '.PENPOT_OIDC_CLIENT_SECRET // empty' <<<"$existing_penpot_secret_json" || true)"

  [[ -n "$existing_db_username" ]] && penpot_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && penpot_db_password="$existing_db_password"
  [[ -n "$existing_secret_key" ]] && penpot_secret_key="$existing_secret_key"
  [[ -n "$existing_oidc_client_id" ]] && penpot_oidc_client_id="$existing_oidc_client_id"
  [[ -n "$existing_oidc_client_secret" ]] && penpot_oidc_client_secret="$existing_oidc_client_secret"
fi

penpot_secret_file="$(mktemp "${TMPDIR:-/tmp}/penpot-bootstrap-XXXXXX")"
penpot_rendered_app_manifest="$(mktemp "${TMPDIR:-/tmp}/penpot-application-XXXXXX")"
trap 'rm -f "$penpot_secret_file" "$penpot_rendered_app_manifest"' EXIT

jq -n \
  --arg PENPOT_POSTGRESQL__USERNAME "$penpot_db_username" \
  --arg PENPOT_POSTGRESQL__PASSWORD "$penpot_db_password" \
  --arg PENPOT_SECRET_KEY "$penpot_secret_key" \
  --arg PENPOT_OIDC_CLIENT_ID "$penpot_oidc_client_id" \
  --arg PENPOT_OIDC_CLIENT_SECRET "$penpot_oidc_client_secret" \
  '{
    PENPOT_POSTGRESQL__USERNAME: $PENPOT_POSTGRESQL__USERNAME,
    PENPOT_POSTGRESQL__PASSWORD: $PENPOT_POSTGRESQL__PASSWORD,
    PENPOT_SECRET_KEY: $PENPOT_SECRET_KEY,
    PENPOT_OIDC_CLIENT_ID: $PENPOT_OIDC_CLIENT_ID,
    PENPOT_OIDC_CLIENT_SECRET: $PENPOT_OIDC_CLIENT_SECRET
  }' >"$penpot_secret_file"

log "Writing Penpot bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "penpot" \
  --json-file "$penpot_secret_file" \
  --required-keys "PENPOT_POSTGRESQL__USERNAME,PENPOT_POSTGRESQL__PASSWORD,PENPOT_SECRET_KEY,PENPOT_OIDC_CLIENT_ID,PENPOT_OIDC_CLIENT_SECRET"

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
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"

penpot_provider_name="Penpot"
penpot_application_slug="penpot"
penpot_provider_payload="$(
  jq -n \
    --arg name "$penpot_provider_name" \
    --arg slug "$penpot_application_slug" \
    --arg client_id "$penpot_oidc_client_id" \
    --arg client_secret "$penpot_oidc_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "https://penpot.${public_zone_name}/api/auth/oidc/callback" \
    --arg oauth_redirect_uri "https://penpot.${public_zone_name}/api/auth/oauth/oidc/callback" \
    --argjson property_mappings "$(jq -cn --arg openid "$openid_mapping_id" --arg email "$email_mapping_id" --arg profile "$profile_mapping_id" '[$openid, $email, $profile]')" \
    '{
      name: $name,
      slug: $slug,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      client_id: $client_id,
      client_secret: $client_secret,
      client_type: "confidential",
      grant_types: ["authorization_code"],
      issuer_mode: "per_provider",
      signing_key: $signing_key,
      property_mappings: $property_mappings,
      redirect_uris: [
        {
          matching_mode: "strict",
          url: $redirect_uri
        },
        {
          matching_mode: "strict",
          url: $oauth_redirect_uri
        }
      ],
      include_claims_in_id_token: true
    }'
)"

log "Provisioning Authentik OIDC client for Penpot"
provider_pk="$(create_or_update_provider "$penpot_provider_name" "$penpot_provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return an OAuth provider ID for Penpot"

penpot_application_payload="$(
  jq -n \
    --arg name "Penpot" \
    --arg slug "$penpot_application_slug" \
    --arg provider_pk "$provider_pk" \
    --arg launch_url "https://penpot.${public_zone_name}" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber),
      meta_launch_url: $launch_url
    }'
)"

application_pk="$(create_or_update_application "$penpot_application_slug" "$penpot_application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Penpot"

log "Applying Penpot Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$WORKSPACE_ROOT/gitops/apps/penpot.yaml" >"$penpot_rendered_app_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$penpot_rendered_app_manifest" \
  --application "penpot"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "penpot" \
  --host "penpot-db-pooler-rw.databases.svc.cluster.local"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "penpot" \
    --arg manifest_path "$WORKSPACE_ROOT/gitops/apps/penpot.yaml" \
    '{
      application: $application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "penpot" \
  --service-domain "penpot.${public_zone_name}" \
  --service-path /
