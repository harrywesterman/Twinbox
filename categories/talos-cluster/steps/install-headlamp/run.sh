#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
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
headlamp_manifest_path="$WORKSPACE_ROOT/gitops/apps/headlamp.yaml"
headlamp_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/headlamp-application-XXXXXX")"
trap 'rm -f "$headlamp_rendered_manifest"' EXIT

headlamp_host="https://headlamp.${public_zone_name}"
headlamp_redirect_uri="${headlamp_host}/oidc-callback"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"
headlamp_application_slug="headlamp"
headlamp_issuer_url="${AUTHENTIK_HOST%/}/application/o/${headlamp_application_slug}/"
headlamp_client_id="$(openssl rand -hex 16)"
headlamp_client_secret="$(openssl rand -hex 24)"
authentik_oidc_state_key="authentik-headlamp"

existing_headlamp_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_headlamp_secret_json="$(openbao_read_global_secret_json headlamp-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_headlamp_secret_json" ]]; then
  existing_client_id="$(jq -r '.HEADLAMP_CONFIG_OIDC_CLIENT_ID // .OIDC_CLIENT_ID // empty' <<<"$existing_headlamp_secret_json")"
  existing_client_secret="$(jq -r '.HEADLAMP_CONFIG_OIDC_CLIENT_SECRET // .OIDC_CLIENT_SECRET // empty' <<<"$existing_headlamp_secret_json")"
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    headlamp_client_id="$existing_client_id"
    headlamp_client_secret="$existing_client_secret"
  fi
fi

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

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Headlamp")"
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

  existing_json="$(find_application_json_by_slug "$headlamp_application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${headlamp_application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
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

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
admins_group_id="$(authentik_find_group_id "admins")"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "Headlamp" \
    --arg client_id "$headlamp_client_id" \
    --arg client_secret "$headlamp_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$headlamp_redirect_uri" \
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Headlamp"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Headlamp"

application_payload="$(
  jq -n \
    --arg name "Headlamp" \
    --arg slug "$headlamp_application_slug" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Headlamp"

application_json="$(find_application_json_by_slug "$headlamp_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Headlamp"
ensure_group_binding "$application_uuid" "$admins_group_id"

secrets_dir="/opt/twinbox/bootstrap/secrets/global"

headlamp_secret_file="$secrets_dir/headlamp-oidc-${cluster_id}.json"
cat >"$headlamp_secret_file" <<EOF
{
  "OIDC_CLIENT_ID": "$headlamp_client_id",
  "OIDC_CLIENT_SECRET": "$headlamp_client_secret",
  "OIDC_ISSUER_URL": "$headlamp_issuer_url",
  "OIDC_SCOPES": "openid profile email",
  "HEADLAMP_CONFIG_OIDC_CLIENT_ID": "$headlamp_client_id",
  "HEADLAMP_CONFIG_OIDC_CLIENT_SECRET": "$headlamp_client_secret",
  "HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL": "$headlamp_issuer_url",
  "HEADLAMP_CONFIG_OIDC_SCOPES": "openid profile email",
  "CLUSTER_ID": "$cluster_id",
  "HEADLAMP_HOST": "$headlamp_host"
}
EOF

chmod 600 "$headlamp_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "headlamp-oidc" \
  --json-file "$headlamp_secret_file" \
  --required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL,OIDC_SCOPES,HEADLAMP_CONFIG_OIDC_CLIENT_ID,HEADLAMP_CONFIG_OIDC_CLIENT_SECRET,HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL,HEADLAMP_CONFIG_OIDC_SCOPES"
rm -f "$headlamp_secret_file"

if command -v kubectl &>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Headlamp ExternalSecret"
  kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/headlamp/externalsecret.yaml"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Headlamp Argo CD application"
  sed "s/__ZONE_NAME__/${public_zone_name}/g" "$headlamp_manifest_path" >"$headlamp_rendered_manifest"
  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$headlamp_rendered_manifest" \
    --application "headlamp"

  if kubectl -n kube-system get deployment/headlamp >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting Headlamp to pick up Authentik OIDC settings"
    kubectl -n kube-system rollout restart deployment/headlamp
    kubectl -n kube-system rollout status deployment/headlamp --timeout=10m
  fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Headlamp Authentik configuration complete"
