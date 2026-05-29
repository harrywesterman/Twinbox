#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
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
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing Beszel Monitoring for zone: ${public_zone_name}"

# ---------------------------------------------------------------------------
# Authentik OIDC provider setup
# ---------------------------------------------------------------------------
authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
beszel_application_slug="beszel"
beszel_redirect_uri="https://beszel.${public_zone_name}/oauth/callback"
beszel_issuer_url="${AUTHENTIK_HOST%/}/application/o/${beszel_application_slug}/"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

beszel_client_id="$(openssl rand -hex 16)"
beszel_client_secret="$(openssl rand -hex 24)"
authentik_oidc_state_key="authentik-beszel"

existing_beszel_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_beszel_secret_json="$(openbao_read_global_secret_json beszel-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_beszel_secret_json" ]]; then
  existing_client_id="$(jq -r '.OIDC_CLIENT_ID // empty' <<<"$existing_beszel_secret_json")"
  existing_client_secret="$(jq -r '.OIDC_CLIENT_SECRET // empty' <<<"$existing_beszel_secret_json")"
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    beszel_client_id="$existing_client_id"
    beszel_client_secret="$existing_client_secret"
  fi
fi

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response
  response="$(authentik_api_get "/providers/oauth2/?name=$(printf '%s' "$provider_name" | jq -sRr @uri)&page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]? | select((.name // "") == $provider_name) | .pk // .id // empty' \
    <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local response
  response="$(authentik_api_get "/core/applications/?slug=$(printf '%s' "$application_slug" | jq -sRr @uri)")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]? | select((.slug // "") == $application_slug)' \
    <<<"$response" | head -n1
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
  local existing_app_json
  existing_app_json="$(find_application_json_by_slug "$beszel_application_slug")"
  if [[ -n "$existing_app_json" ]]; then
    local existing_app_pk
    existing_app_pk="$(jq -r '.pk // .id // empty' <<<"$existing_app_json")"
    if [[ -n "$existing_app_pk" ]]; then
      authentik_api_write PATCH "/core/applications/${existing_app_pk}/" "$application_payload" >/dev/null
      printf '%s\n' "$existing_app_pk"
      return 0
    fi
  fi
  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Beszel"

provider_payload="$(
  jq -n \
    --arg name "Beszel Monitoring" \
    --arg client_id "$beszel_client_id" \
    --arg client_secret "$beszel_client_secret" \
    --arg redirect_uris "$beszel_redirect_uri" \
    --arg issuer_url "${AUTHENTIK_HOST%/}" \
    '{
      name: $name,
      authorization_flow: "default-provider-authorization-implicit-consent",
      client_id: $client_id,
      client_secret: $client_secret,
      redirect_uris: [$redirect_uris, $redirect_uris + "/"],
      issuer_url: $issuer_url,
      property_mappings: [],
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
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Beszel"

application_json="$(find_application_json_by_slug "$beszel_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Beszel"

admins_group_response="$(authentik_api_get "/groups/?name=Twinbox%20Admins")"
admins_group_id="$(jq -r '.results[0].pk // .results[0].id // empty' <<<"$admins_group_response")"
if [[ -n "$admins_group_id" ]]; then
  ensure_group_binding "$application_uuid" "$admins_group_id"
fi

# ---------------------------------------------------------------------------
# Beszel agent credentials
# ---------------------------------------------------------------------------
beszel_agent_key="$(openssl rand -hex 16)"
beszel_agent_token="$(openssl rand -hex 32)"

existing_agent_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_agent_secret_json="$(openbao_read_global_secret_json beszel-agent 2>/dev/null || true)"
fi

if [[ -n "$existing_agent_secret_json" ]]; then
  existing_key="$(jq -r '.BESZEL_AGENT_KEY // empty' <<<"$existing_agent_secret_json")"
  existing_token="$(jq -r '.BESZEL_AGENT_TOKEN // empty' <<<"$existing_agent_secret_json")"
  if [[ -n "$existing_key" && -n "$existing_token" ]]; then
    beszel_agent_key="$existing_key"
    beszel_agent_token="$existing_token"
  fi
fi

# ---------------------------------------------------------------------------
# Write secrets to OpenBao
# ---------------------------------------------------------------------------
beszel_oidc_secret_file="$(mktemp "${TMPDIR:-/tmp}/beszel-oidc-XXXXXX")"
trap 'rm -f "$beszel_oidc_secret_file"' EXIT

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

rm -f "$beszel_oidc_secret_file"

beszel_agent_secret_file="$(mktemp "${TMPDIR:-/tmp}/beszel-agent-XXXXXX")"
trap 'rm -f "$beszel_agent_secret_file"' EXIT

cat >"$beszel_agent_secret_file" <<EOF
{
  "BESZEL_AGENT_KEY": "$beszel_agent_key",
  "BESZEL_AGENT_TOKEN": "$beszel_agent_token",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$beszel_agent_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "beszel-agent" \
  --json-file "$beszel_agent_secret_file" \
  --required-keys "BESZEL_AGENT_KEY,BESZEL_AGENT_TOKEN"

rm -f "$beszel_agent_secret_file"

# ---------------------------------------------------------------------------
# Write env vars to /opt/twinbox/.env for docker compose
# ---------------------------------------------------------------------------
env_file="/opt/twinbox/.env"
if [[ -f "$env_file" ]]; then
  ensure_env_var() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$env_file"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
      printf '%s=%s\n' "$key" "$value" >>"$env_file"
    fi
  }

  ensure_env_var "BESZEL_AGENT_KEY" "$beszel_agent_key"
  ensure_env_var "BESZEL_AGENT_TOKEN" "$beszel_agent_token"
  ensure_env_var "BESZEL_OIDC_PROVIDER_URL" "$beszel_issuer_url"
  ensure_env_var "BESZEL_OIDC_CLIENT_ID" "$beszel_client_id"
  ensure_env_var "BESZEL_OIDC_CLIENT_SECRET" "$beszel_client_secret"
  ensure_env_var "BESZEL_VERSION" "${BESZEL_VERSION:-0.18.7}"
fi

# ---------------------------------------------------------------------------
# Start beszel hub + agent via docker compose
# ---------------------------------------------------------------------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Beszel docker services"
docker compose -f "$WORKSPACE_ROOT/docker-compose.yml" up -d beszel beszel-agent

# Wait for hub health
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Beszel hub to become healthy"
for i in $(seq 1 30); do
  if curl -sf http://localhost:8090/api/health >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Beszel hub is healthy"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Beszel hub did not become healthy within 60s, continuing anyway"
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# Register NetBird reverse proxy service
# ---------------------------------------------------------------------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Registering Beszel NetBird service"
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "beszel" \
  --service-domain "beszel.${public_zone_name}" \
  --service-path /

# ---------------------------------------------------------------------------
# Deploy beszel-agent DaemonSet on cluster via Argo CD
# ---------------------------------------------------------------------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Beszel agent DaemonSet on cluster"
kubectl delete application beszel-agents -n argocd --ignore-not-found=true 2>/dev/null || true

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/beszel-agents.yaml" \
  --application "beszel-agents" \
  --destination-namespace "beszel"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Beszel monitoring installation complete"
