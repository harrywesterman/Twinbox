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
cluster_instance_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // .instance_id // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
dashy_manifest_path="$WORKSPACE_ROOT/gitops/apps/dashy.yaml"

dashy_host="https://admin.${public_zone_name}"
dashy_redirect_uri="${dashy_host}"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"
dashy_application_slug="dashy"
dashy_issuer_url="${AUTHENTIK_HOST%/}/application/o/${dashy_application_slug}/"
dashy_client_id="$(openssl rand -hex 16)"

existing_dashy_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_dashy_secret_json="$(openbao_read_global_secret_json dashy-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_dashy_secret_json" ]]; then
  existing_client_id="$(jq -r '.DASHY_OIDC_CLIENT_ID // empty' <<<"$existing_dashy_secret_json")"
  if [[ -n "$existing_client_id" ]]; then
    dashy_client_id="$existing_client_id"
  fi
fi

resolve_flow_id() {
  local slug="$1"
  local designation="$2"

  # Reuse the shared Authentik resolver because it already matches the API
  # endpoint used by the deployed management environment.
  authentik_resolve_flow_id "$slug" "$designation"
}

resolve_scope_mapping_id() {
  local scope_name="$1"
  local response managed_pk fallback_pk

  response="$(authentik_api_get "/propertymappings/provider/scope/?scope_name=${scope_name}&page_size=20")"
  managed_pk="$(
    jq -r \
      --arg scope_name "$scope_name" \
      'limit(1; .results[]?
        | select((.scope_name // "") == $scope_name and ((.managed // "") | length > 0))
        | .pk // empty)' <<<"$response"
  )"
  if [[ -n "$managed_pk" ]]; then
    printf '%s\n' "$managed_pk"
    return 0
  fi

  fallback_pk="$(
    jq -r \
      --arg scope_name "$scope_name" \
      'limit(1; .results[]?
        | select((.scope_name // "") == $scope_name)
        | .pk // empty)' <<<"$response"
  )"
  printf '%s\n' "$fallback_pk"
}

create_or_update_provider() {
  local provider_payload="$1"
  local search_response provider_pk existing_pk

  search_response="$(authentik_api_get "/providers/oauth2/?search=Dashy")"
  existing_pk="$(
    jq -r '
      limit(1; .results[]?
      | select((.name // "") == "Dashy")
      | .pk // .id // empty)
    ' <<<"$search_response"
  )"

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  provider_pk="$(
    authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
  )"

  [[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Dashy"
  printf '%s\n' "$provider_pk"
}

create_or_update_application() {
  local app_payload="$1"
  local existing_json existing_pk

  existing_json="$(authentik_api_get "/core/applications/${dashy_application_slug}/" 2>/dev/null || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${dashy_application_slug}/" "$app_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$app_payload" | jq -r '.pk // .id // empty'
}

find_application_json_by_slug() {
  local application_slug="$1"
  local direct_json list_response

  # Prefer the slug-specific endpoint because the list endpoint can lag just
  # enough after a create/patch for the next lookup to miss the fresh object.
  direct_json="$(authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true)"
  if [[ -n "$direct_json" ]]; then
    printf '%s\n' "$direct_json"
    return 0
  fi

  list_response="$(authentik_api_get "/core/applications/?page_size=100")"
  jq -c \
    --arg application_slug "$application_slug" \
    'limit(1; .results[]?
      | select((.slug // "") == $application_slug))' <<<"$list_response"
}

find_policy_binding_pk() {
  local target_uuid="$1"
  local group_id="$2"
  local response

  response="$(authentik_api_get "/policies/bindings/?page_size=200")"
  jq -r \
    --arg target_uuid "$target_uuid" \
    --arg group_id "$group_id" \
    'limit(1; .results[]?
      | select((.target // "") == $target_uuid and (.group // "") == $group_id)
      | .pk // .id // empty)' <<<"$response"
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

authorization_flow_id="$(resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(resolve_scope_mapping_id "openid")"
email_mapping_id="$(resolve_scope_mapping_id "email")"
profile_mapping_id="$(resolve_scope_mapping_id "profile")"
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

dashy_redirect_regex="$(printf '%s' "${dashy_redirect_uri%/}" | sed 's/[.[\*^$()+?{|]/\\&/g; s/\//\\\//g')"

provider_payload="$(
  jq -n \
    --arg name "Dashy" \
    --arg client_id "$dashy_client_id" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_regex "^${dashy_redirect_regex}(?:.*)?$" \
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Dashy"
provider_pk="$(create_or_update_provider "$provider_payload")"
application_payload="$(
  jq -n \
    --arg name "Dashy" \
    --arg slug "$dashy_application_slug" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Dashy"

application_json="$(find_application_json_by_slug "$dashy_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Dashy"
ensure_group_binding "$application_uuid" "$admins_group_id"

dashy_secret_file="$secrets_dir/dashy-oidc-${cluster_id}.json"
cat >"$dashy_secret_file" <<EOF
{
  "DASHY_OIDC_CLIENT_ID": "$dashy_client_id",
  "DASHY_OIDC_ENDPOINT": "$dashy_issuer_url",
  "DASHY_OIDC_SCOPE": "openid profile email",
  "CLUSTER_ID": "$cluster_id",
  "DASHY_HOST": "$dashy_host"
}
EOF

chmod 600 "$dashy_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "dashy-oidc" \
  --json-file "$dashy_secret_file" \
  --required-keys "DASHY_OIDC_CLIENT_ID,DASHY_OIDC_ENDPOINT,DASHY_OIDC_SCOPE"
rm -f "$dashy_secret_file"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Rendering Dashy config"
refresh_dashy_config_args=(
  "$WORKSPACE_ROOT/manager-worker/src/refresh-dashy-config.mjs"
  --workspace-root "$WORKSPACE_ROOT"
  --manager-data-dir "$MANAGER_DATA_DIR"
  --cluster-id "$cluster_id"
  --trigger-step-id install-dashy-dashboard
)
if [[ -n "$cluster_instance_id" ]]; then
  refresh_dashy_config_args+=(--cluster-instance-id "$cluster_instance_id")
fi
if ! node "${refresh_dashy_config_args[@]}"; then
  fail "Dashy config rendering failed before rollout wait"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dashy config rendered"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Dashy Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$dashy_manifest_path" \
  --application "dashy" \
  --destination-namespace "dashy" \
  --no-wait

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Dashy OIDC secret"
for attempt in $(seq 1 120); do
  if kubectl -n dashy get externalsecret/dashy-oidc >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 120 ]]; then
    fail "Dashy ExternalSecret did not appear in time"
  fi
  sleep 5
done
kubectl -n dashy wait --for=condition=Ready externalsecret/dashy-oidc --timeout=10m

for attempt in $(seq 1 120); do
  if kubectl -n dashy get deployment/dashy >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 120 ]]; then
    fail "Dashy deployment did not appear in time"
  fi
  sleep 5
done
kubectl -n dashy rollout status deployment/dashy --timeout=10m

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "dashy" \
  --service-domain "admin.${public_zone_name}" \
  --service-path /

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dashy Authentik configuration complete"
