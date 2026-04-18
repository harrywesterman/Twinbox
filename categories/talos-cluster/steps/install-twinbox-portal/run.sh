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
portal_host="https://portal.${public_zone_name}"
portal_application_slug="twinbox-portal"
portal_issuer_url="${AUTHENTIK_HOST%/}/application/o/${portal_application_slug}/"
authentik_api_base="http://authentik-server.authentik.svc.cluster.local/api/v3"
portal_client_id="$(openssl rand -hex 16)"
portal_session_secret="$(openssl rand -hex 32)"

existing_portal_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_portal_secret_json="$(openbao_read_global_secret_json twinbox-portal 2>/dev/null || true)"
fi

if [[ -n "$existing_portal_secret_json" ]]; then
  existing_client_id="$(jq -r '.PORTAL_OIDC_CLIENT_ID // empty' <<<"$existing_portal_secret_json")"
  existing_session_secret="$(jq -r '.PORTAL_SESSION_SECRET // empty' <<<"$existing_portal_secret_json")"
  [[ -n "$existing_client_id" ]] && portal_client_id="$existing_client_id"
  [[ -n "$existing_session_secret" ]] && portal_session_secret="$existing_session_secret"
fi

resolve_flow_id() {
  authentik_resolve_flow_id "$1" "$2"
}

resolve_scope_mapping_id() {
  authentik_resolve_scope_mapping_id "$1"
}

create_or_update_provider() {
  local provider_payload="$1"
  local search_response existing_pk

  search_response="$(authentik_api_get "/providers/oauth2/?page_size=100")"
  existing_pk="$(
    jq -r '
      .results[]?
      | select((.name // "") == "Twinbox Portal")
      | .pk // .id // empty
    ' <<<"$search_response" | head -n1
  )"

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local app_payload="$1"
  local existing_json existing_pk

  existing_json="$(authentik_api_get "/core/applications/${portal_application_slug}/" 2>/dev/null || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${portal_application_slug}/" "$app_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$app_payload" | jq -r '.pk // .id // empty'
}

authorization_flow_id="$(resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(resolve_scope_mapping_id "openid")"
email_mapping_id="$(resolve_scope_mapping_id "email")"
profile_mapping_id="$(resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

portal_redirect_regex="$(printf '%s' "$portal_host/auth/callback" | sed 's/[.[\*^$()+?{|]/\\&/g; s/\//\\\//g')"

provider_payload="$(
  jq -n \
    --arg name "Twinbox Portal" \
    --arg client_id "$portal_client_id" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_regex "^${portal_redirect_regex}$" \
    --argjson property_mappings "$property_mapping_ids_json" \
    '{
      name: $name,
      client_id: $client_id,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      redirect_uris: [
        {
          matching_mode: "regex",
          url: $redirect_regex
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "public",
      issuer_mode: "per_provider"
    }'
)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Twinbox Portal"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Twinbox Portal"

application_payload="$(
  jq -n \
    --arg name "Twinbox Portal" \
    --arg slug "$portal_application_slug" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber)
    }'
)"

application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Twinbox Portal"

secret_file="$(mktemp "${TMPDIR:-/tmp}/twinbox-portal.XXXXXX.json")"
trap 'rm -f "$secret_file"' EXIT
cat >"$secret_file" <<EOF
{
  "PORTAL_BASE_URL": "$portal_host",
  "PORTAL_OIDC_CLIENT_ID": "$portal_client_id",
  "PORTAL_OIDC_ISSUER": "$portal_issuer_url",
  "PORTAL_SESSION_SECRET": "$portal_session_secret",
  "AUTHENTIK_API_BASE": "$authentik_api_base"
}
EOF

chmod 600 "$secret_file"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "twinbox-portal" \
  --json-file "$secret_file" \
  --required-keys "PORTAL_BASE_URL,PORTAL_OIDC_CLIENT_ID,PORTAL_OIDC_ISSUER,PORTAL_SESSION_SECRET,AUTHENTIK_API_BASE"

kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/twinbox-portal/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/twinbox-portal/configmap.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/twinbox-portal/externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/twinbox-portal/pvc.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/twinbox-portal/service.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/twinbox-portal/deployment.yaml"

rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/twinbox-portal-ingressroute.XXXXXX.yaml")"
trap 'rm -f "$secret_file" "$rendered_ingressroute"' EXIT
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/platform-apps/twinbox-portal/ingressroute.yaml" >"$rendered_ingressroute"
kubectl apply -f "$rendered_ingressroute"

node "$WORKSPACE_ROOT/manager-worker/src/refresh-portal-config.mjs" \
  --workspace-root "$WORKSPACE_ROOT" \
  --manager-data-dir "$MANAGER_DATA_DIR" \
  --cluster-id "$cluster_id"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Twinbox Portal configuration complete"
