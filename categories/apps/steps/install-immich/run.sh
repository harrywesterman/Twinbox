#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

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

wait_for_resources_ready() {
  local namespace="$1"
  local kind="$2"
  local condition="$3"
  local label="$4"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$namespace" get "$kind" -o name 2>/dev/null | grep -q .; then
      if kubectl -n "$namespace" wait --for="condition=${condition}" "$kind" --all --timeout=5s >/dev/null 2>&1; then
        log "${label} resources are ready"
        return 0
      fi

      log "Waiting for ${label} resources to become ready"
    else
      log "Waiting for ${label} resources to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} resources did not become ready after ${attempts} attempts"
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
  local progressing_status=""
  local progressing_reason=""
  local available_status=""
  local available_reason=""
  local message=""

  while true; do
    if status_json="$(kubectl -n "$namespace" get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"
      progressing_status="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .status // "Unknown"' <<<"$status_json")"
      progressing_reason="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .reason // empty' <<<"$status_json")"
      available_status="$(jq -r '.status.conditions[]? | select(.type == "Available") | .status // "Unknown"' <<<"$status_json")"
      available_reason="$(jq -r '.status.conditions[]? | select(.type == "Available") | .reason // empty' <<<"$status_json")"
      message="$(jq -r '.status.conditions[]? | select(.type == "Progressing" or .type == "Available") | .message // empty' <<<"$status_json" | awk 'NF { if (out) out = out " | "; out = out $0 } END { print out }')"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}, progressing=${progressing_status}${progressing_reason:+/${progressing_reason}}, available=${available_status}${available_reason:+/${available_reason}}${message:+, message=${message}}"
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

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local response

  response="$(authentik_api_get "/core/applications/?page_size=100")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug)' <<<"$response" | head -n1
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Immich")"
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

  existing_json="$(find_application_json_by_slug "immich" || true)"
  existing_pk=""
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  fi
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/immich/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

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
  local response

  response="$(authentik_api_get "/policies/bindings/?page_size=200")"
  jq -r \
    --arg target_uuid "$target_uuid" \
    --arg group_id "$group_id" \
    '.results[]?
      | select((.target // "") == $target_uuid and (.group // "") == $group_id)
      | .pk // .id // empty' <<<"$response" | head -n1
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

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
IMMICH_HOST="https://immich.${public_zone_name}"
IMMICH_MOBILE_REDIRECT_URI="${IMMICH_MOBILE_REDIRECT_URI:-app.immich:///oauth-callback}"
databases_namespace_manifest="$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
immich_db_cluster_manifest="$WORKSPACE_ROOT/gitops/databases/immich/cluster.yaml"
immich_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/databases/immich/externalsecret.yaml"
immich_app_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform-apps/immich/db-externalsecret.yaml"
immich_db_pooler_ro_manifest="$WORKSPACE_ROOT/gitops/databases/immich/pooler-ro.yaml"
immich_db_pooler_rw_manifest="$WORKSPACE_ROOT/gitops/databases/immich/pooler-rw.yaml"
immich_db_backup_manifest="$WORKSPACE_ROOT/gitops/databases/immich/scheduled-backup.yaml"

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"
admins_group_id="$(authentik_find_group_id "admins")"
[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

existing_immich_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_immich_secret_json="$(openbao_read_global_secret_json immich 2>/dev/null || true)"
fi

immich_db_username="immich"
immich_db_password="$(openssl rand -hex 24)"
immich_client_id="$(openssl rand -hex 16)"
immich_client_secret="$(openssl rand -hex 32)"
immich_oauth_enabled="true"
immich_oauth_scope="openid email profile"
immich_oauth_button_text="Sign in with Authentik"
immich_oauth_auto_register="true"
immich_oauth_auto_launch="true"
immich_oauth_signing_algorithm="RS256"
immich_oauth_profile_signing_algorithm="none"
immich_oauth_token_endpoint_auth_method="client_secret_post"
immich_oauth_storage_label_claim="preferred_username"
immich_oauth_storage_quota_claim="immich_quota"
immich_oauth_role_claim="immich_role"
immich_oauth_mobile_override_enabled="false"
immich_oauth_mobile_redirect_uri="$IMMICH_MOBILE_REDIRECT_URI"
immich_server_external_domain="$IMMICH_HOST"

if [[ -n "$existing_immich_secret_json" ]]; then
  immich_db_username="$(jq -r '.IMMICH_POSTGRESQL__USERNAME // empty' <<<"$existing_immich_secret_json" || true)"
  immich_db_password="$(jq -r '.IMMICH_POSTGRESQL__PASSWORD // empty' <<<"$existing_immich_secret_json" || true)"
  immich_client_id="$(jq -r '.IMMICH_OAUTH_CLIENT_ID // empty' <<<"$existing_immich_secret_json" || true)"
  immich_client_secret="$(jq -r '.IMMICH_OAUTH_CLIENT_SECRET // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_enabled="$(jq -r '.IMMICH_OAUTH_ENABLED // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_scope="$(jq -r '.IMMICH_OAUTH_SCOPE // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_button_text="$(jq -r '.IMMICH_OAUTH_BUTTON_TEXT // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_auto_register="$(jq -r '.IMMICH_OAUTH_AUTO_REGISTER // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_auto_launch="$(jq -r '.IMMICH_OAUTH_AUTO_LAUNCH // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_signing_algorithm="$(jq -r '.IMMICH_OAUTH_SIGNING_ALGORITHM // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_profile_signing_algorithm="$(jq -r '.IMMICH_OAUTH_PROFILE_SIGNING_ALGORITHM // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_token_endpoint_auth_method="$(jq -r '.IMMICH_OAUTH_TOKEN_ENDPOINT_AUTH_METHOD // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_storage_label_claim="$(jq -r '.IMMICH_OAUTH_STORAGE_LABEL_CLAIM // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_storage_quota_claim="$(jq -r '.IMMICH_OAUTH_STORAGE_QUOTA_CLAIM // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_role_claim="$(jq -r '.IMMICH_OAUTH_ROLE_CLAIM // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_mobile_override_enabled="$(jq -r '.IMMICH_OAUTH_MOBILE_OVERRIDE_ENABLED // empty' <<<"$existing_immich_secret_json" || true)"
  immich_oauth_mobile_redirect_uri="$(jq -r '.IMMICH_OAUTH_MOBILE_REDIRECT_URI // empty' <<<"$existing_immich_secret_json" || true)"
  immich_server_external_domain="$(jq -r '.IMMICH_SERVER_EXTERNAL_DOMAIN // empty' <<<"$existing_immich_secret_json" || true)"
fi

[[ -n "$immich_db_username" ]] || immich_db_username="immich"
[[ -n "$immich_db_password" ]] || immich_db_password="$(openssl rand -hex 24)"
[[ -n "$immich_client_id" ]] || immich_client_id="$(openssl rand -hex 16)"
[[ -n "$immich_client_secret" ]] || immich_client_secret="$(openssl rand -hex 32)"
[[ -n "$immich_oauth_enabled" ]] || immich_oauth_enabled="true"
[[ -n "$immich_oauth_scope" ]] || immich_oauth_scope="openid email profile"
[[ -n "$immich_oauth_button_text" ]] || immich_oauth_button_text="Sign in with Authentik"
[[ -n "$immich_oauth_auto_register" ]] || immich_oauth_auto_register="true"
[[ -n "$immich_oauth_auto_launch" ]] || immich_oauth_auto_launch="false"
[[ -n "$immich_oauth_signing_algorithm" ]] || immich_oauth_signing_algorithm="RS256"
[[ -n "$immich_oauth_profile_signing_algorithm" ]] || immich_oauth_profile_signing_algorithm="none"
[[ -n "$immich_oauth_token_endpoint_auth_method" ]] || immich_oauth_token_endpoint_auth_method="client_secret_post"
[[ -n "$immich_oauth_storage_label_claim" ]] || immich_oauth_storage_label_claim="preferred_username"
[[ -n "$immich_oauth_storage_quota_claim" ]] || immich_oauth_storage_quota_claim="immich_quota"
[[ -n "$immich_oauth_role_claim" ]] || immich_oauth_role_claim="immich_role"
[[ -n "$immich_oauth_mobile_override_enabled" ]] || immich_oauth_mobile_override_enabled="false"
[[ -n "$immich_oauth_mobile_redirect_uri" ]] || immich_oauth_mobile_redirect_uri="$IMMICH_MOBILE_REDIRECT_URI"
[[ -n "$immich_server_external_domain" ]] || immich_server_external_domain="$IMMICH_HOST"
[[ "$immich_oauth_auto_launch" == "true" ]] || immich_oauth_auto_launch="true"

immich_secret_file="$(mktemp)"
trap 'rm -f "$immich_secret_file" "${immich_rendered_ingressroute_file:-}"' EXIT
jq -n \
  --arg immich_postgresql_username "$immich_db_username" \
  --arg immich_postgresql_password "$immich_db_password" \
  --arg immich_oauth_enabled "$immich_oauth_enabled" \
  --arg immich_oauth_issuer_url "${AUTHENTIK_HOST%/}/application/o/immich/.well-known/openid-configuration" \
  --arg immich_oauth_client_id "$immich_client_id" \
  --arg immich_oauth_client_secret "$immich_client_secret" \
  --arg immich_oauth_scope "$immich_oauth_scope" \
  --arg immich_oauth_button_text "$immich_oauth_button_text" \
  --arg immich_oauth_auto_register "$immich_oauth_auto_register" \
  --arg immich_oauth_auto_launch "$immich_oauth_auto_launch" \
  --arg immich_oauth_signing_algorithm "$immich_oauth_signing_algorithm" \
  --arg immich_oauth_profile_signing_algorithm "$immich_oauth_profile_signing_algorithm" \
  --arg immich_oauth_token_endpoint_auth_method "$immich_oauth_token_endpoint_auth_method" \
  --arg immich_oauth_storage_label_claim "$immich_oauth_storage_label_claim" \
  --arg immich_oauth_storage_quota_claim "$immich_oauth_storage_quota_claim" \
  --arg immich_oauth_role_claim "$immich_oauth_role_claim" \
  --arg immich_oauth_mobile_override_enabled "$immich_oauth_mobile_override_enabled" \
  --arg immich_oauth_mobile_redirect_uri "$immich_oauth_mobile_redirect_uri" \
  --arg immich_server_external_domain "$immich_server_external_domain" \
  '{
    "IMMICH_POSTGRESQL__USERNAME": $immich_postgresql_username,
    "IMMICH_POSTGRESQL__PASSWORD": $immich_postgresql_password,
    "IMMICH_OAUTH_ENABLED": $immich_oauth_enabled,
    "IMMICH_OAUTH_ISSUER_URL": $immich_oauth_issuer_url,
    "IMMICH_OAUTH_CLIENT_ID": $immich_oauth_client_id,
    "IMMICH_OAUTH_CLIENT_SECRET": $immich_oauth_client_secret,
    "IMMICH_OAUTH_SCOPE": $immich_oauth_scope,
    "IMMICH_OAUTH_BUTTON_TEXT": $immich_oauth_button_text,
    "IMMICH_OAUTH_AUTO_REGISTER": $immich_oauth_auto_register,
    "IMMICH_OAUTH_AUTO_LAUNCH": $immich_oauth_auto_launch,
    "IMMICH_OAUTH_SIGNING_ALGORITHM": $immich_oauth_signing_algorithm,
    "IMMICH_OAUTH_PROFILE_SIGNING_ALGORITHM": $immich_oauth_profile_signing_algorithm,
    "IMMICH_OAUTH_TOKEN_ENDPOINT_AUTH_METHOD": $immich_oauth_token_endpoint_auth_method,
    "IMMICH_OAUTH_STORAGE_LABEL_CLAIM": $immich_oauth_storage_label_claim,
    "IMMICH_OAUTH_STORAGE_QUOTA_CLAIM": $immich_oauth_storage_quota_claim,
    "IMMICH_OAUTH_ROLE_CLAIM": $immich_oauth_role_claim,
    "IMMICH_OAUTH_MOBILE_OVERRIDE_ENABLED": $immich_oauth_mobile_override_enabled,
    "IMMICH_OAUTH_MOBILE_REDIRECT_URI": $immich_oauth_mobile_redirect_uri,
    "IMMICH_SERVER_EXTERNAL_DOMAIN": $immich_server_external_domain
  }' >"$immich_secret_file"

log "Provisioning Authentik OIDC client for Immich"
authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"

immich_role_mapping_id="$(upsert_scope_mapping \
  "Immich role" \
  "profile" \
  "Expose the Immich admin role for the Twinbox admins group" \
  'if ak_is_group_member(request.user, name="admins"):
    return {
        "immich_role": "admin"
    }
return {
    "immich_role": "user"
}' \
)"
[[ -n "$immich_role_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for Immich role"

provider_payload="$(
  jq -n \
    --arg name "Immich" \
    --arg client_id "$immich_client_id" \
    --arg client_secret "$immich_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --argjson property_mappings "$(jq -cn \
      --arg openid "$openid_mapping_id" \
      --arg email "$email_mapping_id" \
      --arg profile "$profile_mapping_id" \
      --arg immich_role "$immich_role_mapping_id" \
      '[$openid, $email, $profile, $immich_role]'
    )" \
    --arg redirect_login "${IMMICH_HOST}/auth/login" \
    --arg redirect_settings "${IMMICH_HOST}/user-settings" \
    --arg redirect_mobile "app.immich:///oauth-callback" \
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
          url: $redirect_login
        },
        {
          matching_mode: "strict",
          url: $redirect_settings
        },
        {
          matching_mode: "strict",
          url: $redirect_mobile
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      issuer_mode: "per_provider"
    }'
)"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Immich"

application_payload="$(
  jq -n \
    --arg name "Immich" \
    --arg slug "immich" \
    --arg launch_url "$IMMICH_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Immich"

application_json="$(find_application_json_by_slug "immich")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Immich"
ensure_group_binding "$application_uuid" "$admins_group_id"

log "Writing Immich bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "immich" \
  --json-file "$immich_secret_file" \
  --required-keys "IMMICH_POSTGRESQL__USERNAME,IMMICH_POSTGRESQL__PASSWORD,IMMICH_OAUTH_ENABLED,IMMICH_OAUTH_ISSUER_URL,IMMICH_OAUTH_CLIENT_ID,IMMICH_OAUTH_CLIENT_SECRET,IMMICH_OAUTH_SCOPE,IMMICH_OAUTH_BUTTON_TEXT,IMMICH_OAUTH_AUTO_REGISTER,IMMICH_OAUTH_AUTO_LAUNCH,IMMICH_OAUTH_SIGNING_ALGORITHM,IMMICH_OAUTH_PROFILE_SIGNING_ALGORITHM,IMMICH_OAUTH_TOKEN_ENDPOINT_AUTH_METHOD,IMMICH_OAUTH_STORAGE_LABEL_CLAIM,IMMICH_OAUTH_STORAGE_QUOTA_CLAIM,IMMICH_OAUTH_ROLE_CLAIM,IMMICH_OAUTH_MOBILE_OVERRIDE_ENABLED,IMMICH_OAUTH_MOBILE_REDIRECT_URI,IMMICH_SERVER_EXTERNAL_DOMAIN"

log "Applying Immich namespace, storage, and OAuth secret resources"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/immich/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/immich/pvc.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/immich/externalsecret.yaml"
kubectl apply -f "$immich_app_db_externalsecret_manifest"

immich_rendered_ingressroute_file="$(mktemp "${TMPDIR:-/tmp}/immich-ingressroute.XXXXXX.yaml")"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/platform-apps/immich/ingressroute.yaml" >"$immich_rendered_ingressroute_file"
kubectl apply -f "$immich_rendered_ingressroute_file"

wait_for_resources_ready "immich" "externalsecret" "Ready" "Immich ExternalSecret"

log "Applying Immich database manifests"
kubectl apply -f "$databases_namespace_manifest"
kubectl apply -f "$immich_db_cluster_manifest"
kubectl apply -f "$immich_db_externalsecret_manifest"
kubectl apply -f "$immich_db_pooler_ro_manifest"
kubectl apply -f "$immich_db_pooler_rw_manifest"
kubectl apply -f "$immich_db_backup_manifest"

wait_for_resources_ready "databases" "cluster" "Ready" "CloudNativePG cluster"
wait_for_resources_ready "databases" "externalsecret" "Ready" "Database ExternalSecret"
wait_for_resources_ready "databases" "deployment" "Available" "Pooler deployment"

log "Applying Immich Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/immich.yaml" \
  --application "immich"

wait_for_deployment_rollout "immich" "immich-server" "Immich server"
wait_for_deployment_rollout "immich" "immich-machine-learning" "Immich machine learning"
wait_for_deployment_rollout "immich" "immich-valkey" "Immich valkey"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "immich" \
    --arg database "immich-db" \
    --arg public_url "$IMMICH_HOST" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      database: $database,
      public_url: $public_url
    }' >"$STEP_RESULT_FILE"
fi
