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

wait_for_authentik_api_ready() {
  local attempt=1
  local attempts=60
  local response_file status body
  local auth_headers=(-H "Accept: application/json")

  if [[ "${AUTHENTIK_USE_COOKIE:-false}" == "true" ]]; then
    auth_headers+=(-H "Cookie: ${AUTHENTIK_TOKEN}")
  else
    auth_headers+=(-H "Authorization: Bearer ${AUTHENTIK_TOKEN}")
  fi

  while [[ "$attempt" -le "$attempts" ]]; do
    response_file="$(mktemp)"
    status="$(
      curl -sS \
        --connect-timeout 10 \
        --max-time 30 \
        "${auth_headers[@]}" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${AUTHENTIK_API_BASE}/flows/instances/?page_size=1"
    )" || status="000"

    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"

    if [[ "$status" =~ ^2 ]]; then
      return 0
    fi

    if [[ -n "$body" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Authentik API readiness (${attempt}/${attempts}): HTTP ${status} ${body}" >&2
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Authentik API readiness (${attempt}/${attempts}): HTTP ${status}" >&2
    fi

    if [[ -n "${AUTHENTIK_FORWARD_PID:-}" ]] && ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Authentik port-forward died while waiting for API readiness; re-establishing" >&2
      authentik_setup_forward
    fi

    sleep 2
    attempt=$((attempt + 1))
  done

  fail "Authentik API did not become ready after ${attempts} attempts"
}

resolve_flow_id() {
  authentik_resolve_flow_id "$1" "$2"
}

resolve_scope_mapping_id() {
  authentik_resolve_scope_mapping_id "$1"
}

extract_authentik_identifier() {
  local payload="${1:-}"

  [[ -n "$payload" ]] || return 0
  jq -er '.pk // .uuid // .id // empty' <<<"$payload" 2>/dev/null || true
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

  existing_json="$(authentik_api_get "/propertymappings/provider/scope/?page_size=200" \
    | jq -c \
      --arg mapping_name "$mapping_name" \
      --arg scope_name "$scope_name" \
      '.results[]? | select((.name // "") == $mapping_name and (.scope_name // "") == $scope_name)' \
    | head -n1 || true)"

  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
    [[ -n "$existing_pk" ]] || fail "Could not determine scope mapping PK for ${mapping_name}"
    authentik_api_write PATCH "/propertymappings/provider/scope/${existing_pk}/" "$payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/propertymappings/provider/scope/" "$payload" | jq -r '.pk // .id // empty'
}

create_or_update_provider() {
  local provider_payload="$1"
  local search_response existing_pk response_json

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

  response_json="$(authentik_api_write POST "/providers/oauth2/" "$provider_payload")"
  existing_pk="$(extract_authentik_identifier "$response_json")"
  if [[ -n "$existing_pk" ]]; then
    printf '%s\n' "$existing_pk"
    return 0
  fi

  search_response="$(authentik_api_get "/providers/oauth2/?page_size=100")"
  existing_pk="$(
    jq -r \
      --arg provider_name "Twinbox Portal" \
      '.results[]?
        | select((.name // "") == $provider_name)
        | .pk // .id // empty' <<<"$search_response" | head -n1
  )"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose a provider ID for Twinbox Portal"

  authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
  printf '%s\n' "$existing_pk"
}

create_or_update_application() {
  local app_payload="$1"
  local existing_json existing_pk response_json created_pk

  existing_json="$(authentik_api_get "/core/applications/${portal_application_slug}/" 2>/dev/null || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${portal_application_slug}/" "$app_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  response_json="$(authentik_api_write POST "/core/applications/" "$app_payload")"
  created_pk="$(extract_authentik_identifier "$response_json")"
  if [[ -n "$created_pk" ]]; then
    printf '%s\n' "$created_pk"
    return 0
  fi

  existing_json="$(authentik_api_get "/core/applications/${portal_application_slug}/" 2>/dev/null || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose an application ID for Twinbox Portal"

  authentik_api_write PATCH "/core/applications/${portal_application_slug}/" "$app_payload" >/dev/null
  printf '%s\n' "$existing_pk"
}

wait_for_authentik_api_ready

authorization_flow_id="$(resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(resolve_scope_mapping_id "openid")"
email_mapping_id="$(resolve_scope_mapping_id "email")"
profile_mapping_id="$(resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"
groups_mapping_id="$(upsert_scope_mapping \
  "Twinbox Portal groups" \
  "groups" \
  "Expose Twinbox Portal group membership" \
  'groups = [group.name for group in request.user.ak_groups.all()]
if request.user.is_superuser and "admins" not in groups:
    groups.append("admins")
return {
    "groups": groups,
}' \
)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$groups_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for groups"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    --arg groups "$groups_mapping_id" \
    '[$openid, $email, $profile, $groups]'
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
      grant_types: ["authorization_code"],
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

secret_file="$(mktemp "${TMPDIR:-/tmp}/twinbox-portal-XXXXXX")"
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

rendered_application="$(mktemp "${TMPDIR:-/tmp}/twinbox-portal-application-XXXXXX")"
trap 'rm -f "$secret_file" "$rendered_application"' EXIT
node "$WORKSPACE_ROOT/manager-worker/src/refresh-portal-config.mjs" \
  --workspace-root "$WORKSPACE_ROOT" \
  --manager-data-dir "$MANAGER_DATA_DIR" \
  --cluster-id "$cluster_id" \
  --trigger-step-id install-twinbox-portal

sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/twinbox-portal.yaml" >"$rendered_application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_application" \
  --application "twinbox-portal" \
  --destination-namespace "twinbox-portal"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "twinbox-portal" \
  --service-domain "portal.${public_zone_name}" \
  --service-path /

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Twinbox Portal configuration complete"
