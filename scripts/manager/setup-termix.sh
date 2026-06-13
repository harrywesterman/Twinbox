#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/management-ip.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

TERMIX_URL="${TERMIX_URL:-http://termix.termix.svc.cluster.local:4090}"
TERMIX_ADMIN_USER="${TERMIX_ADMIN_USER:-admin}"
TERMIX_SECRET_NAME="${TERMIX_SECRET_NAME:-termix}"
TERMIX_BROWSER_ROLE_NAME="${TERMIX_BROWSER_ROLE_NAME:-browser-ssh}"
TERMIX_BROWSER_ROLE_DISPLAY_NAME="${TERMIX_BROWSER_ROLE_DISPLAY_NAME:-Browser SSH}"
TERMIX_BROWSER_ROLE_DESCRIPTION="${TERMIX_BROWSER_ROLE_DESCRIPTION:-Access to the Twinbox Management VM and bastion through Termix}"
MGMT_VM_USER="${MGMT_VM_USER:-twinbox}"
MANAGEMENT_VM_IP="${MANAGEMENT_VM_IP:-${MGMT_VM_IP:-}}"
LOGIN_SECRET_FILE="${TWINBOX_LOGIN_SECRET_FILE:-/opt/twinbox/bootstrap/secrets/global/twinbox-login.json}"
SECRETS_DIR="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global"

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v openssl >/dev/null 2>&1 || fail "openssl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v ssh >/dev/null 2>&1 || fail "ssh is required"

tmp_files=()
cleanup() {
  local path

  for path in "${tmp_files[@]}"; do
    [[ -n "$path" && -f "$path" ]] && rm -f "$path"
  done
}
trap cleanup EXIT

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_slug" ]] || fail "Could not determine cluster slug from context"

netbird_bastion_secret="${SECRETS_DIR}/netbird-bastion-${cluster_id}.json"
[[ -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found at ${netbird_bastion_secret}"

netbird_management_url="$(jq -r '.NETBIRD_URL // empty' "$netbird_bastion_secret")"
netbird_token="$(jq -r '.NETBIRD_SETUP_TOKEN // empty' "$netbird_bastion_secret")"
bastion_public_ip="$(jq -r '.NETBIRD_IP // empty' "$netbird_bastion_secret")"
bastion_ssh_private_key="$(jq -r '.SSH_PRIVATE_KEY // empty' "$netbird_bastion_secret")"

[[ -n "$netbird_management_url" ]] || fail "NETBIRD_URL is missing from ${netbird_bastion_secret}"
[[ -n "$netbird_token" ]] || fail "NETBIRD_SETUP_TOKEN is missing from ${netbird_bastion_secret}"
[[ -n "$bastion_public_ip" ]] || fail "NETBIRD_IP is missing from ${netbird_bastion_secret}"
[[ -n "$bastion_ssh_private_key" ]] || fail "SSH_PRIVATE_KEY is missing from ${netbird_bastion_secret}; cannot create the Termix bastion key credential"

termix_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  termix_secret_json="$(openbao_read_global_secret_json "$TERMIX_SECRET_NAME" 2>/dev/null || true)"
fi

termix_secret_get() {
  local key="$1"

  [[ -n "$termix_secret_json" ]] || return 0
  jq -r --arg key "$key" '.[$key] // empty' <<<"$termix_secret_json"
}

termix_admin_password="${TERMIX_ADMIN_PASSWORD:-${TERMIX_ADMIN_PASS:-$(termix_secret_get TERMIX_ADMIN_PASSWORD)}}"
[[ -n "$termix_admin_password" ]] || fail "TERMIX_ADMIN_PASSWORD is required or must be present in OpenBao secret '${TERMIX_SECRET_NAME}'"

read_management_vm_password() {
  if [[ -n "${MANAGEMENT_VM_PASSWORD:-}" ]]; then
    printf '%s\n' "$MANAGEMENT_VM_PASSWORD"
    return 0
  fi

  if [[ -f "$LOGIN_SECRET_FILE" ]]; then
    jq -r '.password // .PASSWORD // empty' "$LOGIN_SECRET_FILE"
    return 0
  fi

  return 1
}

MANAGEMENT_VM_PASSWORD="$(read_management_vm_password || true)"
[[ -n "$MANAGEMENT_VM_PASSWORD" ]] || fail "Could not read the Management VM password from ${LOGIN_SECRET_FILE}"

resolve_target_home() {
  local target_user="$1"
  local home_dir=""

  if [[ -d "/home/${target_user}" ]]; then
    printf '/home/%s\n' "$target_user"
    return 0
  fi

  home_dir="$(getent passwd "$target_user" | cut -d: -f6 || true)"
  if [[ -n "$home_dir" && -d "$home_dir" ]]; then
    printf '%s\n' "$home_dir"
    return 0
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    home_dir="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
    if [[ -n "$home_dir" && -d "$home_dir" ]]; then
      printf '%s\n' "$home_dir"
      return 0
    fi
  fi

  return 1
}

sync_local_config() {
  local source_file="$1"
  local target_file="$2"
  local target_dir
  local target_home
  local owner_uid
  local owner_gid

  [[ -f "$source_file" ]] || fail "Source file not found: $source_file"

  target_home="$(resolve_target_home "$MGMT_VM_USER")"
  [[ -n "$target_home" ]] || fail "Could not determine the target home directory for ${MGMT_VM_USER}"

  if [[ -d "$target_home" ]]; then
    owner_uid="$(stat -c '%u' "$target_home")"
    owner_gid="$(stat -c '%g' "$target_home")"
  else
    owner_uid="$(id -u "$MGMT_VM_USER" 2>/dev/null || printf '0')"
    owner_gid="$(id -g "$MGMT_VM_USER" 2>/dev/null || printf '0')"
  fi

  target_dir="$(dirname "$target_file")"
  install -d -m 700 -o "$owner_uid" -g "$owner_gid" "$target_dir"
  install -m 600 -o "$owner_uid" -g "$owner_gid" "$source_file" "$target_file"
  log "Copied $(basename "$source_file") to ${target_file}"
}

netbird_peer_ip_by_name() {
  local hostname="$1"

  python3 - "$netbird_management_url" "$netbird_token" "$hostname" <<'PY' 2>/dev/null || true
import json
import sys
import urllib.parse
import urllib.request

management_url, token, hostname = sys.argv[1], sys.argv[2], sys.argv[3]
base_url = management_url.rstrip("/")
if base_url.endswith("/api"):
    base_url = base_url[:-4]
url = f"{base_url}/api/peers?name={urllib.parse.quote(hostname)}"
req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
with urllib.request.urlopen(req, timeout=10) as resp:
    peers = json.loads(resp.read().decode())
if isinstance(peers, dict):
    peers = peers.get("peers") or peers.get("items") or []
for peer in peers:
    if peer.get("name") == hostname and peer.get("ip"):
        print(str(peer["ip"]).split("/", 1)[0])
        break
PY
}

discover_management_netbird_ip() {
  local mgmt_netbird_status=""
  local mgmt_netbird_ip=""

  if command -v netbird >/dev/null 2>&1; then
    mgmt_netbird_ip="$(netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 || true)"
    mgmt_netbird_status="$(netbird status 2>/dev/null || true)"
  fi
  if [[ -z "$mgmt_netbird_status" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    mgmt_netbird_ip="$(docker exec twinbox-netbird netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 || true)"
    mgmt_netbird_status="$(docker exec twinbox-netbird netbird status 2>/dev/null || true)"
  fi
  if [[ -z "$mgmt_netbird_ip" ]]; then
    mgmt_netbird_ip="$(printf '%s\n' "$mgmt_netbird_status" | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 2>/dev/null || true)"
  fi
  if [[ -z "$mgmt_netbird_ip" ]]; then
    mgmt_netbird_ip="$(netbird_peer_ip_by_name "twinbox-mgmt-${cluster_slug}")"
  fi

  printf '%s\n' "$mgmt_netbird_ip"
}

write_bastion_ssh_key() {
  local ssh_key_file

  ssh_key_file="$(mktemp "${TMPDIR:-/tmp}/termix-bastion-ssh-key-XXXXXX")"
  tmp_files+=("$ssh_key_file")
  printf '%s\n' "$bastion_ssh_private_key" >"$ssh_key_file"
  chmod 600 "$ssh_key_file"
  printf '%s\n' "$ssh_key_file"
}

discover_bastion_netbird_ip() {
  local bastion_netbird_ip
  local ssh_key_file

  bastion_netbird_ip="$(jq -r '.NETBIRD_PRIVATE_IP // empty' "$netbird_bastion_secret")"
  if [[ -n "$bastion_netbird_ip" ]]; then
    printf '%s\n' "$bastion_netbird_ip"
    return 0
  fi

  ssh_key_file="$(write_bastion_ssh_key)"
  bastion_netbird_ip="$(
    ssh -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -i "$ssh_key_file" \
      "root@${bastion_public_ip}" \
      'bash -s' <<'REMOTE' 2>/dev/null || true
set -euo pipefail
docker exec netbird-client netbird status --check ready >/dev/null
netbird_ip="$(docker exec netbird-client netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1)"
if [[ -z "$netbird_ip" ]]; then
  netbird_ip="$(docker exec netbird-client sh -lc "ip -o -4 addr show | awk '\$2 ~ /^(wt|nb|netbird)/ {split(\$4,a,\"/\"); print a[1]; exit}'" 2>/dev/null || true)"
fi
printf '%s\n' "$netbird_ip"
REMOTE
  )"

  if [[ -z "$bastion_netbird_ip" ]]; then
    bastion_netbird_ip="$(netbird_peer_ip_by_name "twinbox-${cluster_id}-proxy")"
  fi

  if [[ -n "$bastion_netbird_ip" ]]; then
    local tmp_file
    tmp_file="$(mktemp)"
    jq --arg netbird_private_ip "$bastion_netbird_ip" \
      '. + {NETBIRD_PRIVATE_IP: $netbird_private_ip}' \
      "$netbird_bastion_secret" >"$tmp_file"
    mv "$tmp_file" "$netbird_bastion_secret"
    chmod 600 "$netbird_bastion_secret"
  fi

  printf '%s\n' "$bastion_netbird_ip"
}

wait_for_termix() {
  local attempt=1
  local attempts=60

  log "Waiting for Termix to be ready"
  while [[ "$attempt" -le "$attempts" ]]; do
    if curl -fsS "${TERMIX_URL}/users/database-health-check" >/dev/null 2>&1; then
      log "Termix is ready"
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done

  fail "Termix did not become ready within ${attempts} attempts"
}

termix_public_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local response_file
  local status
  local body

  response_file="$(mktemp)"

  if [[ -n "$payload" ]]; then
    status="$(
      curl -sS \
        -X "$method" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data-binary "$payload" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${TERMIX_URL}${path}"
    )" || status="000"
  else
    status="$(
      curl -sS \
        -X "$method" \
        -H "Accept: application/json" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${TERMIX_URL}${path}"
    )" || status="000"
  fi

  body="$(cat "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"

  if [[ ! "$status" =~ ^2 ]]; then
    fail "Termix public API ${method} ${path} failed with HTTP ${status}: ${body:-<empty>}"
  fi

  printf '%s' "$body"
}

termix_api_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local response_file
  local status
  local body

  [[ -n "${TERMIX_TOKEN:-}" ]] || fail "TERMIX_TOKEN is not set"

  response_file="$(mktemp)"

  if [[ -n "$payload" ]]; then
    status="$(
      curl -sS \
        -X "$method" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${TERMIX_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "$payload" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${TERMIX_URL}${path}"
    )" || status="000"
  else
    status="$(
      curl -sS \
        -X "$method" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${TERMIX_TOKEN}" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${TERMIX_URL}${path}"
    )" || status="000"
  fi

  body="$(cat "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"

  if [[ ! "$status" =~ ^2 ]]; then
    fail "Termix API ${method} ${path} failed with HTTP ${status}: ${body:-<empty>}"
  fi

  printf '%s' "$body"
}

ensure_termix_credential() {
  local credential_name="$1"
  local auth_type="$2"
  local username="$3"
  local secret_value="$4"
  local description="$5"
  local credential_id
  local credential_payload
  local credential_response

  credential_id="$(
    jq -r \
      --arg credential_name "$credential_name" \
      '.[]?
        | select((.name // "") == $credential_name)
        | .id // empty' <<<"$credentials_payload" | head -n1
  )"

  if [[ "$auth_type" == "password" ]]; then
    credential_payload="$(
      jq -n \
        --arg name "$credential_name" \
        --arg username "$username" \
        --arg password "$secret_value" \
        --arg description "$description" \
        '{
          name: $name,
          description: $description,
          authType: "password",
          username: $username,
          password: $password
        }'
    )"
  elif [[ "$auth_type" == "key" ]]; then
    credential_payload="$(
      jq -n \
        --arg name "$credential_name" \
        --arg username "$username" \
        --arg key "$secret_value" \
        --arg description "$description" \
        '{
          name: $name,
          description: $description,
          authType: "key",
          username: $username,
          key: $key,
          keyType: "auto"
        }'
    )"
  else
    fail "Unsupported Termix credential auth type: $auth_type"
  fi

  if [[ -n "$credential_id" ]]; then
    termix_api_request PUT "/credentials/${credential_id}" "$credential_payload" >/dev/null
  else
    credential_response="$(termix_api_request POST "/credentials" "$credential_payload")"
    credential_id="$(jq -r '.id // ._id // empty' <<<"$credential_response")"
  fi

  [[ -n "$credential_id" ]] || fail "Could not determine the ${credential_name} credential ID"
  printf '%s\n' "$credential_id"
}

ensure_termix_host() {
  local host_name="$1"
  local host_ip="$2"
  local username="$3"
  local credential_id="$4"
  local host_id
  local host_payload
  local host_response

  host_id="$(
    jq -r \
      --arg host_name "$host_name" \
      --arg host_ip "$host_ip" \
      '.[]?
        | select((.name // "") == $host_name or (.ip // "") == $host_ip)
        | .id // empty' <<<"$hosts_payload" | head -n1
  )"

  host_payload="$(
    jq -n \
      --arg name "$host_name" \
      --arg ip "$host_ip" \
      --arg username "$username" \
      --arg credential_id "$credential_id" \
      '{
        connectionType: "ssh",
        name: $name,
        ip: $ip,
        port: 22,
        username: $username,
        authType: "credential",
        credentialId: ($credential_id | tonumber? // $credential_id),
        enableTerminal: true,
        showTerminalInSidebar: true,
        enableSsh: true
      }'
  )"

  if [[ -n "$host_id" ]]; then
    termix_api_request PUT "/ssh/db/host/${host_id}" "$host_payload" >/dev/null
  else
    host_response="$(termix_api_request POST "/ssh/db/host" "$host_payload")"
    host_id="$(jq -r '.id // ._id // empty' <<<"$host_response")"
  fi

  [[ -n "$host_id" ]] || fail "Could not determine the ${host_name} host ID"
  printf '%s\n' "$host_id"
}

share_termix_host_with_browser_role() {
  local host_id="$1"
  local share_payload

  share_payload="$(
    jq -n \
      --arg role_id "$browser_role_id" \
      '{
        targetType: "role",
        targetRoleId: ($role_id | tonumber? // $role_id),
        permissionLevel: "view"
      }'
  )"
  termix_api_request POST "/rbac/host/${host_id}/share" "$share_payload" >/dev/null
}

wait_for_termix

setup_required_payload="$(termix_public_request GET "/users/setup-required")"
if jq -e '.setup_required == true' <<<"$setup_required_payload" >/dev/null 2>&1; then
  log "Creating the initial Termix admin user"
  create_user_payload="$(
    jq -n \
      --arg username "$TERMIX_ADMIN_USER" \
      --arg password "$termix_admin_password" \
      '{username: $username, password: $password}'
  )"
  termix_public_request POST "/users/create" "$create_user_payload" >/dev/null
fi

log "Signing in to Termix"
login_payload="$(
  jq -n \
    --arg username "$TERMIX_ADMIN_USER" \
    --arg password "$termix_admin_password" \
    '{username: $username, password: $password}'
)"
login_result="$(termix_public_request POST "/users/login" "$login_payload")"
TERMIX_TOKEN="$(jq -r '.token // empty' <<<"$login_result")"
[[ -n "$TERMIX_TOKEN" ]] || fail "Could not extract a Termix login token"

mgmt_vm_ip="$(resolve_management_vm_ip)"
[[ -n "$mgmt_vm_ip" ]] || fail "Could not resolve the Management VM IP"

log "Discovering Management VM NetBird IP"
mgmt_netbird_ip="$(discover_management_netbird_ip)"
[[ -n "$mgmt_netbird_ip" ]] || fail "Could not determine the Management VM NetBird IP; run configure-netbird-admin-access first"
log "Management VM NetBird IP: ${mgmt_netbird_ip}"

log "Discovering bastion NetBird IP"
bastion_netbird_ip="$(discover_bastion_netbird_ip)"
[[ -n "$bastion_netbird_ip" ]] || fail "Could not determine the bastion NetBird IP; run configure-netbird-ingress first"
log "Bastion NetBird IP: ${bastion_netbird_ip}"

mgmt_kubeconfig_target_home="$(resolve_target_home "$MGMT_VM_USER")"
[[ -n "$mgmt_kubeconfig_target_home" ]] || fail "Could not determine the target home directory for ${MGMT_VM_USER}"

sync_local_config "$KUBECONFIG_FILE" "$mgmt_kubeconfig_target_home/.kube/config"
sync_local_config "${TWINBOX_TALOSCONFIG_FILE:?missing TWINBOX_TALOSCONFIG_FILE}" "$mgmt_kubeconfig_target_home/.talos/config"

log "Ensuring Termix credentials exist"
credentials_payload="$(termix_api_request GET "/credentials")"
mgmt_credential_id="$(
  ensure_termix_credential \
    "Management VM Password" \
    "password" \
    "$MGMT_VM_USER" \
    "$MANAGEMENT_VM_PASSWORD" \
    "Password credential for the Twinbox Management VM"
)"
bastion_credential_id="$(
  ensure_termix_credential \
    "Bastion VM SSH Key" \
    "key" \
    "root" \
    "$bastion_ssh_private_key" \
    "SSH key credential for the Twinbox NetBird bastion"
)"

log "Ensuring Termix SSH hosts exist"
hosts_payload="$(termix_api_request GET "/ssh/db/host")"
mgmt_host_id="$(ensure_termix_host "Management VM" "$mgmt_netbird_ip" "$MGMT_VM_USER" "$mgmt_credential_id")"
bastion_host_id="$(ensure_termix_host "Bastion VM" "$bastion_netbird_ip" "root" "$bastion_credential_id")"

log "Ensuring the Browser SSH role exists"
roles_payload="$(termix_api_request GET "/rbac/roles")"
browser_role_id="$(
  jq -r \
    --arg role_name "$TERMIX_BROWSER_ROLE_NAME" \
    '.roles[]?
      | select((.name // "") == $role_name)
      | .id // empty' <<<"$roles_payload" | head -n1
)"

browser_role_payload="$(
  jq -n \
    --arg name "$TERMIX_BROWSER_ROLE_NAME" \
    --arg display_name "$TERMIX_BROWSER_ROLE_DISPLAY_NAME" \
    --arg description "$TERMIX_BROWSER_ROLE_DESCRIPTION" \
    '{
      name: $name,
      displayName: $display_name,
      description: $description
    }'
)"

if [[ -n "$browser_role_id" ]]; then
  termix_api_request PUT "/rbac/roles/${browser_role_id}" "$browser_role_payload" >/dev/null || true
else
  browser_role_response="$(termix_api_request POST "/rbac/roles" "$browser_role_payload")"
  browser_role_id="$(jq -r '.roleId // .id // empty' <<<"$browser_role_response")"
fi
[[ -n "$browser_role_id" ]] || fail "Could not determine the Browser SSH role ID"

log "Assigning the Browser SSH role to admin users"
users_payload="$(termix_api_request GET "/users/list")"
admin_user_ids="$(
  jq -r '
    .users[]?
    | select(.isAdmin == true)
    | .id // empty
  ' <<<"$users_payload"
)"

while IFS= read -r user_id; do
  [[ -n "$user_id" ]] || continue
  user_roles_payload="$(termix_api_request GET "/rbac/users/${user_id}/roles")"
  if jq -e --arg role_name "$TERMIX_BROWSER_ROLE_NAME" '
    any(.roles[]?; (.roleName // .name // "") == $role_name or (.roleDisplayName // "") == "Browser SSH")
  ' <<<"$user_roles_payload" >/dev/null 2>&1; then
    continue
  fi

  assign_role_payload="$(
    jq -n --arg role_id "$browser_role_id" '{roleId: ($role_id | tonumber? // $role_id)}'
  )"
  termix_api_request POST "/rbac/users/${user_id}/roles" "$assign_role_payload" >/dev/null
done <<<"$admin_user_ids"

log "Sharing Browser SSH hosts with the Browser SSH role"
share_termix_host_with_browser_role "$mgmt_host_id"
share_termix_host_with_browser_role "$bastion_host_id"

log ""
log "===== Termix Browser SSH Setup Complete ====="
log "Termix URL: ${TERMIX_URL}"
log "Management VM LAN IP: ${mgmt_vm_ip}"
log "Management VM NetBird IP: ${mgmt_netbird_ip}"
log "Bastion NetBird IP: ${bastion_netbird_ip}"
log "Management VM host: Management VM"
log "Bastion host: Bastion VM"
log "Browser SSH role: ${TERMIX_BROWSER_ROLE_NAME}"
log "Current admin users now inherit the role through Termix RBAC"
log ""
log "Next steps:"
log "  1. Visit Termix at https://termix.<your-zone>"
log "  2. Open the Management VM or Bastion VM host"
log "  3. Use kubectl, talosctl, helm, and bastion tools from the browser shell"
