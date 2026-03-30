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
hcloud_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_token')"
hcloud_location="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_location // "fsn1"')"
hcloud_server_type="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_server_type // "cax11"')"
zone_name="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.zone_name')"
wiredoor_network="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.wiredoor_network // "10.200.0.0/24"')"
ssh_public_key="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ssh_public_key // ""')"

# Validate required inputs
[[ -n "$hcloud_token" ]] || fail "Hetzner API token is required"
[[ -n "$zone_name" ]] || fail "Domain name is required"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Wiredoor bastion host provisioning for cluster: $cluster_id"

# Generate FQDN based on cluster slug
if [[ "$cluster_id" == "prd" ]]; then
  wiredoor_fqdn="wiredoor.${zone_name}"
  server_name="wiredoor"
else
  wiredoor_fqdn="wiredoor-${cluster_id}.${zone_name}"
  server_name="wiredoor-${cluster_id}"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor FQDN: $wiredoor_fqdn"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Server name: $server_name"

# Generate random admin password (32 chars)
wiredoor_admin_password="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Generated admin password"

# Handle SSH key
if [[ -z "$ssh_public_key" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] No SSH public key provided, generating new key pair"
  ssh_key_dir="$MANAGER_DATA_DIR/ssh/wiredoor-${cluster_id}"
  mkdir -p "$ssh_key_dir"
  
  if [[ ! -f "$ssh_key_dir/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -f "$ssh_key_dir/id_ed25519" -N "" -q
  fi
  
  ssh_public_key="$(cat "$ssh_key_dir/id_ed25519.pub")"
  ssh_private_key="$(cat "$ssh_key_dir/id_ed25519")"
else
  ssh_private_key=""
fi

# Prepare OpenTofu working directory (per cluster)
tf_workdir="$MANAGER_DATA_DIR/opentofu/wiredoor-${cluster_id}"
mkdir -p "$tf_workdir"

# Copy OpenTofu files
cp -r infra/opentofu/wiredoor/* "$tf_workdir/"

# Generate wiredoor admin email from FQDN
wiredoor_admin_email="admin@${wiredoor_fqdn#*.}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing OpenTofu"
cd "$tf_workdir"
tofu init -input=false

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying OpenTofu configuration"
tofu apply -auto-approve \
  -var "hcloud_token=$hcloud_token" \
  -var "ssh_public_key=$ssh_public_key" \
  -var "server_name=$server_name" \
  -var "server_type=$hcloud_server_type" \
  -var "image=debian-13" \
  -var "location=$hcloud_location" \
  -var "wiredoor_fqdn=$wiredoor_fqdn" \
  -var "wiredoor_admin_email=$wiredoor_admin_email" \
  -var "wiredoor_admin_password=$wiredoor_admin_password" \
  -var "wiredoor_vpn_port=51820" \
  -var "wiredoor_tcp_service_port_range=32760-32767"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Collecting outputs"
server_ipv4="$(tofu output -raw server_ipv4)"
wiredoor_url="$(tofu output -raw wiredoor_url)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor bastion host provisioned successfully"
echo "  Server IP: $server_ipv4"
echo "  Wiredoor URL: $wiredoor_url"
echo "  Server name: $server_name"

# Write secrets (per cluster)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing secrets to bootstrap directory"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/wiredoor-bastion-${cluster_id}.json" <<EOF
{
  "HCLOUD_TOKEN": "$hcloud_token",
  "WIREDOOR_IP": "$server_ipv4",
  "WIREDOOR_ADMIN_PASSWORD": "$wiredoor_admin_password",
  "WIREDOOR_URL": "$wiredoor_url",
  "WIREDOOR_FQDN": "$wiredoor_fqdn",
  "WIREDOOR_NETWORK": "$wiredoor_network",
  "CLUSTER_ID": "$cluster_id"
}
EOF

if [[ -n "$ssh_private_key" ]]; then
  # Add SSH private key to secrets file
  jq --arg key "$ssh_private_key" '. + {SSH_PRIVATE_KEY: $key}' \
    "$secrets_dir/wiredoor-bastion-${cluster_id}.json" > "$secrets_dir/wiredoor-bastion-${cluster_id}.json.tmp" \
    && mv "$secrets_dir/wiredoor-bastion-${cluster_id}.json.tmp" "$secrets_dir/wiredoor-bastion-${cluster_id}.json"
fi

chmod 600 "$secrets_dir/wiredoor-bastion-${cluster_id}.json"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "server_ipv4": "$server_ipv4",
  "wiredoor_url": "$wiredoor_url",
  "wiredoor_fqdn": "$wiredoor_fqdn",
  "server_name": "$server_name",
  "wiredoor_network": "$wiredoor_network",
  "cluster_id": "$cluster_id",
  "secrets_path": "$secrets_dir/wiredoor-bastion-${cluster_id}.json"
}
EOF
fi
