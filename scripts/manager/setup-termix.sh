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
TERMIX_BROWSER_ROLE_DESCRIPTION="${TERMIX_BROWSER_ROLE_DESCRIPTION:-Access to the Twinbox Management VM through Termix}"
MGMT_VM_USER="${MGMT_VM_USER:-twinbox}"
MANAGEMENT_VM_IP="${MANAGEMENT_VM_IP:-${MGMT_VM_IP:-}}"
LOGIN_SECRET_FILE="${TWINBOX_LOGIN_SECRET_FILE:-/opt/twinbox/bootstrap/secrets/global/twinbox-login.json}"

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v openssl >/dev/null 2>&1 || fail "openssl is required"

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

mgmt_kubeconfig_target_home="$(resolve_target_home "$MGMT_VM_USER")"
[[ -n "$mgmt_kubeconfig_target_home" ]] || fail "Could not determine the target home directory for ${MGMT_VM_USER}"

sync_local_config "$KUBECONFIG_FILE" "$mgmt_kubeconfig_target_home/.kube/config"
sync_local_config "${TWINBOX_TALOSCONFIG_FILE:?missing TWINBOX_TALOSCONFIG_FILE}" "$mgmt_kubeconfig_target_home/.talos/config"

credential_name="Management VM Password"
host_name="Management VM"

log "Ensuring the Management VM password credential exists"
credentials_payload="$(termix_api_request GET "/credentials")"
credential_id="$(
  jq -r \
    --arg credential_name "$credential_name" \
    '.[]?
      | select((.name // "") == $credential_name)
      | .id // empty' <<<"$credentials_payload" | head -n1
)"

credential_payload="$(
  jq -n \
    --arg name "$credential_name" \
    --arg username "$MGMT_VM_USER" \
    --arg password "$MANAGEMENT_VM_PASSWORD" \
    --arg description "Password credential for the Twinbox Management VM" \
    '{
      name: $name,
      description: $description,
      authType: "password",
      username: $username,
      password: $password
    }'
)"

if [[ -n "$credential_id" ]]; then
  termix_api_request PUT "/credentials/${credential_id}" "$credential_payload" >/dev/null
else
  credential_response="$(termix_api_request POST "/credentials" "$credential_payload")"
  credential_id="$(jq -r '.id // ._id // empty' <<<"$credential_response")"
fi
[[ -n "$credential_id" ]] || fail "Could not determine the Management VM credential ID"

log "Ensuring the Management VM host exists"
hosts_payload="$(termix_api_request GET "/ssh/db/host")"
host_id="$(
  jq -r \
    --arg host_name "$host_name" \
    --arg mgmt_vm_ip "$mgmt_vm_ip" \
    '.[]?
      | select((.name // "") == $host_name or (.ip // "") == $mgmt_vm_ip)
      | .id // empty' <<<"$hosts_payload" | head -n1
)"

host_payload="$(
  jq -n \
    --arg name "$host_name" \
    --arg ip "$mgmt_vm_ip" \
    --arg username "$MGMT_VM_USER" \
    --argjson credential_id "$credential_id" \
    '{
      connectionType: "ssh",
      name: $name,
      ip: $ip,
      port: 22,
      username: $username,
      authType: "credential",
      credentialId: $credential_id,
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
[[ -n "$host_id" ]] || fail "Could not determine the Management VM host ID"

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
    jq -n --argjson role_id "$browser_role_id" '{roleId: $role_id}'
  )"
  termix_api_request POST "/rbac/users/${user_id}/roles" "$assign_role_payload" >/dev/null
done <<<"$admin_user_ids"

log "Sharing the Management VM host with the Browser SSH role"
share_payload="$(
  jq -n \
    --argjson role_id "$browser_role_id" \
    '{
      targetType: "role",
      targetRoleId: $role_id,
      permissionLevel: "view"
    }'
)"
termix_api_request POST "/rbac/host/${host_id}/share" "$share_payload" >/dev/null

log ""
log "===== Termix Browser SSH Setup Complete ====="
log "Termix URL: ${TERMIX_URL}"
log "Management VM IP: ${mgmt_vm_ip}"
log "Management VM host: ${host_name}"
log "Browser SSH role: ${TERMIX_BROWSER_ROLE_NAME}"
log "Current admin users now inherit the role through Termix RBAC"
log ""
log "Next steps:"
log "  1. Visit Termix at https://termix.<your-zone>"
log "  2. Open the Management VM host"
log "  3. Use kubectl, talosctl, helm, and other host tools from the browser shell"
