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

start_abs_port_forward() {
  local local_port="$1"
  local log_file="$2"

  kubectl -n audiobookshelf port-forward "svc/audiobookshelf" "${local_port}:80" >"$log_file" 2>&1 &
  printf '%s\n' "$!"
}

wait_for_abs_http() {
  local base_url="$1"
  local attempts=60
  local attempt=1

  while true; do
    if curl -fsS "${base_url}/status" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Audiobookshelf HTTP endpoint did not become ready at ${base_url}"
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

resolve_cluster_json() {
  printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster'
}

cluster_json="$(resolve_cluster_json)"
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
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
AUDIOBOOKSHELF_HOST="https://audiobookshelf.${public_zone_name}"
AUDIOBOOKSHELF_ISSUER_URL="${AUTHENTIK_HOST%/}/application/o/audiobookshelf/"
AUDIOBOOKSHELF_AUTHORIZATION_URL="${AUTHENTIK_HOST%/}/application/o/authorize/"
AUDIOBOOKSHELF_TOKEN_URL="${AUTHENTIK_HOST%/}/application/o/token/"
AUDIOBOOKSHELF_USERINFO_URL="${AUTHENTIK_HOST%/}/application/o/userinfo/"
AUDIOBOOKSHELF_JWKS_URL="${AUTHENTIK_HOST%/}/application/o/audiobookshelf/jwks/"
AUDIOBOOKSHELF_MOBILE_REDIRECT_URIS='["audiobookshelf://oauth"]'

existing_audiobookshelf_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_audiobookshelf_secret_json="$(openbao_read_global_secret_json audiobookshelf 2>/dev/null || true)"
fi

audiobookshelf_root_username="root"
audiobookshelf_root_password="$(openssl rand -hex 24)"
audiobookshelf_client_id="$(openssl rand -hex 16)"
audiobookshelf_client_secret="$(openssl rand -hex 32)"

if [[ -n "$existing_audiobookshelf_secret_json" ]]; then
  existing_root_username="$(jq -r '.AUDIOBOOKSHELF_ROOT_USERNAME // empty' <<<"$existing_audiobookshelf_secret_json" || true)"
  existing_root_password="$(jq -r '.AUDIOBOOKSHELF_ROOT_PASSWORD // empty' <<<"$existing_audiobookshelf_secret_json" || true)"
  existing_client_id="$(jq -r '.AUDIOBOOKSHELF_OIDC_CLIENT_ID // empty' <<<"$existing_audiobookshelf_secret_json" || true)"
  existing_client_secret="$(jq -r '.AUDIOBOOKSHELF_OIDC_CLIENT_SECRET // empty' <<<"$existing_audiobookshelf_secret_json" || true)"

  [[ -n "$existing_root_username" ]] && audiobookshelf_root_username="$existing_root_username"
  [[ -n "$existing_root_password" ]] && audiobookshelf_root_password="$existing_root_password"
  [[ -n "$existing_client_id" ]] && audiobookshelf_client_id="$existing_client_id"
  [[ -n "$existing_client_secret" ]] && audiobookshelf_client_secret="$existing_client_secret"
fi

[[ -n "$audiobookshelf_root_username" ]] || audiobookshelf_root_username="root"
[[ -n "$audiobookshelf_root_password" ]] || audiobookshelf_root_password="$(openssl rand -hex 24)"
[[ -n "$audiobookshelf_client_id" ]] || audiobookshelf_client_id="$(openssl rand -hex 16)"
[[ -n "$audiobookshelf_client_secret" ]] || audiobookshelf_client_secret="$(openssl rand -hex 32)"

audiobookshelf_secret_file="$(mktemp)"
audiobookshelf_port_forward_log="$(mktemp "${TMPDIR:-/tmp}/audiobookshelf-port-forward-XXXXXX")"
audiobookshelf_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/audiobookshelf-application-XXXXXX")"
trap 'rm -f "$audiobookshelf_secret_file" "$audiobookshelf_port_forward_log" "$audiobookshelf_rendered_manifest"' EXIT

jq -n \
  --arg root_username "$audiobookshelf_root_username" \
  --arg root_password "$audiobookshelf_root_password" \
  --arg client_id "$audiobookshelf_client_id" \
  --arg client_secret "$audiobookshelf_client_secret" \
  '{
    "AUDIOBOOKSHELF_ROOT_USERNAME": $root_username,
    "AUDIOBOOKSHELF_ROOT_PASSWORD": $root_password,
    "AUDIOBOOKSHELF_OIDC_CLIENT_ID": $client_id,
    "AUDIOBOOKSHELF_OIDC_CLIENT_SECRET": $client_secret
  }' >"$audiobookshelf_secret_file"

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

audiobookshelf_groups_mapping_id="$(upsert_scope_mapping \
  "Audiobookshelf groups" \
  "groups" \
  "Expose Audiobookshelf role claims" \
  'groups = ["admin"] if ak_is_group_member(request.user, name="admins") else ["user"]
return {
    "groups": groups,
}' \
)"
[[ -n "$audiobookshelf_groups_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for Audiobookshelf groups"

provider_payload="$(
  jq -n \
    --arg name "Audiobookshelf" \
    --arg client_id "$audiobookshelf_client_id" \
    --arg client_secret "$audiobookshelf_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg issuer_url "$AUDIOBOOKSHELF_ISSUER_URL" \
    --arg authorize_url "$AUDIOBOOKSHELF_AUTHORIZATION_URL" \
    --arg token_url "$AUDIOBOOKSHELF_TOKEN_URL" \
    --arg userinfo_url "$AUDIOBOOKSHELF_USERINFO_URL" \
    --arg jwks_url "$AUDIOBOOKSHELF_JWKS_URL" \
    --argjson property_mappings "$(jq -cn \
      --arg openid "$openid_mapping_id" \
      --arg email "$email_mapping_id" \
      --arg profile "$profile_mapping_id" \
      --arg groups "$audiobookshelf_groups_mapping_id" \
      '[$openid, $email, $profile, $groups]'
    )" \
    --arg callback_url "${AUDIOBOOKSHELF_HOST}/auth/openid/callback" \
    --arg mobile_redirect_url "${AUDIOBOOKSHELF_HOST}/auth/openid/mobile-redirect" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      issuer_mode: "per_provider",
      include_claims_in_id_token: true,
      client_type: "confidential",
      grant_types: ["authorization_code"],
      redirect_uris: [
        {
          matching_mode: "strict",
          url: $callback_url
        },
        {
          matching_mode: "strict",
          url: $mobile_redirect_url
        }
      ],
      property_mappings: $property_mappings
    }'
)"
provider_pk="$(create_or_update_provider "Audiobookshelf" "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Audiobookshelf"

application_payload="$(
  jq -n \
    --arg name "Audiobookshelf" \
    --arg slug "audiobookshelf" \
    --arg launch_url "$AUDIOBOOKSHELF_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "audiobookshelf" "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Audiobookshelf"

log "Syncing Audiobookshelf bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "audiobookshelf" \
  --json-file "$audiobookshelf_secret_file" \
  --required-keys "AUDIOBOOKSHELF_ROOT_USERNAME,AUDIOBOOKSHELF_ROOT_PASSWORD,AUDIOBOOKSHELF_OIDC_CLIENT_ID,AUDIOBOOKSHELF_OIDC_CLIENT_SECRET"

manifest_path="$WORKSPACE_ROOT/gitops/apps/audiobookshelf.yaml"
sed \
  -e "s|__REPO_URL__|${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}|g" \
  -e "s|__TARGET_REVISION__|${TWINBOX_GIT_TARGET_REVISION:-main}|g" \
  -e "s|__ZONE_NAME__|${public_zone_name}|g" \
  "$manifest_path" >"$audiobookshelf_rendered_manifest"

log "Applying Audiobookshelf Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$audiobookshelf_rendered_manifest" \
  --application "audiobookshelf" \
  --destination-namespace "audiobookshelf"

wait_for_deployment_rollout "audiobookshelf" "audiobookshelf" "Audiobookshelf application"

port_forward_pid="$(start_abs_port_forward "18378" "$audiobookshelf_port_forward_log")"
cleanup_audiobookshelf_port_forward() {
  if [[ -n "${port_forward_pid:-}" ]]; then
    kill "$port_forward_pid" >/dev/null 2>&1 || true
    wait "$port_forward_pid" >/dev/null 2>&1 || true
  fi
}
trap 'authentik_teardown_forward; cleanup_audiobookshelf_port_forward; rm -f "$audiobookshelf_secret_file" "$audiobookshelf_port_forward_log" "$audiobookshelf_rendered_manifest"' EXIT

ABS_BASE_URL="http://127.0.0.1:18378"
wait_for_abs_http "$ABS_BASE_URL"

status_json="$(curl -fsS "$ABS_BASE_URL/status")"
is_init="$(jq -r '.isInit // false' <<<"$status_json")"
if [[ "$is_init" != "true" ]]; then
  log "Initializing Audiobookshelf root user"
  curl -fsS \
    -X POST "$ABS_BASE_URL/init" \
    -H "Content-Type: application/json" \
    -d "$(
      jq -n \
        --arg username "$audiobookshelf_root_username" \
        --arg password "$audiobookshelf_root_password" \
        '{newRoot: {username: $username, password: $password}}'
    )" >/dev/null
fi

login_response="$(curl -fsS \
  -X POST "$ABS_BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d "$(
    jq -n \
      --arg username "$audiobookshelf_root_username" \
      --arg password "$audiobookshelf_root_password" \
      '{username: $username, password: $password}'
  )")"

audiobookshelf_api_token="$(jq -r '.user.token // empty' <<<"$login_response")"
[[ -n "$audiobookshelf_api_token" ]] || fail "Could not obtain an Audiobookshelf API token from /login"

auth_settings_payload="$(
  jq -n \
    --argjson auth_active_auth_methods '["local","openid"]' \
    --arg auth_openid_issuer_url "$AUDIOBOOKSHELF_ISSUER_URL" \
    --arg auth_openid_authorization_url "$AUDIOBOOKSHELF_AUTHORIZATION_URL" \
    --arg auth_openid_token_url "$AUDIOBOOKSHELF_TOKEN_URL" \
    --arg auth_openid_userinfo_url "$AUDIOBOOKSHELF_USERINFO_URL" \
    --arg auth_openid_jwks_url "$AUDIOBOOKSHELF_JWKS_URL" \
    --arg auth_openid_client_id "$audiobookshelf_client_id" \
    --arg auth_openid_client_secret "$audiobookshelf_client_secret" \
    --arg auth_openid_button_text "Sign in with Authentik" \
    --arg auth_openid_match_existing_by "preferred_username" \
    --arg auth_openid_group_claim "groups" \
    --arg auth_openid_subfolder_for_redirect_urls "" \
    --argjson auth_openid_auto_launch true \
    --argjson auth_openid_auto_register true \
    --argjson auth_openid_mobile_redirect_uris '["audiobookshelf://oauth"]' \
    '{
      authActiveAuthMethods: $auth_active_auth_methods,
      authOpenIDIssuerURL: $auth_openid_issuer_url,
      authOpenIDAuthorizationURL: $auth_openid_authorization_url,
      authOpenIDTokenURL: $auth_openid_token_url,
      authOpenIDUserInfoURL: $auth_openid_userinfo_url,
      authOpenIDJwksURL: $auth_openid_jwks_url,
      authOpenIDClientID: $auth_openid_client_id,
      authOpenIDClientSecret: $auth_openid_client_secret,
      authOpenIDButtonText: $auth_openid_button_text,
      authOpenIDMatchExistingBy: $auth_openid_match_existing_by,
      authOpenIDGroupClaim: $auth_openid_group_claim,
      authOpenIDSubfolderForRedirectURLs: $auth_openid_subfolder_for_redirect_urls,
      authOpenIDAutoLaunch: $auth_openid_auto_launch,
      authOpenIDAutoRegister: $auth_openid_auto_register,
      authOpenIDMobileRedirectURIs: $auth_openid_mobile_redirect_uris
    }'
)"

log "Applying Audiobookshelf Authentik settings"
curl -fsS \
  -X PATCH "$ABS_BASE_URL/api/auth-settings" \
  -H "Authorization: Bearer ${audiobookshelf_api_token}" \
  -H "Content-Type: application/json" \
  -d "$auth_settings_payload" >/dev/null

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg public_url "$AUDIOBOOKSHELF_HOST" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      public_url: $public_url
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "audiobookshelf" \
  --service-domain "audiobookshelf.${public_zone_name}" \
  --service-path /

log "Audiobookshelf installation completed"
