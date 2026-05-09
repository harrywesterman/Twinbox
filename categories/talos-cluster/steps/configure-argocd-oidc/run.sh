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

wait_for_argocd_secret_key() {
  local secret_key="$1"
  local attempts=120
  local attempt=1
  local value=""

  while true; do
    value="$(
      kubectl -n argocd get secret argocd-secret -o json 2>/dev/null \
        | jq -r --arg secret_key "$secret_key" '.data[$secret_key] // empty'
    )"
    if [[ -n "$value" ]]; then
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for argocd-secret key '${secret_key}'"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_argocd_oidc_config() {
  local expected_issuer="$1"
  local attempts="${2:-12}"
  local attempt=1
  local oidc_config=""

  while true; do
    oidc_config="$(
      kubectl -n argocd get configmap argocd-cm -o json 2>/dev/null \
        | jq -r '.data["oidc.config"] // empty'
    )"
    if [[ "$oidc_config" == *"issuer: ${expected_issuer}"* ]]; then
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for argocd-cm oidc.config to contain issuer '${expected_issuer}'"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
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

argocd_host="https://argocd.${public_zone_name}"
argocd_redirect_uri="${argocd_host}/auth/callback"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ensuring Argo CD cluster secret is annotated for ${public_zone_name}"
bash "$WORKSPACE_ROOT/scripts/manager/upsert-argocd-cluster-secret.sh" \
  --public-zone-name "$public_zone_name"

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reading Authentik OIDC lookup data for Argo CD"
argocd_client_id="$(openssl rand -hex 16)"
argocd_client_secret="$(openssl rand -hex 24)"
argocd_application_slug="argocd"
argocd_issuer_url="${AUTHENTIK_HOST%/}/application/o/${argocd_application_slug}/"

existing_argocd_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_argocd_secret_json="$(openbao_read_global_secret_json argocd-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_argocd_secret_json" ]]; then
  existing_client_id="$(jq -r '.ARGOCD_OIDC_CLIENT_ID // empty' <<<"$existing_argocd_secret_json")"
  existing_client_secret="$(jq -r '.ARGOCD_OIDC_CLIENT_SECRET // empty' <<<"$existing_argocd_secret_json")"
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    argocd_client_id="$existing_client_id"
    argocd_client_secret="$existing_client_secret"
  fi
fi

resolve_flow_id() {
  local slug="$1"
  local designation="$2"

  # Reuse the shared Authentik resolver because it already targets the API
  # shape used by the management VM's Authentik deployment.
  authentik_resolve_flow_id "$slug" "$designation"
}

authorization_flow_id="$(resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
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

create_or_update_provider() {
  local provider_payload="$1"
  local search_response provider_pk existing_pk

  search_response="$(authentik_api_get "/providers/oauth2/?search=Argo%20CD")"
  existing_pk="$(
    jq -r '
      .results[]?
      | select((.name // "") == "Argo CD")
      | .pk // .id // empty
    ' <<<"$search_response" | head -n1
  )"

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  provider_pk="$(
    authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
  )"

  [[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Argo CD"
  printf '%s\n' "$provider_pk"
}

create_or_update_application() {
  local app_payload="$1"
  local existing_json existing_pk

  existing_json="$(authentik_api_get "/core/applications/${argocd_application_slug}/" 2>/dev/null || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${argocd_application_slug}/" "$app_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$app_payload" | jq -r '.pk // .id // empty'
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

provider_payload="$(
  jq -n \
    --arg name "Argo CD" \
    --arg client_id "$argocd_client_id" \
    --arg client_secret "$argocd_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$argocd_redirect_uri" \
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Argo CD"
provider_pk="$(create_or_update_provider "$provider_payload")"
application_payload="$(
  jq -n \
    --arg name "Argo CD" \
    --arg slug "$argocd_application_slug" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Argo CD"

application_json="$(authentik_api_get "/core/applications/${argocd_application_slug}/")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Argo CD"
ensure_group_binding "$application_uuid" "$admins_group_id"

argocd_secret_file="$secrets_dir/argocd-oidc-${cluster_id}.json"
cat >"$argocd_secret_file" <<EOF
{
  "ARGOCD_OIDC_CLIENT_ID": "$argocd_client_id",
  "ARGOCD_OIDC_CLIENT_SECRET": "$argocd_client_secret",
  "ARGOCD_OIDC_ISSUER_URL": "$argocd_issuer_url",
  "ARGOCD_REDIRECT_URI": "$argocd_redirect_uri",
  "ARGOCD_HOST": "$argocd_host",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$argocd_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "argocd-oidc" \
  --json-file "$argocd_secret_file" \
  --required-keys "ARGOCD_OIDC_CLIENT_ID,ARGOCD_OIDC_CLIENT_SECRET,ARGOCD_OIDC_ISSUER_URL,ARGOCD_REDIRECT_URI,ARGOCD_HOST"
rm -f "$argocd_secret_file"

kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/argocd/externalsecret.yaml"
kubectl -n argocd wait --for=condition=Ready externalsecret/argocd-oidc --timeout=10m
wait_for_argocd_secret_key "oidc.authentik.clientID"
wait_for_argocd_secret_key "oidc.authentik.clientSecret"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refreshing platform-ingress so Argo CD picks up OIDC config"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
  --application "platform-ingress" \
  --destination-namespace "argocd"

wait_for_argocd_oidc_config "$argocd_issuer_url" 12

if kubectl -n argocd get deployment/argocd-server >/dev/null 2>&1; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting Argo CD server to load OIDC settings"
  kubectl -n argocd rollout restart deployment/argocd-server
  kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
fi

argocd_cli_file="$secrets_dir/argocd-cli.json"
cat >"$argocd_cli_file" <<EOF
{
  "ARGOCD_HOST": "$argocd_host",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$argocd_cli_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "argocd-cli" \
  --json-file "$argocd_cli_file" \
  --required-keys "ARGOCD_HOST,CLUSTER_ID"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD Authentik configuration complete"
