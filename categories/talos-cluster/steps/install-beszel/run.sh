#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
source "$WORKSPACE_ROOT/scripts/manager/management-ip.sh"
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

tmp_files=()
cleanup() {
  local file
  for file in "${tmp_files[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

beszel_app_url="https://beszel.${public_zone_name}"
beszel_local_url="${BESZEL_LOCAL_URL:-http://beszel:8090}"
beszel_user_email="beszel-admin@${public_zone_name}"
beszel_version="${BESZEL_VERSION:-${PINNED_BESZEL_VERSION:-0.18.7}}"
env_file="/opt/twinbox/.env"
management_consoles_dir="$WORKSPACE_ROOT/gitops/platform/management-consoles"

log "Installing Beszel Monitoring for zone: ${public_zone_name}"

read_env_var() {
  local key="$1"
  if [[ -f "$env_file" ]]; then
    grep -E "^${key}=" "$env_file" | tail -n1 | cut -d= -f2- || true
  fi
}

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp_file

  mkdir -p "$(dirname "$env_file")"
  touch "$env_file"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/twinbox-env-XXXXXX")"
  tmp_files+=("$tmp_file")

  awk -v key="$key" -v value="$value" '
    BEGIN { written = 0 }
    $0 ~ "^" key "=" {
      if (!written) {
        print key "=" value
        written = 1
      }
      next
    }
    { print }
    END {
      if (!written) {
        print key "=" value
      }
    }
  ' "$env_file" >"$tmp_file"
  cat "$tmp_file" >"$env_file"
}

beszel_user_password="$(read_env_var BESZEL_USER_PASSWORD)"
if [[ -z "$beszel_user_password" ]]; then
  beszel_user_password="$(openssl rand -hex 24)"
fi

set_env_var "BESZEL_APP_URL" "$beszel_app_url"
set_env_var "BESZEL_USER_EMAIL" "$beszel_user_email"
set_env_var "BESZEL_USER_PASSWORD" "$beszel_user_password"
set_env_var "BESZEL_VERSION" "$beszel_version"

apply_beszel_traefik_route() {
  local management_ip

  management_ip="${MANAGEMENT_VM_IP:-}"
  if [[ -z "$management_ip" ]]; then
    management_ip="$(resolve_management_vm_ip)" || fail "Unable to resolve Management VM IP for Beszel route"
  fi

  kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$management_consoles_dir/beszel-service.yaml" >/dev/null
  sed "s/__MGMT_HOST_IP__/${management_ip}/g" \
    "$management_consoles_dir/beszel-endpoints.yaml" | kubectl apply -f - >/dev/null
  sed "s/__ZONE_NAME__/${public_zone_name}/g" \
    "$management_consoles_dir/beszel-ingressroute.yaml" | kubectl apply -f - >/dev/null

  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
    --application "platform-ingress" \
    --destination-namespace "argocd"
}

log "Starting Beszel hub"
(cd "$WORKSPACE_ROOT" && docker compose up -d beszel)

log "Waiting for Beszel hub to become healthy"
for attempt in $(seq 1 60); do
  if curl -sf "${beszel_local_url}/api/health" >/dev/null 2>&1; then
    log "Beszel hub is healthy"
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    fail "Beszel hub did not become healthy within 120s"
  fi
  sleep 2
done

ensure_beszel_superuser() {
  docker exec twinbox-beszel /beszel superuser upsert "$beszel_user_email" "$beszel_user_password" >/dev/null
}

log "Ensuring Beszel PocketBase superuser"
ensure_beszel_superuser

beszel_authenticate_superuser() {
  local response token

  response="$(curl -sf -X POST "${beszel_local_url}/api/collections/_superusers/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --arg identity "$beszel_user_email" --arg password "$beszel_user_password" '{identity: $identity, password: $password}')" 2>/dev/null || true)"
  token="$(jq -r '.token // empty' <<<"$response")"
  if [[ -n "$token" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  response="$(curl -sf -X POST "${beszel_local_url}/api/superusers/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --arg identity "$beszel_user_email" --arg password "$beszel_user_password" '{identity: $identity, password: $password}')" 2>/dev/null || true)"
  token="$(jq -r '.token // empty' <<<"$response")"
  if [[ -n "$token" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  response="$(curl -sf -X POST "${beszel_local_url}/api/admins/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --arg identity "$beszel_user_email" --arg password "$beszel_user_password" '{identity: $identity, password: $password}')" 2>/dev/null || true)"
  jq -r '.token // empty' <<<"$response"
}

beszel_superuser_token="$(beszel_authenticate_superuser)"
[[ -n "$beszel_superuser_token" ]] || fail "Could not authenticate with Beszel PocketBase superuser API"
beszel_pb_auth_header="Authorization: Bearer ${beszel_superuser_token}"

beszel_api_get() {
  curl -sf "${beszel_local_url}$1" \
    -H "$beszel_pb_auth_header" \
    -H "Accept: application/json"
}

beszel_api_write() {
  local method="$1"
  local path="$2"
  local payload="$3"

  curl -sf -X "$method" "${beszel_local_url}${path}" \
    -H "$beszel_pb_auth_header" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

beszel_public_key_from_file() {
  local private_key_path="/opt/twinbox/beszel/data/id_ed25519"
  if [[ -f "$private_key_path" ]]; then
    ssh-keygen -y -f "$private_key_path" 2>/dev/null || true
  fi
}

beszel_public_key="$(beszel_public_key_from_file)"
if [[ -z "$beszel_public_key" ]]; then
  beszel_public_key="$(beszel_api_get "/api/beszel/info" | jq -r '.key // empty')"
fi
[[ -n "$beszel_public_key" ]] || fail "Could not determine Beszel hub public key"

ensure_beszel_user() {
  local encoded_filter response user_id payload

  encoded_filter="$(urlencode "email = \"${beszel_user_email}\"")"
  response="$(beszel_api_get "/api/collections/users/records?filter=${encoded_filter}&perPage=1")"
  user_id="$(jq -r '.items[0].id // empty' <<<"$response")"
  if [[ -n "$user_id" ]]; then
    printf '%s\n' "$user_id"
    return 0
  fi

  payload="$(
    jq -cn \
      --arg email "$beszel_user_email" \
      --arg password "$beszel_user_password" \
      '{
        email: $email,
        password: $password,
        passwordConfirm: $password,
        emailVisibility: true,
        verified: true,
        role: "admin"
      }'
  )"
  beszel_api_write POST "/api/collections/users/records" "$payload" | jq -r '.id // empty'
}

beszel_user_id="$(ensure_beszel_user)"
[[ -n "$beszel_user_id" ]] || fail "Could not create or find Beszel automation user"

existing_agent_secret_json="$(openbao_read_global_secret_json beszel-agent 2>/dev/null || true)"
beszel_agent_token="$(jq -r '.token // empty' <<<"$existing_agent_secret_json" 2>/dev/null || true)"
if [[ -z "$beszel_agent_token" ]]; then
  beszel_agent_token="$(openssl rand -hex 32)"
fi

upsert_beszel_universal_token() {
  local encoded_filter response record_id payload

  encoded_filter="$(urlencode "user = \"${beszel_user_id}\"")"
  response="$(beszel_api_get "/api/collections/universal_tokens/records?filter=${encoded_filter}&perPage=1")"
  record_id="$(jq -r '.items[0].id // empty' <<<"$response")"
  payload="$(jq -cn --arg user "$beszel_user_id" --arg token "$beszel_agent_token" '{user: $user, token: $token}')"

  if [[ -n "$record_id" ]]; then
    beszel_api_write PATCH "/api/collections/universal_tokens/records/${record_id}" "$payload" >/dev/null
  else
    beszel_api_write POST "/api/collections/universal_tokens/records" "$payload" >/dev/null
  fi
}

log "Configuring Beszel universal agent token"
upsert_beszel_universal_token

beszel_agent_secret_file="$(mktemp "${TMPDIR:-/tmp}/beszel-agent-XXXXXX")"
tmp_files+=("$beszel_agent_secret_file")
cat >"$beszel_agent_secret_file" <<EOF
{
  "key": "$beszel_public_key",
  "token": "$beszel_agent_token",
  "hub_url": "$beszel_app_url",
  "CLUSTER_ID": "$cluster_id"
}
EOF
chmod 600 "$beszel_agent_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "beszel-agent" \
  --json-file "$beszel_agent_secret_file" \
  --required-keys "key,token,hub_url"

set_env_var "BESZEL_AGENT_KEY" "$beszel_public_key"
set_env_var "BESZEL_AGENT_TOKEN" "$beszel_agent_token"

log "Starting Beszel Management VM agent"
(cd "$WORKSPACE_ROOT" && docker compose up -d beszel-agent)

# ---------------------------------------------------------------------------
# Authentik OIDC provider setup
# ---------------------------------------------------------------------------
authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
beszel_application_slug="beszel"
beszel_redirect_uri="${beszel_app_url}/api/oauth2-redirect"
beszel_issuer_url="${AUTHENTIK_HOST%/}/application/o/${beszel_application_slug}/"

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response
  response="$(authentik_api_get "/providers/oauth2/?name=$(urlencode "$provider_name")&page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    'limit(1; .results[]? | select((.name // "") == $provider_name) | .pk // .id // empty)' \
    <<<"$response"
}

find_application_json_by_slug() {
  local application_slug="$1"
  local direct_json response

  direct_json="$(authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true)"
  if [[ -n "$direct_json" ]]; then
    printf '%s\n' "$direct_json"
    return 0
  fi

  response="$(authentik_api_get "/core/applications/?slug=$(urlencode "$application_slug")&page_size=100")"
  jq -c \
    --arg application_slug "$application_slug" \
    'limit(1; .results[]? | select((.slug // "") == $application_slug))' \
    <<<"$response"
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

  binding_payload="$(jq -n --arg target_uuid "$target_uuid" --arg group_id "$group_id" '{target: $target_uuid, group: $group_id, order: 1, enabled: true}')"
  existing_pk="$(find_policy_binding_pk "$target_uuid" "$group_id")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
  else
    authentik_api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
  fi
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk
  existing_pk="$(find_oauth2_provider_pk_by_name "Beszel Monitoring")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi
  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_payload="$1"
  local existing_app_json existing_app_pk

  existing_app_json="$(find_application_json_by_slug "$beszel_application_slug")"
  existing_app_pk="$(jq -r '.pk // .id // empty' <<<"$existing_app_json")"
  if [[ -n "$existing_app_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${beszel_application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_app_pk"
    return 0
  fi
  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

beszel_client_id="$(jq -r '.OIDC_CLIENT_ID // empty' <<<"$(openbao_read_global_secret_json beszel-oidc 2>/dev/null || true)" 2>/dev/null || true)"
beszel_client_secret="$(jq -r '.OIDC_CLIENT_SECRET // empty' <<<"$(openbao_read_global_secret_json beszel-oidc 2>/dev/null || true)" 2>/dev/null || true)"
[[ -n "$beszel_client_id" ]] || beszel_client_id="$(openssl rand -hex 16)"
[[ -n "$beszel_client_secret" ]] || beszel_client_secret="$(openssl rand -hex 24)"

log "Provisioning Authentik OIDC client for Beszel"

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik openid scope mapping ID"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik email scope mapping ID"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik profile scope mapping ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

provider_payload="$(
  jq -n \
    --arg name "Beszel Monitoring" \
    --arg client_id "$beszel_client_id" \
    --arg client_secret "$beszel_client_secret" \
    --arg redirect_uri "$beszel_redirect_uri" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '{
      name: $name,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      client_id: $client_id,
      client_secret: $client_secret,
      redirect_uris: [{
        matching_mode: "strict",
        url: $redirect_uri,
        redirect_uri_type: "authorization"
      }],
      property_mappings: [$openid, $email, $profile],
      signing_key: $signing_key,
      include_claims_in_id_token: true,
      client_type: "confidential",
      grant_types: ["authorization_code"],
      issuer_mode: "per_provider"
    }'
)"

provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Beszel"

application_payload="$(
  jq -n \
    --arg name "Beszel" \
    --arg slug "$beszel_application_slug" \
    --arg provider_pk "$provider_pk" \
    '{name: $name, slug: $slug, provider: ($provider_pk | tonumber)}'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Beszel"

application_json="$(find_application_json_by_slug "$beszel_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Beszel"
ensure_group_binding "$application_uuid" "$admins_group_id"

beszel_oidc_secret_file="$(mktemp "${TMPDIR:-/tmp}/beszel-oidc-XXXXXX")"
tmp_files+=("$beszel_oidc_secret_file")
cat >"$beszel_oidc_secret_file" <<EOF
{
  "OIDC_CLIENT_ID": "$beszel_client_id",
  "OIDC_CLIENT_SECRET": "$beszel_client_secret",
  "OIDC_ISSUER_URL": "$beszel_issuer_url",
  "OIDC_SCOPES": "openid profile email",
  "BESZEL_OIDC_CLIENT_ID": "$beszel_client_id",
  "BESZEL_OIDC_CLIENT_SECRET": "$beszel_client_secret",
  "BESZEL_OIDC_PROVIDER_URL": "$beszel_issuer_url",
  "CLUSTER_ID": "$cluster_id"
}
EOF
chmod 600 "$beszel_oidc_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "beszel-oidc" \
  --json-file "$beszel_oidc_secret_file" \
  --required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL,OIDC_SCOPES,BESZEL_OIDC_CLIENT_ID,BESZEL_OIDC_CLIENT_SECRET,BESZEL_OIDC_PROVIDER_URL"

log "Configuring OIDC in Beszel PocketBase"
existing_collection="$(beszel_api_get "/api/collections/users" 2>/dev/null || true)"
if [[ -n "$existing_collection" ]]; then
  oauth_options="$(
    jq -n \
      --arg client_id "$beszel_client_id" \
      --arg client_secret "$beszel_client_secret" \
      --arg auth_url "${beszel_issuer_url}authorize/" \
      --arg token_url "${beszel_issuer_url}token/" \
      --arg userinfo_url "${beszel_issuer_url}userinfo/" \
      '{
        allowOAuth2: true,
        enabledOAuth2Providers: [{
          name: "authentik",
          clientId: $client_id,
          clientSecret: $client_secret,
          authUrl: $auth_url,
          tokenUrl: $token_url,
          userInfoUrl: $userinfo_url
        }]
      }'
  )"
  updated_options="$(jq --argjson oauth "$oauth_options" '.options |= (. // {}) + $oauth' <<<"$existing_collection")"
  beszel_api_write PATCH "/api/collections/users" "$updated_options" >/dev/null || \
    log "WARNING: Failed to configure OIDC provider in Beszel PocketBase"
fi

log "Configuring Beszel Traefik route"
apply_beszel_traefik_route

log "Registering Beszel NetBird service"
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "beszel" \
  --service-domain "beszel.${public_zone_name}" \
  --service-path /

log "Configuring Beszel agent on NetBird bastion when available"
bash "$WORKSPACE_ROOT/scripts/manager/configure-bastion-beszel-agent.sh" \
  --cluster-id "$cluster_id" \
  --agent-secret-file "$beszel_agent_secret_file" \
  --beszel-version "$beszel_version"

log "Deploying Beszel agent DaemonSet through Argo CD"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/beszel-agents.yaml" \
  --application "beszel-agents" \
  --destination-namespace "beszel" \
  --skip-namespace-baseline

log "Beszel monitoring installation complete"
