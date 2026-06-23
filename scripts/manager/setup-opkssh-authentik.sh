#!/usr/bin/env bash
# scripts/manager/setup-opkssh-authentik.sh
# Creates the Authentik OAuth2 application for opkssh and stores secrets in OpenBao.
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_slug" ]] || fail "Could not determine cluster slug from STEP_CONTEXT_JSON"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain from STEP_CONTEXT_JSON"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

termix_host="https://termix.${public_zone_name}"
opkssh_redirect_uri="${termix_host}/host/opkssh-callback"
opkssh_issuer_url="https://authentik.${public_zone_name}/application/o/opkssh/"
opkssh_authorization_url="https://authentik.${public_zone_name}/application/o/authorize/"
opkssh_token_url="https://authentik.${public_zone_name}/application/o/token/"
opkssh_userinfo_url="https://authentik.${public_zone_name}/application/o/userinfo/"

opkssh_secret_file=""

cleanup() {
  rm -f "$opkssh_secret_file"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Local helpers for Authentik OAuth2 provider/application management.
# These mirror the helpers in setup-termix-authentik.sh but are scoped to
# the opkssh application so that setup-termix-authentik.sh does not need to
# be refactored.
# ---------------------------------------------------------------------------

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?name=$(printf '%s' "$provider_name" | jq -sRr @uri)&page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local response

  response="$(authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true)"
  if [[ -n "$response" ]]; then
    printf '%s\n' "$response"
    return 0
  fi

  response="$(authentik_api_get "/core/applications/?search=$(printf '%s' "$application_slug" | jq -sRr @uri)&page_size=200")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug or (.pk // .id // "") == $application_slug)' <<<"$response" | head -n1
}

create_or_update_oauth2_provider() {
  local provider_name="$1"
  local provider_payload="$2"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    log "OAuth2 provider '${provider_name}' already exists (pk=${existing_pk}), updating" >&2
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  log "Creating OAuth2 provider '${provider_name}'" >&2
  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug")"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"${existing_json:-null}")"
  if [[ -n "$existing_pk" ]]; then
    log "Application '${application_slug}' already exists (pk=${existing_pk}), updating" >&2
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  log "Creating application '${application_slug}'" >&2
  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

find_scope_mapping_json_by_name_and_scope() {
  local mapping_name="$1"
  local scope_name="$2"
  local response

  response="$(authentik_api_get "/propertymappings/provider/scope/?page_size=200")"
  jq -c \
    --arg mapping_name "$mapping_name" \
    --arg scope_name "$scope_name" \
    '.results[]?
      | select((.name // "") == $mapping_name and (.scope_name // "") == $scope_name)' <<<"$response" | head -n1
}

upsert_scope_mapping() {
  local mapping_name="$1"
  local scope_name="$2"
  local description="$3"
  local expression="$4"
  local existing_json existing_pk payload

  payload="$(
    jq -n \
      --arg name "$mapping_name" \
      --arg scope_name "$scope_name" \
      --arg description "$description" \
      --arg expression "$expression" \
      '{
        name: $name,
        scope_name: $scope_name,
        description: $description,
        expression: $expression
      }'
  )"

  existing_json="$(find_scope_mapping_json_by_name_and_scope "$mapping_name" "$scope_name" || true)"
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
    [[ -n "$existing_pk" ]] || fail "Could not determine Authentik scope mapping ID for ${mapping_name}"
    authentik_api_write PATCH "/propertymappings/provider/scope/${existing_pk}/" "$payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/propertymappings/provider/scope/" "$payload" | jq -r '.pk // .id // empty'
}

find_policy_binding_pk() {
  local target_uuid="$1"
  local group_id="$2"

  authentik_api_get "/policies/bindings/?page_size=200" | jq -r \
    --arg target_uuid "$target_uuid" \
    --arg group_id "$group_id" \
    '.results[]?
      | select((.target // "") == $target_uuid and (.group // "") == $group_id)
      | .pk // .id // empty' | head -n1
}

ensure_group_binding() {
  local target_uuid="$1"
  local group_id="$2"
  local binding_payload existing_pk

  binding_payload="$(
    jq -n \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '{target: $target_uuid, group: $group_id, order: 1, enabled: true}'
  )"

  existing_pk="$(find_policy_binding_pk "$target_uuid" "$group_id")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
    return 0
  fi

  authentik_api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
}

# ---------------------------------------------------------------------------
# Main setup
# ---------------------------------------------------------------------------

authentik_ensure_token
authentik_setup_forward

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
signing_key_id="$(authentik_resolve_signing_key_id)"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
groups_mapping_id="$(upsert_scope_mapping \
  "OPKSSH groups" \
  "groups" \
  "Expose OPKSSH group membership" \
  'groups = [group.name for group in request.user.ak_groups.all()]
if request.user.is_superuser and "admins" not in groups:
    groups.append("admins")
return {
    "groups": groups,
}')"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$groups_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for groups"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

opkssh_secret_json="$(openbao_read_global_secret_json opkssh 2>/dev/null || true)"

existing_provider_pk="$(find_oauth2_provider_pk_by_name "OPKSSH")"
existing_provider_json=""
if [[ -n "$existing_provider_pk" ]]; then
  existing_provider_json="$(authentik_api_get "/providers/oauth2/${existing_provider_pk}/" 2>/dev/null || true)"
fi

existing_client_id="$(jq -r '.OIDC_CLIENT_ID // empty' <<<"${opkssh_secret_json:-null}")"
existing_client_secret="$(jq -r '.OIDC_CLIENT_SECRET // empty' <<<"${opkssh_secret_json:-null}")"

provider_client_id_from_authentik="$(jq -r '.client_id // empty' <<<"${existing_provider_json:-null}")"
provider_client_secret_from_authentik="$(jq -r '.client_secret // empty' <<<"${existing_provider_json:-null}")"

client_id="${OIDC_CLIENT_ID:-${existing_client_id:-${provider_client_id_from_authentik:-}}}"
if [[ -z "$client_id" ]]; then
  client_id="opkssh-$(openssl rand -hex 8)"
fi

client_secret="${OIDC_CLIENT_SECRET:-${existing_client_secret:-${provider_client_secret_from_authentik:-}}}"
if [[ -z "$client_secret" ]]; then
  client_secret="$(openssl rand -hex 24)"
fi

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    --arg groups "$groups_mapping_id" \
    '[$openid, $email, $profile, $groups]'
)"

provider_payload="$(
  jq -n \
    --arg name "OPKSSH" \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$opkssh_redirect_uri" \
    --argjson property_mappings "$property_mapping_ids_json" \
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
      issuer_mode: "per_provider",
      sub_mode: "hashed_user_id"
    }'
)"

log "Provisioning Authentik OIDC provider for OPKSSH"
provider_pk="$(create_or_update_oauth2_provider "OPKSSH" "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for OPKSSH"

application_payload="$(
  jq -n \
    --arg name "OPKSSH" \
    --arg slug "opkssh" \
    --arg provider_pk "$provider_pk" \
    --arg launch_url "$termix_host" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber? // $provider_pk)
    }'
)"

application_pk="$(create_or_update_application "opkssh" "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for OPKSSH"

application_json="$(find_application_json_by_slug "opkssh")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"${application_json:-null}")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for OPKSSH"
ensure_group_binding "$application_uuid" "$admins_group_id"

opkssh_secret_payload="$(
  jq -n \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    --arg issuer_url "$opkssh_issuer_url" \
    --arg authorization_url "$opkssh_authorization_url" \
    --arg token_url "$opkssh_token_url" \
    --arg userinfo_url "$opkssh_userinfo_url" \
    --arg redirect_uri "$opkssh_redirect_uri" \
    '{
      OIDC_CLIENT_ID: $client_id,
      OIDC_CLIENT_SECRET: $client_secret,
      OIDC_ISSUER_URL: $issuer_url,
      OIDC_AUTHORIZATION_URL: $authorization_url,
      OIDC_TOKEN_URL: $token_url,
      OIDC_USERINFO_URL: $userinfo_url,
      OIDC_REDIRECT_URI: $redirect_uri
    }'
)"

opkssh_secret_file="$(mktemp "${TMPDIR:-/tmp}/opkssh-secret-XXXXXX")"
printf '%s' "$opkssh_secret_payload" >"$opkssh_secret_file"

log "Storing OPKSSH bootstrap secret in OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "opkssh" \
  --json-file "$opkssh_secret_file" \
  --required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL,OIDC_AUTHORIZATION_URL,OIDC_TOKEN_URL,OIDC_USERINFO_URL,OIDC_REDIRECT_URI"

log "===== Authentik OIDC Setup Complete for OPKSSH ====="
log "Issuer: ${opkssh_issuer_url}"
log "Client ID: ${client_id}"
log "Redirect URI: ${opkssh_redirect_uri}"
log "Application: OPKSSH"
