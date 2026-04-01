#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# Parse cluster context
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

# Parse inputs
cf_api_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cf_api_token')"
cf_account_id="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cf_account_id')"
cf_zone_id="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cf_zone_id')"

# Validate required inputs
[[ -n "$cf_api_token" ]] || fail "Cloudflare API token is required"
[[ -n "$cf_account_id" ]] || fail "Cloudflare account ID is required"
[[ -n "$cf_zone_id" ]] || fail "Cloudflare zone ID is required"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Cloudflare Tunnel configuration for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Account ID: $cf_account_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Zone ID: $cf_zone_id"

# Step 1: Create Cloudflare Tunnel
tunnel_name="twinbox-${cluster_id}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating tunnel: $tunnel_name"

tunnel_response="$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel" \
  -H "Authorization: Bearer $cf_api_token" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${tunnel_name}\",\"config_src\":\"local\"}")"

tunnel_success="$(echo "$tunnel_response" | jq -r '.success')"
if [[ "$tunnel_success" != "true" ]]; then
  # Check if tunnel already exists
  tunnel_exists="$(echo "$tunnel_response" | jq -r '.errors[0].message // ""')"
  if [[ "$tunnel_exists" == *"already exists"* ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tunnel already exists, fetching existing tunnel"
    tunnels_list="$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel?name=${tunnel_name}" \
      -H "Authorization: Bearer $cf_api_token" \
      -H "Content-Type: application/json")"
    cf_tunnel_id="$(echo "$tunnels_list" | jq -r '.result[0].id // empty')"
  else
    error_msg="$(echo "$tunnel_response" | jq -r '.errors[0].message // "Unknown error"')"
    fail "Failed to create Cloudflare tunnel: $error_msg"
  fi
else
  cf_tunnel_id="$(echo "$tunnel_response" | jq -r '.result.id')"
fi

[[ -n "$cf_tunnel_id" ]] || fail "Could not determine tunnel ID"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tunnel ID: $cf_tunnel_id"

# Step 2: Generate tunnel token
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Generating tunnel token"
token_response="$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel/${cf_tunnel_id}/token" \
  -H "Authorization: Bearer $cf_api_token" \
  -H "Content-Type: application/json")"

cf_tunnel_token="$(echo "$token_response" | jq -r '.result.Token // empty')"
[[ -n "$cf_tunnel_token" ]] || fail "Could not generate tunnel token"

# Step 3: Create DNS CNAME record pointing to the tunnel
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating DNS CNAME record for tunnel"
dns_response="$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${cf_zone_id}/dns_records" \
  -H "Authorization: Bearer $cf_api_token" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\":\"CNAME\",
    \"name\":\"*.${cluster_slug}\",
    \"content\":\"${cf_tunnel_id}.cfargotunnel.com\",
    \"proxied\":true,
    \"ttl\":1
  }")"

dns_success="$(echo "$dns_response" | jq -r '.success')"
if [[ "$dns_success" != "true" ]]; then
  dns_error="$(echo "$dns_response" | jq -r '.errors[0].message // "Unknown error"')"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: DNS record creation failed: $dns_error"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] You may need to create the DNS record manually"
fi

# Step 4: Store credentials as global secret
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing Cloudflare Tunnel credentials to secrets"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/cloudflare-tunnel-${cluster_id}.json" <<EOF
{
  "CF_API_TOKEN": "$cf_api_token",
  "CF_ACCOUNT_ID": "$cf_account_id",
  "CF_ZONE_ID": "$cf_zone_id",
  "CF_TUNNEL_ID": "$cf_tunnel_id",
  "CF_TUNNEL_TOKEN": "$cf_tunnel_token",
  "CF_TUNNEL_NAME": "$tunnel_name",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$secrets_dir/cloudflare-tunnel-${cluster_id}.json"

# Sync to OpenBao
if [[ -f "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing Cloudflare Tunnel credentials to OpenBao"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "cloudflare-tunnel" \
    --json-file "$secrets_dir/cloudflare-tunnel-${cluster_id}.json" \
    --required-keys "CF_API_TOKEN,CF_ACCOUNT_ID,CF_ZONE_ID,CF_TUNNEL_ID,CF_TUNNEL_TOKEN"
fi

# Step 5: Deploy cloudflared in the cluster
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying cloudflared in the cluster"
if command -v kubectl &>/dev/null; then
  # Wait for Argo CD to be available
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD to be ready"
  for i in $(seq 1 30); do
    if kubectl get application argocd -n argocd &>/dev/null; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD is ready"
      break
    fi
    sleep 5
  done

  # Apply the cloudflare-tunnel application
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying cloudflare-tunnel application"
  kubectl apply -f "$WORKSPACE_ROOT/gitops/apps/cloudflare-tunnel.yaml" 2>/dev/null || true
fi

# Store ingress strategy in cluster state
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recording ingress strategy as cloudflare-tunnel"
if [[ -f "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" ]]; then
  tmp_file="$(mktemp)"
  jq '.ingress_strategy = "cloudflare-tunnel"' "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" > "$tmp_file"
  mv "$tmp_file" "$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cloudflare Tunnel configuration complete"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "outputs": {
    "ingress_strategy": "cloudflare-tunnel",
    "cf_tunnel_id": "$cf_tunnel_id",
    "cf_tunnel_name": "$tunnel_name",
    "cluster_id": "$cluster_id"
  }
}
EOF
fi
