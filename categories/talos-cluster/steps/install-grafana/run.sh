#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
export KUBECONFIG="$KUBECONFIG_FILE"
manifest_path="$WORKSPACE_ROOT/gitops/apps/grafana.yaml"
grafana_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform/grafana/externalsecret.yaml"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
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

grafana_host="https://grafana.${public_zone_name}"
grafana_redirect_uri="${grafana_host}/login/generic_oauth"
grafana_application_slug="grafana"
grafana_client_id="$(openssl rand -hex 16)"
grafana_client_secret="$(openssl rand -hex 24)"
grafana_secret_file="$BOOTSTRAP_ROOT/secrets/global/grafana-oidc-${cluster_id}.json"

mkdir -p "$(dirname "$grafana_secret_file")"

existing_grafana_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_grafana_secret_json="$(openbao_read_global_secret_json grafana-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_grafana_secret_json" ]]; then
  existing_client_id="$(jq -r '.GF_AUTH_GENERIC_OAUTH_CLIENT_ID // empty' <<<"$existing_grafana_secret_json")"
  existing_client_secret="$(jq -r '.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET // empty' <<<"$existing_grafana_secret_json")"
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    grafana_client_id="$existing_client_id"
    grafana_client_secret="$existing_client_secret"
  fi
fi

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

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Grafana")"
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

  existing_json="$(find_application_json_by_slug "$grafana_application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${grafana_application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

ensure_group_binding() {
  local target_uuid="$1"
  local group_id="$2"
  local binding_payload existing_pk

  binding_payload="$(
    jq -n \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '{target: $target_uuid, group: $group_id, order: 1}'
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
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "Grafana" \
    --arg client_id "$grafana_client_id" \
    --arg client_secret "$grafana_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg redirect_uri "$grafana_redirect_uri" \
    --argjson property_mappings "$property_mapping_ids_json" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Grafana"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Grafana"

application_payload="$(
  jq -n \
    --arg name "Grafana" \
    --arg slug "$grafana_application_slug" \
    --arg launch_url "$grafana_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Grafana"

application_json="$(find_application_json_by_slug "$grafana_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Grafana"
ensure_group_binding "$application_uuid" "$admins_group_id"

auth_url="${AUTHENTIK_HOST%/}/application/o/authorize/"
token_url="${AUTHENTIK_HOST%/}/application/o/token/"
api_url="${AUTHENTIK_HOST%/}/application/o/userinfo/"

jq -n \
  --arg auth_disable_login_form "true" \
  --arg auth_oauth_auto_login "true" \
  --arg auth_basic_enabled "false" \
  --arg users_auto_assign_org_role "Admin" \
  --arg oauth_enabled "true" \
  --arg oauth_name "Authentik" \
  --arg oauth_allow_sign_up "true" \
  --arg oauth_client_id "$grafana_client_id" \
  --arg oauth_client_secret "$grafana_client_secret" \
  --arg oauth_scopes "openid profile email" \
  --arg oauth_auth_url "$auth_url" \
  --arg oauth_token_url "$token_url" \
  --arg oauth_api_url "$api_url" \
  '{
    "GF_AUTH_DISABLE_LOGIN_FORM": $auth_disable_login_form,
    "GF_AUTH_OAUTH_AUTO_LOGIN": $auth_oauth_auto_login,
    "GF_AUTH_BASIC_ENABLED": $auth_basic_enabled,
    "GF_USERS_AUTO_ASSIGN_ORG_ROLE": $users_auto_assign_org_role,
    "GF_AUTH_GENERIC_OAUTH_ENABLED": $oauth_enabled,
    "GF_AUTH_GENERIC_OAUTH_NAME": $oauth_name,
    "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP": $oauth_allow_sign_up,
    "GF_AUTH_GENERIC_OAUTH_CLIENT_ID": $oauth_client_id,
    "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": $oauth_client_secret,
    "GF_AUTH_GENERIC_OAUTH_SCOPES": $oauth_scopes,
    "GF_AUTH_GENERIC_OAUTH_AUTH_URL": $oauth_auth_url,
    "GF_AUTH_GENERIC_OAUTH_TOKEN_URL": $oauth_token_url,
    "GF_AUTH_GENERIC_OAUTH_API_URL": $oauth_api_url
  }' >"$grafana_secret_file"

chmod 600 "$grafana_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "grafana-oidc" \
  --json-file "$grafana_secret_file" \
  --required-keys "GF_AUTH_DISABLE_LOGIN_FORM,GF_AUTH_OAUTH_AUTO_LOGIN,GF_AUTH_BASIC_ENABLED,GF_USERS_AUTO_ASSIGN_ORG_ROLE,GF_AUTH_GENERIC_OAUTH_ENABLED,GF_AUTH_GENERIC_OAUTH_NAME,GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP,GF_AUTH_GENERIC_OAUTH_CLIENT_ID,GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET,GF_AUTH_GENERIC_OAUTH_SCOPES,GF_AUTH_GENERIC_OAUTH_AUTH_URL,GF_AUTH_GENERIC_OAUTH_TOKEN_URL,GF_AUTH_GENERIC_OAUTH_API_URL"
rm -f "$grafana_secret_file"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Grafana ExternalSecret"
kubectl apply -f "$grafana_externalsecret_manifest"
kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-oidc --timeout=10m

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refreshing platform-ingress so Grafana platform resources match the repo"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
  --application "platform-ingress" \
  --destination-namespace "argocd" \
  --no-wait

kubectl delete application grafana -n argocd --ignore-not-found=true 2>/dev/null || true
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "grafana" \
  --destination-namespace "monitoring"
