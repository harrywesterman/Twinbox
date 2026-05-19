#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

read_first_admin_email() {
  local cluster_scope="$1"
  local state_file
  local email
  local candidate_paths=(
    "$MANAGER_DATA_DIR/step-state/clusters/${cluster_scope}/create-users-and-groups.json"
    "$MANAGER_DATA_DIR/step-state/clusters/${cluster_id}/create-users-and-groups.json"
    "$MANAGER_DATA_DIR/step-state/global/create-users-and-groups.json"
  )

  for state_file in "${candidate_paths[@]}"; do
    [[ -f "$state_file" ]] || continue
    email="$(jq -r '.inputs.email // .outputs.email // empty' "$state_file")"
    if [[ -n "$email" ]]; then
      printf '%s\n' "$email"
      return 0
    fi
  done

  return 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_scope_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // .instance_id // .id // empty')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
public_zone_name="$(printf '%s' "$cluster_json" | jq -r '.public_zone_name // empty')"
if [[ -z "$public_zone_name" && -n "$cluster_dns_domain" ]]; then
  public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
fi

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

hcloud_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_token')"
hcloud_location="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_location // "fsn1"')"
hcloud_server_type="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_server_type // "cax11"')"
netbird_admin_email="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_admin_email // empty')"
ssh_public_key="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ssh_public_key // ""')"

if [[ -z "$netbird_admin_email" ]]; then
  netbird_admin_email="$(read_first_admin_email "$cluster_scope_id" || true)"
fi

[[ -n "$hcloud_token" ]] || fail "Hetzner API token is required"
[[ -n "$netbird_admin_email" ]] || fail "First admin email is required. Please run Create Users and Groups before provisioning NetBird."
[[ -n "$cluster_dns_domain" ]] || fail "DNS domain not found. Please run Configure DNS Provider before provisioning NetBird."
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name from the configured DNS provider"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required to create NetBird DNS records through external-dns"
command -v ssh >/dev/null 2>&1 || fail "ssh is required to fetch the NetBird setup token. Refresh the manager-worker image so OpenSSH client tools are available."
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required to create the NetBird bootstrap key. Refresh the manager-worker image so OpenSSH client tools are available."

netbird_fqdn="netbird.${public_zone_name}"
netbird_proxy_domain="proxy.${public_zone_name}"
server_name="netbird-${cluster_id}"

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
tofu init -no-color -input=false

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying NetBird VPS OpenTofu configuration"
tofu apply -no-color -auto-approve -input=false \
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird DNS records through external-dns"
kubectl apply -f - <<EOF
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: netbird-bastion-dns
  namespace: external-dns
spec:
  endpoints:
    - dnsName: ${netbird_fqdn}
      recordType: A
      targets:
        - ${server_ipv4}
      recordTTL: 300
    - dnsName: ${netbird_proxy_domain}
      recordType: A
      targets:
        - ${server_ipv4}
      recordTTL: 300
EOF

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

# Wait for cloud-init to finish and poll for setup token via SSH
setup_token_result="{}"
if [[ -n "$ssh_private_key" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for SSH on $server_ipv4..."
  for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i "$ssh_key_dir/id_ed25519" root@"$server_ipv4" 'echo SSH_OK' 2>/dev/null; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] SSH connection established."
      break
    fi
    if [[ $i -eq 30 ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Could not establish SSH connection to $server_ipv4." >&2
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for SSH (attempt ${i}/30)..."
    sleep 10
  done

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NetBird automated setup to complete..."
  for i in $(seq 1 60); do
    setup_token_result="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i "$ssh_key_dir/id_ed25519" root@"$server_ipv4" 'cat /opt/netbird/setup-result.json 2>/dev/null || echo "{}"' 2>/dev/null || echo "{}")"
    if echo "$setup_token_result" | jq -e '.personal_access_token' >/dev/null 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird automated setup completed."
      break
    fi
    if [[ $i -eq 60 ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: NetBird automated setup did not complete in time. You may need to create a Personal Access Token manually." >&2
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NetBird setup (attempt ${i}/60)..."
    sleep 10
  done
fi

if echo "$setup_token_result" | jq -e '.personal_access_token' >/dev/null 2>&1; then
  netbird_setup_token="$(echo "$setup_token_result" | jq -r '.personal_access_token')"
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
