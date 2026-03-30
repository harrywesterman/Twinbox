#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# Parse cluster context
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

# Parse inputs
cloudflare_api_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cloudflare_api_token')"
zone_name="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.zone_name')"

# Validate required inputs
[[ -n "$cloudflare_api_token" ]] || fail "Cloudflare API token is required"
[[ -n "$zone_name" ]] || fail "Domain name is required"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Cloudflare DNS configuration for cluster: $cluster_id"

# Read Wiredoor bastion secrets (per cluster) to get the IP address
wiredoor_secrets="/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-${cluster_id}.json"
[[ -f "$wiredoor_secrets" ]] || fail "Wiredoor bastion secrets not found at $wiredoor_secrets"

target_ipv4="$(jq -r '.WIREDOOR_IP' "$wiredoor_secrets")"
[[ -n "$target_ipv4" && "$target_ipv4" != "null" ]] || fail "Could not read Wiredoor IP from secrets"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor IP: $target_ipv4"

# Generate DNS record names based on cluster slug
if [[ "$cluster_id" == "prd" ]]; then
  wiredoor_record_name="wiredoor"
  wildcard_prefix=""
else
  wiredoor_record_name="wiredoor-${cluster_id}"
  wildcard_prefix="${cluster_id}."
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor record: ${wiredoor_record_name}.${zone_name}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wildcard record: *.${wildcard_prefix}${zone_name}"

# Get Cloudflare zone ID via API
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fetching Cloudflare zone ID for $zone_name"
zone_response="$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" \
  -H "Authorization: Bearer $cloudflare_api_token" \
  -H "Content-Type: application/json")"

zone_success="$(echo "$zone_response" | jq -r '.success')"
if [[ "$zone_success" != "true" ]]; then
  error_msg="$(echo "$zone_response" | jq -r '.errors[0].message // "Unknown error"')"
  fail "Failed to fetch Cloudflare zone: $error_msg"
fi

cloudflare_zone_id="$(echo "$zone_response" | jq -r '.result[0].id // empty')"
[[ -n "$cloudflare_zone_id" ]] || fail "Zone not found for domain: $zone_name"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Zone ID: $cloudflare_zone_id"

# Prepare OpenTofu working directory (per cluster)
tf_workdir="$MANAGER_DATA_DIR/opentofu/cloudflare-${cluster_id}"
mkdir -p "$tf_workdir"

# Copy OpenTofu files
cp -r infra/opentofu/cloudflare/* "$tf_workdir/"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing OpenTofu"
cd "$tf_workdir"
tofu init -input=false

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying OpenTofu configuration"
tofu apply -auto-approve \
  -var "cloudflare_api_token=$cloudflare_api_token" \
  -var "cloudflare_zone_id=$cloudflare_zone_id" \
  -var "zone_name=$zone_name" \
  -var "wiredoor_record_name=$wiredoor_record_name" \
  -var "target_ipv4=$target_ipv4" \
  -var "wiredoor_record_proxied=false" \
  -var "wildcard_record_proxied=false"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Collecting outputs"
wiredoor_fqdn="$(tofu output -raw wiredoor_fqdn)"
wildcard_fqdn="$(tofu output -raw wildcard_fqdn)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS records created successfully"
echo "  Wiredoor FQDN: $wiredoor_fqdn"
echo "  Wildcard FQDN: $wildcard_fqdn"

# Save Cloudflare credentials to secrets (per cluster)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing secrets to bootstrap directory"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/cloudflare-${cluster_id}.json" <<EOF
{
  "CLOUDFLARE_API_TOKEN": "$cloudflare_api_token",
  "CLOUDFLARE_ZONE_ID": "$cloudflare_zone_id",
  "ZONE_NAME": "$zone_name",
  "WIREDOOR_FQDN": "$wiredoor_fqdn",
  "WILDCARD_FQDN": "$wildcard_fqdn",
  "TARGET_IPV4": "$target_ipv4",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$secrets_dir/cloudflare-${cluster_id}.json"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "wiredoor_fqdn": "$wiredoor_fqdn",
  "wildcard_fqdn": "$wildcard_fqdn",
  "target_ipv4": "$target_ipv4",
  "zone_name": "$zone_name",
  "cluster_id": "$cluster_id",
  "secrets_path": "$secrets_dir/cloudflare-${cluster_id}.json"
}
EOF
fi
