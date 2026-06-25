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

delete_hcloud_resources_by_name() {
  local resource_type="$1"
  shift
  local resource_name

  for resource_name in "$@"; do
    [[ -n "$resource_name" ]] || continue
    python3 - "$hcloud_token" "$resource_type" "$resource_name" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

token, resource_type, resource_name = sys.argv[1:]
base_url = "https://api.hetzner.cloud/v1"
headers = {"Authorization": f"Bearer {token}"}
query = urllib.parse.urlencode({"name": resource_name})
request = urllib.request.Request(f"{base_url}/{resource_type}?{query}", headers=headers)

with urllib.request.urlopen(request) as response:
    payload = json.load(response)

items = payload.get(resource_type, [])
for item in items:
    if item.get("name") != resource_name:
        continue

    delete_request = urllib.request.Request(
        f"{base_url}/{resource_type}/{item['id']}",
        headers=headers,
        method="DELETE",
    )

    for attempt in range(1, 11):
        try:
            with urllib.request.urlopen(delete_request):
                pass
            print(f"Deleted existing Hetzner {resource_type[:-1]}: {resource_name}")
            break
        except urllib.error.HTTPError as exc:
            if exc.code not in {409, 422} or attempt == 10:
                raise
            time.sleep(3)
PY
  done
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

bastion_cloud_init_log_path="/var/log/cloud-init-output.log"
bastion_cloud_init_last_line=0

redact_bastion_cloud_init_log() {
  sed -E \
    -e 's/(personal_access_token["'"'"']?[[:space:]]*[:=][[:space:]]*)["'"'"']?[^"'"'"',}[:space:]]+["'"'"']?/\1[REDACTED]/Ig' \
    -e 's/((access_)?token["'"'"']?[[:space:]]*[:=][[:space:]]*)["'"'"']?[^"'"'"',}[:space:]]+["'"'"']?/\1[REDACTED]/Ig' \
    -e 's/(password["'"'"']?[[:space:]]*[:=][[:space:]]*)["'"'"']?[^"'"'"',}[:space:]]+["'"'"']?/\1[REDACTED]/Ig' \
    -e 's/(secret["'"'"']?[[:space:]]*[:=][[:space:]]*)["'"'"']?[^"'"'"',}[:space:]]+["'"'"']?/\1[REDACTED]/Ig' \
    -e 's/([A-Za-z0-9_]*(TOKEN|PASSWORD|SECRET|PRIVATE_KEY)[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/(Auth secret:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/-----BEGIN OPENSSH PRIVATE KEY-----/[REDACTED OPENSSH PRIVATE KEY]/g' \
    -e 's/-----END OPENSSH PRIVATE KEY-----/[REDACTED OPENSSH PRIVATE KEY]/g'
}

emit_bastion_cloud_init_lines() {
  local lines="$1"
  [[ -n "$lines" ]] || return 1

  printf '%s\n' "$lines" |
    redact_bastion_cloud_init_log |
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '[bastion cloud-init] %s\n' "$line"
    done
}

bastion_cloud_init_line_count() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -i "$ssh_key_dir/id_ed25519" root@"$server_ipv4" \
    "test -f '$bastion_cloud_init_log_path' && wc -l < '$bastion_cloud_init_log_path' || echo 0" \
    2>/dev/null || echo 0
}

emit_bastion_cloud_init_tail() {
  local line_count="$1"
  local lines

  lines="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -i "$ssh_key_dir/id_ed25519" root@"$server_ipv4" \
    "test -f '$bastion_cloud_init_log_path' && tail -n '$line_count' '$bastion_cloud_init_log_path' || true" \
    2>/dev/null || true)"
  emit_bastion_cloud_init_lines "$lines" || true
  bastion_cloud_init_last_line="$(bastion_cloud_init_line_count)"
}

emit_new_bastion_cloud_init_lines() {
  local current_line
  local start_line
  local lines

  current_line="$(bastion_cloud_init_line_count)"
  if ! [[ "$current_line" =~ ^[0-9]+$ ]]; then
    current_line=0
  fi
  if ! [[ "$bastion_cloud_init_last_line" =~ ^[0-9]+$ ]]; then
    bastion_cloud_init_last_line=0
  fi
  if (( current_line <= bastion_cloud_init_last_line )); then
    return 1
  fi

  start_line=$((bastion_cloud_init_last_line + 1))
  lines="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -i "$ssh_key_dir/id_ed25519" root@"$server_ipv4" \
    "tail -n +$start_line '$bastion_cloud_init_log_path'" \
    2>/dev/null || true)"
  bastion_cloud_init_last_line="$current_line"
  emit_bastion_cloud_init_lines "$lines"
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
command -v python3 >/dev/null 2>&1 || fail "python3 is required to clean up stale Hetzner resources before provisioning NetBird."

# Read DNS provider and credentials from the external-dns secret
cluster_file="$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
if [[ -f "$cluster_file" ]]; then
  dns_provider="$(jq -r '.selected_dns_provider // empty' "$cluster_file")"
fi
if [[ -z "$dns_provider" ]]; then
  dns_provider="$(kubectl get secret external-dns-credentials -n external-dns -o jsonpath='{.metadata.annotations}' 2>/dev/null | jq -r '.["twinbox.io/dns-provider"] // empty' || true)"
fi
if [[ -z "$dns_provider" ]]; then
  dns_provider="$(kubectl get secret external-dns-credentials -n external-dns -o json 2>/dev/null | jq -r '
    if .data.CF_API_TOKEN or .data.token then "cloudflare"
    elif .data.AWS_ACCESS_KEY_ID or .data["access-key"] then "aws"
    elif .data.DO_TOKEN then "digitalocean"
    else ""
    end' 2>/dev/null || true)"
fi
[[ -n "$dns_provider" ]] || fail "Could not determine DNS provider. Please run Configure DNS Provider before provisioning NetBird."

dns_api_token=""
dns_api_secret=""
case "$dns_provider" in
  cloudflare)
    dns_api_token="$(kubectl get secret external-dns-credentials -n external-dns -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    ;;
  aws)
    dns_api_token="$(kubectl get secret external-dns-credentials -n external-dns -o jsonpath='{.data.access-key}' 2>/dev/null | base64 -d || true)"
    dns_api_secret="$(kubectl get secret external-dns-credentials -n external-dns -o jsonpath='{.data.secret-key}' 2>/dev/null | base64 -d || true)"
    ;;
  digitalocean)
    dns_api_token="$(kubectl get secret external-dns-credentials -n external-dns -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    ;;
  *)
    fail "Unsupported DNS provider for wildcard certificate: $dns_provider"
    ;;
esac
[[ -n "$dns_api_token" ]] || fail "Could not read DNS API token from external-dns-credentials secret"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS provider for wildcard certificate: $dns_provider"

netbird_fqdn="netbird.${public_zone_name}"
netbird_proxy_domain="${public_zone_name}"
server_name="netbird-${cluster_id}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting NetBird bastion provisioning for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird FQDN: $netbird_fqdn"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird proxy domain: $netbird_proxy_domain"

server_name="twinbox-${cluster_id}-netbird"
legacy_server_name="netbird-${cluster_id}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird Hetzner resource prefix: $server_name"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removing stale Hetzner resources from previous runs"
delete_hcloud_resources_by_name "servers" "$legacy_server_name" "$server_name"
delete_hcloud_resources_by_name "firewalls" "${legacy_server_name}-fw" "${server_name}-fw"
delete_hcloud_resources_by_name "ssh_keys" "${legacy_server_name}-ssh-key" "${server_name}-ssh-key"

opkssh_issuer_url=""
opkssh_client_id=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  opkssh_secret_json="$(openbao_read_global_secret_json opkssh 2>/dev/null || true)"
  opkssh_issuer_url="$(jq -r '.OIDC_ISSUER_URL // empty' <<<"${opkssh_secret_json:-null}")"
  opkssh_client_id="$(jq -r '.OIDC_CLIENT_ID // empty' <<<"${opkssh_secret_json:-null}")"
fi

apply_netbird_tofu() {
  local server_type="$1"
  local apply_log_file
  local tofu_status

  apply_log_file="$(mktemp "${TMPDIR:-/tmp}/netbird-tofu-apply-XXXXXX")"

  local opkssh_vars=()
  if [[ -n "$opkssh_issuer_url" && -n "$opkssh_client_id" ]]; then
    opkssh_vars+=( -var "opkssh_issuer_url=$opkssh_issuer_url" )
    opkssh_vars+=( -var "opkssh_client_id=$opkssh_client_id" )
  fi

  if tofu apply -no-color -auto-approve -input=false \
    -var "hcloud_token=$hcloud_token" \
    -var "ssh_public_key=$ssh_public_key" \
    -var "server_name=$server_name" \
    -var "server_type=$server_type" \
    -var "image=debian-13" \
    -var "location=$hcloud_location" \
    -var "netbird_fqdn=$netbird_fqdn" \
    -var "netbird_proxy_domain=$netbird_proxy_domain" \
    -var "public_zone_name=$public_zone_name" \
    -var "netbird_admin_email=$netbird_admin_email" \
    -var "netbird_version=${PINNED_NETBIRD_VERSION:-0.70.5}" \
    -var "dns_provider=$dns_provider" \
    -var "dns_api_token=$dns_api_token" \
    -var "dns_api_secret=$dns_api_secret" \
    "${opkssh_vars[@]}" \
    2>&1 | tee "$apply_log_file"; then
    rm -f "$apply_log_file"
    return 0
  fi

  tofu_status=${PIPESTATUS[0]}
  if [[ "$server_type" == "cax11" ]] && grep -q "resource_unavailable" "$apply_log_file"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Hetzner placement for cax11 is unavailable; retrying once with cpx22" >&2
    rm -f "$apply_log_file"
    return 2
  fi

  cat "$apply_log_file" >&2
  rm -f "$apply_log_file"
  return "$tofu_status"
}

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
if apply_netbird_tofu "$hcloud_server_type"; then
  :
else
  apply_status=$?
  if [[ $apply_status -eq 2 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning up partially created Hetzner resources before retrying with cpx22"
    delete_hcloud_resources_by_name "servers" "$legacy_server_name" "$server_name"
    delete_hcloud_resources_by_name "firewalls" "${legacy_server_name}-fw" "${server_name}-fw"
    delete_hcloud_resources_by_name "ssh_keys" "${legacy_server_name}-ssh-key" "${server_name}-ssh-key"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Retrying NetBird VPS OpenTofu configuration with cpx22"
    if ! apply_netbird_tofu "cpx22"; then
      fail "NetBird bastion provisioning failed after retrying with cpx22. See the OpenTofu output above for details."
    fi
  else
    fail "NetBird bastion provisioning failed. See the OpenTofu output above for details."
  fi
fi

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
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Streaming bastion cloud-init output while waiting for setup token..."
  emit_bastion_cloud_init_tail 80
  for i in $(seq 1 60); do
    setup_token_result="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i "$ssh_key_dir/id_ed25519" root@"$server_ipv4" 'cat /opt/netbird/setup-result.json 2>/dev/null || echo "{}"' 2>/dev/null || echo "{}")"
    if echo "$setup_token_result" | jq -e '.personal_access_token' >/dev/null 2>&1; then
      emit_new_bastion_cloud_init_lines || true
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird automated setup completed."
      break
    fi
    if [[ $i -eq 60 ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Last bastion cloud-init output before timeout:"
      emit_bastion_cloud_init_tail 120
      fail "NetBird automated setup did not produce a Personal Access Token in time. Check /var/log/cloud-init-output.log on the bastion host for the root cause."
    fi
    if ! emit_new_bastion_cloud_init_lines; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] No new bastion cloud-init output yet; waiting for setup token (attempt ${i}/60)..."
    fi
    sleep 10
  done
else
  fail "Cannot verify NetBird automated setup because no SSH private key is available. Use the generated NetBird bastion key so the wizard can fetch the setup token."
fi

if echo "$setup_token_result" | jq -e '.personal_access_token' >/dev/null 2>&1; then
  netbird_setup_token="$(echo "$setup_token_result" | jq -r '.personal_access_token')"
  tmp_file="$(mktemp)"
  jq --arg token "$netbird_setup_token" '. + {NETBIRD_SETUP_TOKEN: $token}' "$secret_file" >"$tmp_file"
  mv "$tmp_file" "$secret_file"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird setup token saved to secret file."
else
  fail "No NetBird setup token found after bastion bootstrap. Check /var/log/cloud-init-output.log on the bastion host for the root cause."
fi
chmod 600 "$secret_file"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird bastion host provisioned successfully"
echo "  Server IP: $server_ipv4"
echo "  NetBird URL: $netbird_url"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg server_ipv4 "$server_ipv4" \
    --arg netbird_url "$netbird_url" \
    --arg netbird_fqdn "$netbird_fqdn" \
    --arg cluster_id "$cluster_id" \
    --arg secrets_path "$secret_file" \
    '{
      status: $status,
      server_ipv4: $server_ipv4,
      netbird_url: $netbird_url,
      netbird_fqdn: $netbird_fqdn,
      cluster_id: $cluster_id,
      secrets_path: $secrets_path
    }' >"$STEP_RESULT_FILE"
fi
