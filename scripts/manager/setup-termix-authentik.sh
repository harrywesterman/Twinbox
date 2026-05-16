#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export KUBECONFIG="${KUBECONFIG_FILE:-$KUBECONFIG}"

# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

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

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"

api_get() {
  local path="$1"
  curl -fsS \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    -H "Accept: application/json" \
    "${AUTHENTIK_API_BASE}${path}"
}

api_write() {
  local method="$1"
  local path="$2"
  local payload="$3"
  curl -fsS \
    -X "$method" \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "${AUTHENTIK_API_BASE}${path}"
}

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  api_get "/providers/oauth2/?page_size=100" | jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  api_get "/core/applications/${application_slug}/" 2>/dev/null || true
}

create_or_update_oauth2_provider() {
  local provider_name="$1"
  local provider_payload="$2"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    log "OAuth2 provider '${provider_name}' already exists (pk=${existing_pk}), updating"
    api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" | jq -r '.pk // .id // empty'
    return 0
  fi

  log "Creating OAuth2 provider '${provider_name}'"
  api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug")"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    log "Application '${application_slug}' already exists (pk=${existing_pk}), updating"
    api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  log "Creating application '${application_slug}'"
  api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
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

  existing_pk="$(
    api_get "/policies/bindings/?page_size=200" | jq -r \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '.results[]?
        | select((.target // "") == $target_uuid and (.group // "") == $group_id)
        | .pk // .id // empty' | head -n1
  )"
  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
    return 0
  fi

  api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
}

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
signing_key_id="$(authentik_resolve_signing_key_id)"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

log "Provisioning Authentik OIDC provider for Termix"

# Generate a random client_secret since Authentik auto-generates and
# we need to capture it. We'll read it back from the provider after creation.
provider_payload="$(
  jq -n \
    --arg name "Termix" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uris "https://termix.${public_zone_name}/users/oidc/callback" \
    '{
      name: $name,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      redirect_uris: $redirect_uris,
      access_code_validity: "minutes=1",
      access_token_validity: "minutes=5",
      include_claims_from_id_token: true
    }'
)"

provider_result="$(create_or_update_oauth2_provider "Termix" "$provider_payload")"
[[ -n "$provider_result" ]] || fail "Authentik did not return an OAuth2 provider ID for Termix"

provider_pk="$(jq -r '.' <<<"$provider_result" 2>/dev/null || printf '%s' "$provider_result")"

# Read back the provider to get the auto-generated client_id and client_secret
provider_detail="$(api_get "/providers/oauth2/${provider_pk}/")"
client_id="$(jq -r '.client_id // empty' <<<"$provider_detail")"
client_secret="$(jq -r '.client_secret // empty' <<<"$provider_detail")"
[[ -n "$client_id" ]] || fail "Could not read client_id from OAuth2 provider"
[[ -n "$client_secret" ]] || fail "Could not read client_secret from OAuth2 provider"

log "OAuth2 provider created with client_id=${client_id}"

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
application_uuid="$(create_or_update_application "termix" "$application_payload")"
[[ -n "$application_uuid" ]] || fail "Authentik did not return an application ID for Termix"

# Bind to admins group
application_json="$(find_application_json_by_slug "termix")"
application_pk="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_pk" ]] || fail "Could not determine Authentik application UUID for Termix"
ensure_group_binding "$application_pk" "$admins_group_id"

# Build the OpenBao secret payload
openbao_payload="$(
  jq -n \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    --arg issuer_url "https://authentik.${public_zone_name}/application/o/termix/" \
    --arg authorization_url "https://authentik.${public_zone_name}/application/o/authorize/" \
    --arg token_url "https://authentik.${public_zone_name}/application/o/token/" \
    --arg userinfo_url "https://authentik.${public_zone_name}/application/o/userinfo/" \
    '{
      OIDC_CLIENT_ID: $client_id,
      OIDC_CLIENT_SECRET: $client_secret,
      OIDC_ISSUER_URL: $issuer_url,
      OIDC_AUTHORIZATION_URL: $authorization_url,
      OIDC_TOKEN_URL: $token_url,
      OIDC_USERINFO_URL: $userinfo_url,
      SSH_PRIVATE_KEY: ""
    }'
)"

tmp_file="$(mktemp)"
printf '%s' "$openbao_payload" >"$tmp_file"

log "Storing Termix OIDC secrets in OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "termix" \
  --json-file "$tmp_file" \
  --required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL"

rm -f "$tmp_file"

log "Syncing ExternalSecret to pull the new values"
kubectl -n termix delete externalsecret termix-bootstrap --ignore-not-found
kubectl -n termix delete secret termix-bootstrap --ignore-not-found
sleep 2
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/termix/externalsecret.yaml"

log "===== Authentik OIDC Setup Complete ====="
log "Termix URL: ${termix_host}"
log "Client ID: ${client_id}"
log "Issuer: https://authentik.${public_zone_name}/application/o/termix/"
log ""
log "After the Argo CD app syncs and the Termix pod restarts:"
log "  1. Visit ${termix_host}"
log "  2. Create the admin account via the first-run setup"
log "  3. OIDC login via Authentik will be available"
log "  4. Run scripts/manager/setup-termix.sh to bootstrap hosts"
echo ""
