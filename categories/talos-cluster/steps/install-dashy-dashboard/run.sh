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

dashy_host="https://start.${public_zone_name}"
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

resolve_flow_id() {
  local slug="$1"
  local designation="$2"
  local response

  response="$(api_get "/flows/instances/?slug=${slug}&designation=${designation}")"
  jq -r \
    --arg slug "$slug" \
    --arg designation "$designation" \
    '.results[]?
      | select((.slug // "") == $slug and (.designation // "") == $designation)
      | .pk // empty' <<<"$response" | head -n1
}

resolve_scope_mapping_id() {
  local scope_name="$1"
  local response managed_pk fallback_pk

  response="$(api_get "/propertymappings/provider/scope/?scope_name=${scope_name}&page_size=20")"
  managed_pk="$(
    jq -r \
      --arg scope_name "$scope_name" \
      '.results[]?
        | select((.scope_name // "") == $scope_name and ((.managed // "") | length > 0))
        | .pk // empty' <<<"$response" | head -n1
  )"
  if [[ -n "$managed_pk" ]]; then
    printf '%s\n' "$managed_pk"
    return 0
  fi

  fallback_pk="$(
    jq -r \
      --arg scope_name "$scope_name" \
      '.results[]?
        | select((.scope_name // "") == $scope_name)
        | .pk // empty' <<<"$response" | head -n1
  )"
  printf '%s\n' "$fallback_pk"
}

create_or_update_provider() {
  local provider_payload="$1"
  local search_response provider_pk existing_pk

  search_response="$(api_get "/providers/oauth2/?search=Dashy")"
  existing_pk="$(
    jq -r '
      .results[]?
      | select((.name // "") == "Dashy")
      | .pk // .id // empty
    ' <<<"$search_response" | head -n1
  )"

  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  provider_pk="$(
    api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
  )"

  [[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Dashy"
  printf '%s\n' "$provider_pk"
}

create_or_update_application() {
  local app_payload="$1"
  local existing_json existing_pk

  existing_json="$(api_get "/core/applications/${dashy_application_slug}/" 2>/dev/null || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"

  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/core/applications/${dashy_application_slug}/" "$app_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  api_write POST "/core/applications/" "$app_payload" | jq -r '.pk // .id // empty'
}

authorization_flow_id="$(resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(resolve_scope_mapping_id "openid")"
email_mapping_id="$(resolve_scope_mapping_id "email")"
profile_mapping_id="$(resolve_scope_mapping_id "profile")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"

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
    --arg redirect_regex "^${dashy_redirect_regex}(?:.*)?$" \
    --argjson property_mappings "$property_mapping_ids_json" \
    '{
      name: $name,
      client_id: $client_id,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
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

kubectl create namespace dashy --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Dashy ExternalSecret"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/dashy/externalsecret.yaml"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Dashy OIDC secret"
kubectl -n dashy wait --for=condition=Ready externalsecret/dashy-oidc --timeout=10m

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refreshing platform-ingress so Dashy resources are applied"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
  --application "platform-ingress" \
  --destination-namespace "argocd" \
  --no-wait

for attempt in $(seq 1 120); do
  if kubectl -n dashy get deployment/dashy >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 120 ]]; then
    fail "Dashy deployment did not appear in time"
  fi
  sleep 5
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Rendering and applying Dashy start page config"
node "$WORKSPACE_ROOT/manager-worker/src/refresh-dashy-config.mjs" \
  --workspace-root "$WORKSPACE_ROOT" \
  --manager-data-dir "$MANAGER_DATA_DIR" \
  --cluster-id "$cluster_id"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dashy Authentik configuration complete"
