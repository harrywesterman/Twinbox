#!/usr/bin/env bash
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
termix_oidc_redirect_uri="${termix_host}/users/oidc/callback"
termix_oidc_issuer_url="https://authentik.${public_zone_name}/application/o/termix/"
termix_oidc_authorization_url="https://authentik.${public_zone_name}/application/o/authorize/"
termix_oidc_token_url="https://authentik.${public_zone_name}/application/o/token/"
termix_oidc_userinfo_url="https://authentik.${public_zone_name}/application/o/userinfo/"
termix_app_manifest="$WORKSPACE_ROOT/gitops/apps/termix.yaml"
rendered_termix_app_manifest="$(mktemp "${TMPDIR:-/tmp}/termix-application-XXXXXX")"
termix_secret_file=""
termix_secret_json=""

cleanup() {
  rm -f "$rendered_termix_app_manifest"
  rm -f "$termix_secret_file"
}
trap cleanup EXIT

termix_secret_get() {
  local key="$1"

  [[ -n "$termix_secret_json" ]] || return 0
  jq -r --arg key "$key" '.[$key] // empty' <<<"$termix_secret_json"
}

normalize_termix_scopes() {
  local scopes_input="${1:-}"
  local -a scopes=()
  local seen=" "
  local required_scope

  for scope in $scopes_input; do
    [[ -n "$scope" ]] || continue
    case "$seen" in
      *" ${scope} "*) ;;
      *)
        scopes+=("$scope")
        seen="${seen}${scope} "
        ;;
    esac
  done

  for required_scope in openid email profile groups; do
    case "$seen" in
      *" ${required_scope} "*) ;;
      *)
        scopes+=("$required_scope")
        seen="${seen}${required_scope} "
        ;;
    esac
  done

  printf '%s\n' "${scopes[*]}"
}

render_template() {
  local template_file="$1"
  local rendered_file="$2"
  local zone_name="$3"

  python3 - "$template_file" "$rendered_file" "$zone_name" <<'PY'
from pathlib import Path
import sys

template_file = Path(sys.argv[1])
rendered_file = Path(sys.argv[2])
zone_name = sys.argv[3]

rendered = template_file.read_text(encoding="utf-8").replace("__ZONE_NAME__", zone_name)
rendered_file.write_text(rendered, encoding="utf-8")
PY
}

authentik_ensure_token
authentik_setup_forward

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

  response="$(authentik_api_get "/core/applications/?slug=$(printf '%s' "$application_slug" | jq -sRr @uri)")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug)' <<<"$response" | head -n1
}

create_or_update_oauth2_provider() {
  local provider_name="$1"
  local provider_payload="$2"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    log "OAuth2 provider '${provider_name}' already exists (pk=${existing_pk}), updating"
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  log "Creating OAuth2 provider '${provider_name}'"
  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug")"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"${existing_json:-null}")"
  if [[ -n "$existing_pk" ]]; then
    log "Application '${application_slug}' already exists (pk=${existing_pk}), updating"
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  log "Creating application '${application_slug}'"
  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
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

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
signing_key_id="$(authentik_resolve_signing_key_id)"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
groups_mapping_id="$(authentik_resolve_scope_mapping_id "groups")"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$groups_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for groups"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

termix_secret_json="$(openbao_read_global_secret_json termix 2>/dev/null || true)"

existing_provider_pk="$(find_oauth2_provider_pk_by_name "Termix")"
existing_provider_json=""
if [[ -n "$existing_provider_pk" ]]; then
  existing_provider_json="$(authentik_api_get "/providers/oauth2/${existing_provider_pk}/" 2>/dev/null || true)"
fi

existing_client_id="$(termix_secret_get OIDC_CLIENT_ID)"
existing_client_secret="$(termix_secret_get OIDC_CLIENT_SECRET)"
existing_admin_password="$(termix_secret_get TERMIX_ADMIN_PASSWORD)"
existing_scopes="$(termix_secret_get OIDC_SCOPES)"
existing_admin_group="$(termix_secret_get OIDC_ADMIN_GROUP)"
existing_allowed_users="$(termix_secret_get OIDC_ALLOWED_USERS)"
existing_allow_registration="$(termix_secret_get OIDC_ALLOW_REGISTRATION)"
existing_force_https="$(termix_secret_get OIDC_FORCE_HTTPS)"
existing_ssh_private_key="$(termix_secret_get SSH_PRIVATE_KEY)"

provider_client_id_from_authentik="$(jq -r '.client_id // empty' <<<"${existing_provider_json:-null}")"
provider_client_secret_from_authentik="$(jq -r '.client_secret // empty' <<<"${existing_provider_json:-null}")"

client_id="${OIDC_CLIENT_ID:-${existing_client_id:-${provider_client_id_from_authentik:-}}}"
if [[ -z "$client_id" ]]; then
  client_id="termix-$(openssl rand -hex 8)"
fi

client_secret="${OIDC_CLIENT_SECRET:-${existing_client_secret:-${provider_client_secret_from_authentik:-}}}"
if [[ -z "$client_secret" ]]; then
  client_secret="$(openssl rand -hex 24)"
fi

termix_admin_password="${TERMIX_ADMIN_PASSWORD:-${TERMIX_ADMIN_PASS:-${existing_admin_password:-}}}"
if [[ -z "$termix_admin_password" ]]; then
  termix_admin_password="$(openssl rand -hex 24)"
fi

oidc_scopes="$(normalize_termix_scopes "${OIDC_SCOPES:-$existing_scopes}")"
oidc_admin_group="${OIDC_ADMIN_GROUP:-${existing_admin_group:-admins}}"
oidc_allowed_users="${OIDC_ALLOWED_USERS:-${existing_allowed_users:-*}}"
oidc_allow_registration="${OIDC_ALLOW_REGISTRATION:-${existing_allow_registration:-true}}"
oidc_force_https="${OIDC_FORCE_HTTPS:-${existing_force_https:-true}}"
ssh_private_key="${SSH_PRIVATE_KEY:-${existing_ssh_private_key:-}}"

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
    --arg name "Termix" \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$termix_oidc_redirect_uri" \
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
      issuer_mode: "per_provider"
    }'
)"

log "Provisioning Authentik OIDC provider for Termix"
provider_pk="$(create_or_update_oauth2_provider "Termix" "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Termix"

application_payload="$(
  jq -n \
    --arg name "Termix" \
    --arg slug "termix" \
    --arg provider_pk "$provider_pk" \
    --arg launch_url "$termix_host" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"

application_pk="$(create_or_update_application "termix" "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Termix"

application_json="$(find_application_json_by_slug "termix")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"${application_json:-null}")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Termix"
ensure_group_binding "$application_uuid" "$admins_group_id"

termix_secret_payload="$(
  jq -n \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    --arg issuer_url "$termix_oidc_issuer_url" \
    --arg authorization_url "$termix_oidc_authorization_url" \
    --arg token_url "$termix_oidc_token_url" \
    --arg userinfo_url "$termix_oidc_userinfo_url" \
    --arg scopes "$oidc_scopes" \
    --arg admin_group "$oidc_admin_group" \
    --arg allowed_users "$oidc_allowed_users" \
    --arg allow_registration "$oidc_allow_registration" \
    --arg force_https "$oidc_force_https" \
    --arg admin_password "$termix_admin_password" \
    --arg ssh_private_key "$ssh_private_key" \
    '{
      OIDC_CLIENT_ID: $client_id,
      OIDC_CLIENT_SECRET: $client_secret,
      OIDC_ISSUER_URL: $issuer_url,
      OIDC_AUTHORIZATION_URL: $authorization_url,
      OIDC_TOKEN_URL: $token_url,
      OIDC_USERINFO_URL: $userinfo_url,
      OIDC_SCOPES: $scopes,
      OIDC_ADMIN_GROUP: $admin_group,
      OIDC_ALLOWED_USERS: $allowed_users,
      OIDC_ALLOW_REGISTRATION: $allow_registration,
      OIDC_FORCE_HTTPS: $force_https,
      TERMIX_ADMIN_PASSWORD: $admin_password,
      SSH_PRIVATE_KEY: $ssh_private_key
    }'
)"

termix_secret_file="$(mktemp "${TMPDIR:-/tmp}/termix-secret-XXXXXX.json")"
printf '%s' "$termix_secret_payload" >"$termix_secret_file"

log "Storing Termix bootstrap secret in OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "termix" \
  --json-file "$termix_secret_file" \
  --required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL,OIDC_AUTHORIZATION_URL,OIDC_TOKEN_URL,OIDC_USERINFO_URL,OIDC_SCOPES,OIDC_ADMIN_GROUP,OIDC_ALLOWED_USERS,OIDC_ALLOW_REGISTRATION,OIDC_FORCE_HTTPS,TERMIX_ADMIN_PASSWORD"

rm -f "$termix_secret_file"

log "Applying Termix Argo CD application"
render_template "$termix_app_manifest" "$rendered_termix_app_manifest" "$public_zone_name"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_termix_app_manifest" \
  --application "termix" \
  --destination-namespace "termix" \
  --no-wait \
  >/dev/null

if kubectl -n termix get deployment termix >/dev/null 2>&1; then
  kubectl -n termix rollout restart deployment/termix >/dev/null 2>&1 || true
fi

log "===== Authentik OIDC Setup Complete ====="
log "Termix URL: ${termix_host}"
log "Client ID: ${client_id}"
log "Issuer: ${termix_oidc_issuer_url}"
log "Application: Termix"
log ""
log "After the Termix deployment is healthy:"
log "  1. Visit ${termix_host}"
log "  2. Sign in with the Termix admin account created during bootstrap"
log "  3. Current admin users will receive the Browser SSH role when setup-termix.sh runs"
log "  4. Run scripts/manager/setup-termix.sh to bootstrap the host access"
