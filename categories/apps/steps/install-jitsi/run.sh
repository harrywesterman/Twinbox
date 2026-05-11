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

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?page_size=100")" || return 1
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true
}

find_scope_mapping_pk_by_name() {
  local mapping_name="$1"
  local scope_name="$2"
  local response

  response="$(authentik_api_get "/propertymappings/provider/scope/?page_size=200")" || return 1
  jq -r \
    --arg mapping_name "$mapping_name" \
    --arg scope_name "$scope_name" \
    '.results[]?
      | select((.name // "") == $mapping_name and (.scope_name // "") == $scope_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

create_or_update_scope_mapping() {
  local mapping_name="$1"
  local scope_name="$2"
  local description="$3"
  local expression="$4"
  local payload existing_pk

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

  existing_pk="$(find_scope_mapping_pk_by_name "$mapping_name" "$scope_name")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/propertymappings/provider/scope/${existing_pk}/" "$payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/propertymappings/provider/scope/" "$payload" | jq -r '.pk // .id // empty'
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Jitsi broker")"
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

  existing_json="$(find_application_json_by_slug "$application_slug")"
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

find_policy_binding_pk() {
  local target_uuid="$1"
  local group_id="$2"
  local response

  response="$(authentik_api_get "/policies/bindings/?page_size=200")" || return 1
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
    return 0
  fi

  authentik_api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
}

ensure_group() {
  local group_name="$1"
  local is_superuser="${2:-false}"
  local payload group_id

  payload="$(
    jq -n \
      --arg name "$group_name" \
      --argjson is_superuser "$is_superuser" \
      '{name: $name, is_superuser: $is_superuser}'
  )"

  group_id="$(authentik_find_group_id "$group_name" || true)"
  if [[ -n "$group_id" ]]; then
    authentik_api_write PATCH "/core/groups/${group_id}/" "$payload" >/dev/null
    printf '%s\n' "$group_id"
    return 0
  fi

  authentik_api_write POST "/core/groups/" "$payload" | jq -r '.pk // .id // empty'
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
jitsi_host="https://jitsi.${public_zone_name}"
broker_host="https://auth-jitsi.${public_zone_name}"
jitsi_application_slug="jitsi-openid"
jitsi_issuer_url="${AUTHENTIK_HOST%/}/application/o/${jitsi_application_slug}/"
jitsi_client_id="$(openssl rand -hex 16)"
jitsi_client_secret="$(openssl rand -hex 24)"
jwt_app_id="jitsi"
jwt_app_secret="$(openssl rand -hex 32)"
jitsi_sub="jitsi.${public_zone_name}"
broker_session_secret="$(openssl rand -hex 32)"
jicofo_auth_password="$(openssl rand -hex 16)"
jvb_auth_user="jvb"
jvb_auth_password="$(openssl rand -hex 16)"
jitsi_hosts_group_name="jitsi-hosts"
secrets_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global"
jitsi_secret_file="${secrets_dir}/jitsi-auth-${cluster_id}.json"
jitsi_manifest_path="$WORKSPACE_ROOT/gitops/apps/jitsi.yaml"
jitsi_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/jitsi-application-XXXXXX.yaml")"
jitsi_namespace_manifest="$WORKSPACE_ROOT/gitops/platform-apps/jitsi/namespace.yaml"
jitsi_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform-apps/jitsi/externalsecret.yaml"
trap 'rm -f "$jitsi_rendered_manifest" "$jitsi_secret_file"' EXIT

mkdir -p "$secrets_dir"

existing_jitsi_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_jitsi_secret_json="$(openbao_read_global_secret_json jitsi-auth 2>/dev/null || true)"
fi

if [[ -n "$existing_jitsi_secret_json" ]]; then
  existing_client_id="$(jq -r '.CLIENT_ID // .AUTHENTIK_CLIENT_ID // empty' <<<"$existing_jitsi_secret_json")"
  existing_client_secret="$(jq -r '.CLIENT_SECRET // .AUTHENTIK_CLIENT_SECRET // empty' <<<"$existing_jitsi_secret_json")"
  existing_jwt_app_secret="$(jq -r '.JWT_APP_SECRET // empty' <<<"$existing_jitsi_secret_json")"
  existing_broker_session_secret="$(jq -r '.BROKER_SESSION_SECRET // empty' <<<"$existing_jitsi_secret_json")"
  existing_jicofo_auth_password="$(jq -r '.JICOFO_AUTH_PASSWORD // empty' <<<"$existing_jitsi_secret_json")"
  existing_jvb_auth_user="$(jq -r '.JVB_AUTH_USER // empty' <<<"$existing_jitsi_secret_json")"
  existing_jvb_auth_password="$(jq -r '.JVB_AUTH_PASSWORD // empty' <<<"$existing_jitsi_secret_json")"

  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    jitsi_client_id="$existing_client_id"
    jitsi_client_secret="$existing_client_secret"
  fi
  if [[ -n "$existing_jwt_app_secret" ]]; then
    jwt_app_secret="$existing_jwt_app_secret"
  fi
  if [[ -n "$existing_broker_session_secret" ]]; then
    broker_session_secret="$existing_broker_session_secret"
  fi
  if [[ -n "$existing_jicofo_auth_password" ]]; then
    jicofo_auth_password="$existing_jicofo_auth_password"
  fi
  if [[ -n "$existing_jvb_auth_user" ]]; then
    jvb_auth_user="$existing_jvb_auth_user"
  fi
  if [[ -n "$existing_jvb_auth_password" ]]; then
    jvb_auth_password="$existing_jvb_auth_password"
  fi
fi

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
admins_group_id="$(authentik_find_group_id "admins")"
jitsi_hosts_group_id="$(ensure_group "$jitsi_hosts_group_name" false)"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"
[[ -n "$jitsi_hosts_group_id" ]] || fail "Could not create Authentik jitsi-hosts group"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"

jitsi_affiliation_expression="$(
  cat <<'EOF'
if ak_is_group_member(request.user, name="admins") or ak_is_group_member(request.user, name="jitsi-hosts"):
    return {
        "affiliation": "owner",
        "moderator": True,
    }
return {
    "affiliation": "member",
    "moderator": False,
}
EOF
)"
jitsi_scope_mapping_id="$(
  create_or_update_scope_mapping \
    "Jitsi host affiliation" \
    "jitsi" \
    "Map Authentik host groups to Jitsi token roles." \
    "$jitsi_affiliation_expression"
)"
[[ -n "$jitsi_scope_mapping_id" ]] || fail "Could not create or update Authentik scope mapping for Jitsi"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    --arg jitsi "$jitsi_scope_mapping_id" \
    '[$openid, $email, $profile, $jitsi]'
)"

provider_payload="$(
  jq -n \
    --arg name "Jitsi broker" \
    --arg client_id "$jitsi_client_id" \
    --arg client_secret "$jitsi_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "${broker_host}/callback" \
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
      issuer_mode: "per_provider"
    }'
)"

log "Provisioning Authentik OIDC client for Jitsi broker"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Jitsi"

application_payload="$(
  jq -n \
    --arg name "Jitsi broker" \
    --arg slug "$jitsi_application_slug" \
    --arg launch_url "$jitsi_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$jitsi_application_slug" "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Jitsi"

application_json="$(find_application_json_by_slug "$jitsi_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Jitsi"
ensure_group_binding "$application_uuid" "$admins_group_id"
ensure_group_binding "$application_uuid" "$jitsi_hosts_group_id"

jq -n \
  --arg jwt_app_id "$jwt_app_id" \
  --arg jwt_app_secret "$jwt_app_secret" \
  --arg jitsi_secret "$jwt_app_secret" \
  --arg jitsi_url "$jitsi_host" \
  --arg jitsi_sub "$jitsi_sub" \
  --arg issuer_url "$jitsi_issuer_url" \
  --arg authentik_issuer_url "$jitsi_issuer_url" \
  --arg client_id "$jitsi_client_id" \
  --arg authentik_client_id "$jitsi_client_id" \
  --arg client_secret "$jitsi_client_secret" \
  --arg authentik_client_secret "$jitsi_client_secret" \
  --arg base_url "$broker_host" \
  --arg broker_base_url "$broker_host" \
  --arg broker_session_secret "$broker_session_secret" \
  --arg jicofo_auth_password "$jicofo_auth_password" \
  --arg jvb_auth_user "$jvb_auth_user" \
  --arg jvb_auth_password "$jvb_auth_password" \
  '{
    JWT_APP_ID: $jwt_app_id,
    JWT_APP_SECRET: $jwt_app_secret,
    JITSI_SECRET: $jitsi_secret,
    JITSI_URL: $jitsi_url,
    JITSI_SUB: $jitsi_sub,
    ISSUER_URL: $issuer_url,
    AUTHENTIK_ISSUER_URL: $authentik_issuer_url,
    CLIENT_ID: $client_id,
    AUTHENTIK_CLIENT_ID: $authentik_client_id,
    CLIENT_SECRET: $client_secret,
    AUTHENTIK_CLIENT_SECRET: $authentik_client_secret,
    BASE_URL: $base_url,
    BROKER_BASE_URL: $broker_base_url,
    BROKER_SESSION_SECRET: $broker_session_secret,
    JICOFO_AUTH_PASSWORD: $jicofo_auth_password,
    JVB_AUTH_USER: $jvb_auth_user,
    JVB_AUTH_PASSWORD: $jvb_auth_password
  }' >"$jitsi_secret_file"
chmod 600 "$jitsi_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "jitsi-auth" \
  --json-file "$jitsi_secret_file" \
  --required-keys "JWT_APP_ID,JWT_APP_SECRET,JITSI_SECRET,JITSI_URL,JITSI_SUB,ISSUER_URL,AUTHENTIK_ISSUER_URL,CLIENT_ID,AUTHENTIK_CLIENT_ID,CLIENT_SECRET,AUTHENTIK_CLIENT_SECRET,BASE_URL,BROKER_BASE_URL,BROKER_SESSION_SECRET,JICOFO_AUTH_PASSWORD,JVB_AUTH_USER,JVB_AUTH_PASSWORD"

log "Applying Jitsi namespace baseline"
kubectl apply -f "$jitsi_namespace_manifest"

log "Applying Jitsi ExternalSecret"
kubectl apply -f "$jitsi_externalsecret_manifest"
kubectl -n jitsi wait --for=condition=Ready externalsecret/jitsi-auth --timeout=10m

sed "s/__ZONE_NAME__/${public_zone_name}/g" "$jitsi_manifest_path" >"$jitsi_rendered_manifest"

log "Applying Jitsi Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$jitsi_rendered_manifest" \
  --application "jitsi" \
  --destination-namespace "jitsi"

if kubectl -n jitsi get deployment/auth-jitsi >/dev/null 2>&1; then
  log "Restarting Auth Jitsi broker to pick up the latest Twinbox-pinned image"
  kubectl -n jitsi rollout restart deployment/auth-jitsi
  kubectl -n jitsi rollout status deployment/auth-jitsi --timeout=10m
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "jitsi" \
    --arg manifest_path "$jitsi_manifest_path" \
    --arg host "$jitsi_host" \
    --arg broker_host "$broker_host" \
    --arg provider_pk "$provider_pk" \
    '{
      application: $application,
      manifest_path: $manifest_path,
      host: $host,
      broker_host: $broker_host,
      provider_pk: $provider_pk
    }' >"$STEP_RESULT_FILE"
fi
