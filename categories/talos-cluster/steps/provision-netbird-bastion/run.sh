#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "${cluster_dns_domain:-}")"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

hcloud_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_token')"
hcloud_location="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_location // "fsn1"')"
hcloud_server_type="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_server_type // "cax11"')"
zone_name="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.zone_name')"
netbird_admin_email="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_admin_email')"
ssh_public_key="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ssh_public_key // ""')"
cloudflare_api_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cloudflare_api_token // empty')"

[[ -n "$hcloud_token" ]] || fail "Hetzner API token is required"
[[ -n "$zone_name" ]] || fail "Domain name is required"
[[ -n "$netbird_admin_email" ]] || fail "Let's Encrypt email is required"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

netbird_fqdn="netbird.${public_zone_name}"
netbird_proxy_domain="proxy.${public_zone_name}"
if [[ "$cluster_id" == "prd" ]]; then
  server_name="netbird"
else
  server_name="netbird-${cluster_id}"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting NetBird bastion provisioning for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird FQDN: $netbird_fqdn"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird proxy domain: $netbird_proxy_domain"

if [[ -z "$ssh_public_key" ]]; then
  ssh_key_dir="$MANAGER_DATA_DIR/ssh/netbird-${cluster_id}"
  mkdir -p "$ssh_key_dir"
  if [[ ! -f "$ssh_key_dir/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -f "$ssh_key_dir/id_ed25519" -N "" -q
  fi
  ssh_public_key="$(cat "$ssh_key_dir/id_ed25519.pub")"
  ssh_private_key="$(cat "$ssh_key_dir/id_ed25519")"
else
  ssh_private_key=""
fi

tf_workdir="$MANAGER_DATA_DIR/opentofu/netbird-${cluster_id}"
mkdir -p "$tf_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/netbird/"* "$tf_workdir/"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing OpenTofu for NetBird VPS"
cd "$tf_workdir"
tofu init -input=false

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying NetBird VPS OpenTofu configuration"
tofu apply -auto-approve \
  -var "hcloud_token=$hcloud_token" \
  -var "ssh_public_key=$ssh_public_key" \
  -var "server_name=$server_name" \
  -var "server_type=$hcloud_server_type" \
  -var "image=debian-13" \
  -var "location=$hcloud_location" \
  -var "netbird_fqdn=$netbird_fqdn" \
  -var "netbird_proxy_domain=$netbird_proxy_domain" \
  -var "netbird_admin_email=$netbird_admin_email" \
  -var "netbird_version=${PINNED_NETBIRD_VERSION:-0.70.5}"

server_ipv4="$(tofu output -raw server_ipv4)"
netbird_url="$(tofu output -raw netbird_url)"

if [[ -n "$cloudflare_api_token" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird DNS records in Cloudflare"
  zone_response="$(curl -sS -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" \
    -H "Authorization: Bearer $cloudflare_api_token" \
    -H "Content-Type: application/json")"
  [[ "$(printf '%s' "$zone_response" | jq -r '.success')" == "true" ]] || fail "Failed to fetch Cloudflare zone"
  cloudflare_zone_id="$(printf '%s' "$zone_response" | jq -r '.result[0].id // empty')"
  [[ -n "$cloudflare_zone_id" ]] || fail "Cloudflare zone not found for $zone_name"

  relative_public_zone="${public_zone_name%.$zone_name}"
  if [[ "$relative_public_zone" == "$public_zone_name" ]]; then
    netbird_record_name="netbird"
    proxy_record_name="proxy"
  elif [[ -n "$relative_public_zone" ]]; then
    netbird_record_name="netbird.${relative_public_zone}"
    proxy_record_name="proxy.${relative_public_zone}"
  else
    netbird_record_name="netbird"
    proxy_record_name="proxy"
  fi

  dns_workdir="$MANAGER_DATA_DIR/opentofu/cloudflare-netbird-${cluster_id}"
  mkdir -p "$dns_workdir"
  cp -r "$WORKSPACE_ROOT/infra/opentofu/cloudflare-netbird/"* "$dns_workdir/"
  cd "$dns_workdir"
  tofu init -input=false
  tofu apply -auto-approve \
    -var "cloudflare_api_token=$cloudflare_api_token" \
    -var "cloudflare_zone_id=$cloudflare_zone_id" \
    -var "zone_name=$zone_name" \
    -var "netbird_record_name=$netbird_record_name" \
    -var "proxy_record_name=$proxy_record_name" \
    -var "target_ipv4=$server_ipv4"
fi

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"
secret_file="$secrets_dir/netbird-bastion-${cluster_id}.json"

jq -n \
  --arg hcloud_token "$hcloud_token" \
  --arg netbird_ip "$server_ipv4" \
  --arg netbird_url "$netbird_url" \
  --arg netbird_fqdn "$netbird_fqdn" \
  --arg netbird_proxy_domain "$netbird_proxy_domain" \
  --arg cluster_id "$cluster_id" \
  '{
    HCLOUD_TOKEN: $hcloud_token,
    NETBIRD_IP: $netbird_ip,
    NETBIRD_URL: $netbird_url,
    NETBIRD_FQDN: $netbird_fqdn,
    NETBIRD_PROXY_DOMAIN: $netbird_proxy_domain,
    CLUSTER_ID: $cluster_id
  }' >"$secret_file"

if [[ -n "$ssh_private_key" ]]; then
  tmp_file="$(mktemp)"
  jq --arg key "$ssh_private_key" '. + {SSH_PRIVATE_KEY: $key}' "$secret_file" >"$tmp_file"
  mv "$tmp_file" "$secret_file"
fi
chmod 600 "$secret_file"

# Wait for automated setup to complete and fetch the token
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NetBird automated setup to complete..."
setup_result_json=""
for i in $(seq 1 60); do
  if [[ -n "$ssh_private_key" ]]; then
    setup_result_json="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i "$ssh_key_dir/id_ed25519" root@"$server_ipv4" 'cat /opt/netbird/setup-result.json 2>/dev/null || echo "{}"' 2>/dev/null || echo "{}")"
  fi
  if echo "$setup_result_json" | jq -e '.personal_access_token' >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird automated setup completed."
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: NetBird automated setup did not complete in time. You may need to create a Personal Access Token manually." >&2
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NetBird setup (attempt ${i}/60)..."
  sleep 10
done

if echo "$setup_result_json" | jq -e '.personal_access_token' >/dev/null 2>&1; then
  netbird_setup_token="$(echo "$setup_result_json" | jq -r '.personal_access_token')"
  tmp_file="$(mktemp)"
  jq --arg token "$netbird_setup_token" '. + {NETBIRD_SETUP_TOKEN: $token}' "$secret_file" >"$tmp_file"
  mv "$tmp_file" "$secret_file"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird setup token saved to secret file."
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: No setup token found. Step 'configure-netbird-ingress' will require a manual NetBird API token." >&2
fi
chmod 600 "$secret_file"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird bastion host provisioned successfully"
echo "  Server IP: $server_ipv4"
echo "  NetBird URL: $netbird_url"
echo "  Proxy domain: $netbird_proxy_domain"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg server_ipv4 "$server_ipv4" \
    --arg netbird_url "$netbird_url" \
    --arg netbird_fqdn "$netbird_fqdn" \
    --arg netbird_proxy_domain "$netbird_proxy_domain" \
    --arg cluster_id "$cluster_id" \
    --arg secrets_path "$secret_file" \
    '{
      status: $status,
      server_ipv4: $server_ipv4,
      netbird_url: $netbird_url,
      netbird_fqdn: $netbird_fqdn,
      netbird_proxy_domain: $netbird_proxy_domain,
      cluster_id: $cluster_id,
      secrets_path: $secrets_path
    }' >"$STEP_RESULT_FILE"
fi
