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
bastion_ssh_host=""
bastion_ssh_port="22"
bastion_ssh_user="root"
bastion_ssh_key_path=""

bastion_ssh() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -o BatchMode=yes \
    -p "$bastion_ssh_port" \
    -i "$bastion_ssh_key_path" \
    "${bastion_ssh_user}@${bastion_ssh_host}" \
    "$@"
}

temp_paths=()
cleanup_temp_paths() {
  local path
  for path in "${temp_paths[@]}"; do
    [[ -n "$path" ]] || continue
    if [[ -d "$path" ]]; then
      rm -rf "$path"
    else
      rm -f "$path"
    fi
  done
}
trap cleanup_temp_paths EXIT

register_temp_path() {
  temp_paths+=("$1")
}

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
  bastion_ssh \
    "test -f '$bastion_cloud_init_log_path' && wc -l < '$bastion_cloud_init_log_path' || echo 0" \
    2>/dev/null || echo 0
}

emit_bastion_cloud_init_tail() {
  local line_count="$1"
  local lines

  lines="$(bastion_ssh \
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
  lines="$(bastion_ssh \
    "tail -n +$start_line '$bastion_cloud_init_log_path'" \
    2>/dev/null || true)"
  bastion_cloud_init_last_line="$current_line"
  emit_bastion_cloud_init_lines "$lines"
}

validate_ipv4() {
  local value="$1"
  python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address.version == 4 else 1)
PY
}

create_netbird_dns_records() {
  local public_ipv4="$1"

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
        - ${public_ipv4}
      recordTTL: 300
EOF
}

wait_for_bastion_public_dns_records() {
  local public_ipv4="$1"
  shift
  local record
  local record_args=()
  local output

  for record in "$@"; do
    record_args+=( --record "${record}=${public_ipv4}" )
  done

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for public DNS records to resolve to ${public_ipv4}"
  for i in $(seq 1 60); do
    if output="$(python3 "$WORKSPACE_ROOT/scripts/manager/check-bastion-public-reachability.py" "${record_args[@]}" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public DNS is not ready yet (attempt ${i}/60): ${output}"
    sleep 5
  done

  fail "Public DNS records did not resolve to ${public_ipv4} in time"
}

write_bastion_secret() {
  local provider="$1"
  local mode="$2"
  local public_ipv4="$3"
  local ssh_host="$4"
  local ssh_port="$5"
  local ssh_user="$6"
  local os_family="$7"
  local rdns_provider="$8"
  local rdns_status="$9"
  local hcloud_token_value="${10}"
  local ssh_private_key_value="${11}"

  mkdir -p "$secrets_dir"
  jq -n \
    --arg hcloud_token "$hcloud_token_value" \
    --arg ssh_private_key "$ssh_private_key_value" \
    --arg netbird_ip "$public_ipv4" \
    --arg netbird_url "$netbird_url" \
    --arg netbird_fqdn "$netbird_fqdn" \
    --arg netbird_proxy_domain "$netbird_proxy_domain" \
    --arg cluster_id "$cluster_id" \
    --arg provider "$provider" \
    --arg mode "$mode" \
    --arg public_ipv4 "$public_ipv4" \
    --arg ssh_host "$ssh_host" \
    --arg ssh_port "$ssh_port" \
    --arg ssh_user "$ssh_user" \
    --arg os_family "$os_family" \
    --arg rdns_provider "$rdns_provider" \
    --arg rdns_status "$rdns_status" \
    '{
      NETBIRD_IP: $netbird_ip,
      NETBIRD_URL: $netbird_url,
      NETBIRD_FQDN: $netbird_fqdn,
      NETBIRD_PROXY_DOMAIN: $netbird_proxy_domain,
      CLUSTER_ID: $cluster_id,
      BASTION_PROVIDER: $provider,
      BASTION_MODE: $mode,
      BASTION_PUBLIC_IPV4: $public_ipv4,
      BASTION_SSH_HOST: $ssh_host,
      BASTION_SSH_PORT: $ssh_port,
      BASTION_SSH_USER: $ssh_user,
      BASTION_OS_FAMILY: $os_family,
      BASTION_RDNS_PROVIDER: $rdns_provider,
      BASTION_RDNS_STATUS: $rdns_status
    }
    + (if $hcloud_token != "" then {HCLOUD_TOKEN: $hcloud_token} else {} end)
    + (if $ssh_private_key != "" then {SSH_PRIVATE_KEY: $ssh_private_key} else {} end)' >"$secret_file"
  chmod 600 "$secret_file"
}

save_netbird_setup_token() {
  local setup_token_result="$1"
  local token
  local tmp_file

  if ! echo "$setup_token_result" | jq -e '.personal_access_token' >/dev/null 2>&1; then
    fail "No NetBird setup token found after bastion bootstrap. Check /var/log/cloud-init-output.log on the bastion host for the root cause."
  fi

  token="$(echo "$setup_token_result" | jq -r '.personal_access_token')"
  tmp_file="$(mktemp)"
  jq --arg token "$token" '. + {
    NETBIRD_ADMIN_TOKEN: $token,
    NETBIRD_SETUP_TOKEN: $token
  }' "$secret_file" >"$tmp_file"
  mv "$tmp_file" "$secret_file"
  chmod 600 "$secret_file"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird API token saved to secret file."
}

read_existing_bastion_os_family() {
  local os_release="$1"

  python3 - "$os_release" <<'PY'
import shlex
import sys

fields = {}
for line in sys.argv[1].splitlines():
    if "=" not in line or line.lstrip().startswith("#"):
        continue
    key, value = line.split("=", 1)
    try:
        fields[key] = shlex.split(value)[0] if value else ""
    except ValueError:
        fields[key] = value.strip('"')

tokens = {fields.get("ID", "").lower()}
tokens.update(fields.get("ID_LIKE", "").lower().split())
if "ubuntu" in tokens:
    print("ubuntu")
elif "debian" in tokens:
    print("debian")
PY
}

install_existing_bastion_prerequisites() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing/verifying existing bastion prerequisites"
  bastion_ssh 'bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: existing-vm bootstrap currently supports Debian/Ubuntu hosts with apt-get." >&2
  exit 1
fi

apt-get update -y >/dev/null
apt-get install -y ca-certificates curl jq openssl python3 python3-yaml >/dev/null

if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi '^Status: active'; then
  ufw allow 80/tcp >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
  ufw allow 3478/udp >/dev/null || true
  ufw reload >/dev/null || true
else
  echo "UFW is not active; ensure provider firewall or router forwarding allows TCP 80/443 and UDP 3478."
fi
REMOTE
}

upload_existing_bastion_bootstrap() {
  local render_dir="$1"
  local remote_dir="/root/twinbox-netbird-bootstrap"

  bastion_ssh "install -d -m 0700 '$remote_dir'"
  scp -q -P "$bastion_ssh_port" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "$bastion_ssh_key_path" \
    "$render_dir/bootstrap-netbird.sh" \
    "$render_dir/bootstrap.env" \
    "$render_dir/dns-credentials" \
    "${bastion_ssh_user}@${bastion_ssh_host}:${remote_dir}/"

  bastion_ssh 'install -d -m 0755 /opt/netbird && install -m 0600 /root/twinbox-netbird-bootstrap/bootstrap.env /opt/netbird/.bootstrap.env && install -m 0600 /root/twinbox-netbird-bootstrap/dns-credentials /opt/netbird/.dns-credentials && install -m 0700 /root/twinbox-netbird-bootstrap/bootstrap-netbird.sh /root/bootstrap-netbird.sh'
}

run_existing_bastion_bootstrap() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running shared NetBird bootstrap on existing bastion"
  if ! bastion_ssh '/root/bootstrap-netbird.sh' 2>&1 |
    redact_bastion_cloud_init_log |
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '[bastion bootstrap] %s\n' "$line"
    done; then
    fail "Existing bastion bootstrap failed. Review the redacted bootstrap output above."
  fi
}

provision_existing_bastion() {
  local existing_mode="$1"
  local public_ipv4="$2"
  local ssh_host="$3"
  local ssh_port="$4"
  local ssh_user="$5"
  local ssh_private_key_input="$6"
  local requested_os_family="$7"
  local confirm_clean_host="$8"
  local confirm_port_forwarding="$9"
  local key_file
  local render_dir
  local os_release
  local detected_os_family
  local setup_token_result

  case "$existing_mode" in
    cloud-vm|local-port-forward) ;;
    *) fail "existing_bastion_mode must be cloud-vm or local-port-forward" ;;
  esac
  [[ -n "$public_ipv4" ]] || fail "existing_bastion_public_ipv4 is required for existing-vm"
  validate_ipv4 "$public_ipv4" || fail "existing_bastion_public_ipv4 must be a valid IPv4 address"
  [[ -n "$ssh_host" ]] || fail "existing_bastion_ssh_host is required for existing-vm"
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || fail "existing_bastion_ssh_port must be numeric"
  [[ "$ssh_user" == "root" ]] || fail "existing-vm bootstrap supports root SSH only in this version"
  [[ -n "$ssh_private_key_input" ]] || fail "existing_bastion_ssh_private_key is required for existing-vm"
  [[ "$confirm_clean_host" == "true" ]] || fail "Set existing_bastion_confirm_clean_host=true to confirm Twinbox may manage /opt/netbird on this VM"
  if [[ "$existing_mode" == "local-port-forward" && "$confirm_port_forwarding" != "true" ]]; then
    fail "Set existing_bastion_confirm_port_forwarding=true after forwarding TCP 80/443 and UDP 3478 to the local VM"
  fi

  key_file="$(mktemp "${TMPDIR:-/tmp}/netbird-existing-bastion-key-XXXXXX")"
  register_temp_path "$key_file"
  printf '%s\n' "$ssh_private_key_input" >"$key_file"
  chmod 600 "$key_file"

  bastion_ssh_host="$ssh_host"
  bastion_ssh_port="$ssh_port"
  bastion_ssh_user="$ssh_user"
  bastion_ssh_key_path="$key_file"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Testing SSH reachability to existing bastion ${ssh_user}@${ssh_host}:${ssh_port}"
  [[ "$(bastion_ssh 'id -u' 2>/dev/null)" == "0" ]] || fail "Existing bastion SSH user must resolve to uid 0"

  os_release="$(bastion_ssh 'cat /etc/os-release')"
  detected_os_family="$(read_existing_bastion_os_family "$os_release")"
  [[ -n "$detected_os_family" ]] || fail "Existing bastion OS must be Debian or Ubuntu"
  case "$requested_os_family" in
    ""|debian|ubuntu) ;;
    *) fail "existing_bastion_os_family must be debian or ubuntu" ;;
  esac
  if [[ -n "$requested_os_family" && "$requested_os_family" != "$detected_os_family" ]]; then
    fail "existing_bastion_os_family=${requested_os_family} does not match detected ${detected_os_family}"
  fi

  install_existing_bastion_prerequisites

  render_dir="$(mktemp -d "${TMPDIR:-/tmp}/netbird-bastion-bootstrap-XXXXXX")"
  register_temp_path "$render_dir"
  python3 "$WORKSPACE_ROOT/scripts/manager/render-netbird-bastion-bootstrap.py" \
    --template "$WORKSPACE_ROOT/scripts/manager/netbird-bastion-bootstrap-template.sh" \
    --output-dir "$render_dir" \
    --netbird-fqdn "$netbird_fqdn" \
    --netbird-proxy-domain "$netbird_proxy_domain" \
    --public-zone-name "$public_zone_name" \
    --netbird-admin-email "$netbird_admin_email" \
    --netbird-version "${PINNED_NETBIRD_VERSION:-0.73.2}" \
    --dns-provider "$dns_provider" \
    --dns-api-token "$dns_api_token" \
    --dns-api-secret "$dns_api_secret" \
    --admin-token-expire-days "365" \
    --opkssh-issuer-url "$opkssh_issuer_url" \
    --opkssh-client-id "$opkssh_client_id"

  upload_existing_bastion_bootstrap "$render_dir"
  create_netbird_dns_records "$public_ipv4"
  wait_for_bastion_public_dns_records "$public_ipv4" "$netbird_fqdn"
  run_existing_bastion_bootstrap

  setup_token_result="$(bastion_ssh 'cat /opt/netbird/setup-result.json 2>/dev/null || echo "{}"' 2>/dev/null || echo "{}")"
  netbird_url="https://${netbird_fqdn}"
  server_ipv4="$public_ipv4"
  write_bastion_secret \
    "existing-vm" \
    "$existing_mode" \
    "$public_ipv4" \
    "$ssh_host" \
    "$ssh_port" \
    "$ssh_user" \
    "$detected_os_family" \
    "manual" \
    "manual-required" \
    "" \
    "$ssh_private_key_input"
  save_netbird_setup_token "$setup_token_result"
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

bastion_provider="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.bastion_provider // "hetzner"')"
hcloud_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_token // empty')"
hcloud_location="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_location // "fsn1"')"
hcloud_server_type="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.hcloud_server_type // "cax11"')"
netbird_admin_email="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_admin_email // empty')"
ssh_public_key="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ssh_public_key // ""')"
existing_bastion_mode="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_mode // "cloud-vm"')"
existing_bastion_public_ipv4="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_public_ipv4 // empty')"
existing_bastion_ssh_host="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_ssh_host // empty')"
existing_bastion_ssh_port="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_ssh_port // "22"')"
existing_bastion_ssh_user="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_ssh_user // "root"')"
existing_bastion_ssh_private_key="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_ssh_private_key // empty')"
existing_bastion_os_family="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_os_family // empty')"
existing_bastion_confirm_clean_host="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_confirm_clean_host // "false"')"
existing_bastion_confirm_port_forwarding="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.existing_bastion_confirm_port_forwarding // "false"')"

if [[ -z "$netbird_admin_email" ]]; then
  netbird_admin_email="$(read_first_admin_email "$cluster_scope_id" || true)"
fi

case "$bastion_provider" in
  hetzner|existing-vm) ;;
  *) fail "bastion_provider must be hetzner or existing-vm" ;;
esac
if [[ "$bastion_provider" == "hetzner" ]]; then
  [[ -n "$hcloud_token" ]] || fail "Hetzner API token is required"
fi
[[ -n "$netbird_admin_email" ]] || fail "First admin email is required. Please run Create Users and Groups before provisioning NetBird."
[[ -n "$cluster_dns_domain" ]] || fail "DNS domain not found. Please run Configure DNS Provider before provisioning NetBird."
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name from the configured DNS provider"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required to create NetBird DNS records through external-dns"
command -v ssh >/dev/null 2>&1 || fail "ssh is required to fetch the NetBird setup token. Refresh the manager-worker image so OpenSSH client tools are available."
if [[ "$bastion_provider" == "hetzner" ]]; then
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required to create the NetBird bootstrap key. Refresh the manager-worker image so OpenSSH client tools are available."
else
  command -v scp >/dev/null 2>&1 || fail "scp is required to upload the NetBird bootstrap files to an existing bastion VM."
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required to prepare NetBird bastion provisioning."

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

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
secret_file="$secrets_dir/netbird-bastion-${cluster_id}.json"

opkssh_issuer_url=""
opkssh_client_id=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  opkssh_secret_json="$(openbao_read_global_secret_json opkssh 2>/dev/null || true)"
  opkssh_issuer_url="$(jq -r '.OIDC_ISSUER_URL // empty' <<<"${opkssh_secret_json:-null}")"
  opkssh_client_id="$(jq -r '.OIDC_CLIENT_ID // empty' <<<"${opkssh_secret_json:-null}")"
fi

if [[ "$bastion_provider" == "existing-vm" ]]; then
  provision_existing_bastion \
    "$existing_bastion_mode" \
    "$existing_bastion_public_ipv4" \
    "$existing_bastion_ssh_host" \
    "$existing_bastion_ssh_port" \
    "$existing_bastion_ssh_user" \
    "$existing_bastion_ssh_private_key" \
    "$existing_bastion_os_family" \
    "$existing_bastion_confirm_clean_host" \
    "$existing_bastion_confirm_port_forwarding"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird bastion host provisioned successfully"
  echo "  Provider: existing-vm"
  echo "  Public IPv4: $server_ipv4"
  echo "  NetBird URL: $netbird_url"

  if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
    jq -n \
      --arg status "succeeded" \
      --arg provider "existing-vm" \
      --arg server_ipv4 "$server_ipv4" \
      --arg netbird_url "$netbird_url" \
      --arg netbird_fqdn "$netbird_fqdn" \
      --arg cluster_id "$cluster_id" \
      --arg secrets_path "$secret_file" \
      '{
        status: $status,
        provider: $provider,
        server_ipv4: $server_ipv4,
        netbird_url: $netbird_url,
        netbird_fqdn: $netbird_fqdn,
        cluster_id: $cluster_id,
        secrets_path: $secrets_path
      }' >"$STEP_RESULT_FILE"
  fi
  exit 0
fi

server_name="twinbox-${cluster_id}-netbird"
legacy_server_name="netbird-${cluster_id}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird Hetzner resource prefix: $server_name"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removing stale Hetzner resources from previous runs"
delete_hcloud_resources_by_name "servers" "$legacy_server_name" "$server_name"
delete_hcloud_resources_by_name "firewalls" "${legacy_server_name}-fw" "${server_name}-fw"
delete_hcloud_resources_by_name "ssh_keys" "${legacy_server_name}-ssh-key" "${server_name}-ssh-key"

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
    -var "netbird_version=${PINNED_NETBIRD_VERSION:-0.73.2}" \
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
cp "$WORKSPACE_ROOT/scripts/manager/netbird-bastion-bootstrap-template.sh" \
  "$tf_workdir/cloud-init/netbird-bastion-bootstrap-template.sh"

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
bastion_ssh_host="$server_ipv4"
bastion_ssh_port="22"
bastion_ssh_user="root"
if [[ -n "$ssh_private_key" ]]; then
  bastion_ssh_key_path="$ssh_key_dir/id_ed25519"
else
  bastion_ssh_key_path=""
fi

create_netbird_dns_records "$server_ipv4"
wait_for_bastion_public_dns_records "$server_ipv4" "$netbird_fqdn"
write_bastion_secret \
  "hetzner" \
  "cloud-vm" \
  "$server_ipv4" \
  "$server_ipv4" \
  "22" \
  "root" \
  "debian" \
  "hetzner" \
  "configured" \
  "$hcloud_token" \
  "$ssh_private_key"

# Wait for cloud-init to finish and poll for setup token via SSH
setup_token_result="{}"
if [[ -n "$ssh_private_key" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for SSH on $server_ipv4..."
  for i in $(seq 1 30); do
    if bastion_ssh 'echo SSH_OK' 2>/dev/null; then
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
    setup_token_result="$(bastion_ssh 'cat /opt/netbird/setup-result.json 2>/dev/null || echo "{}"' 2>/dev/null || echo "{}")"
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

save_netbird_setup_token "$setup_token_result"

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
