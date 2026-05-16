#!/usr/bin/env bash
set -euo pipefail

TERMIX_URL="${TERMIX_URL:-http://termix.termix.svc.cluster.local:4090}"
TERMIX_ADMIN_USER="${TERMIX_ADMIN_USER:-admin}"
TERMIX_ADMIN_PASS="${TERMIX_ADMIN_PASS:-}"
TERMIX_API_KEY="${TERMIX_API_KEY:-}"
MGMT_VM_IP="${MGMT_VM_IP:-}"
MGMT_VM_USER="${MGMT_VM_USER:-twinbox}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

[[ -n "$TERMIX_ADMIN_PASS" ]] || fail "TERMIX_ADMIN_PASS is required"
[[ -n "$TERMIX_API_KEY" ]] || fail "TERMIX_API_KEY is required (create one in Admin Settings > API Keys)"
[[ -n "$MGMT_VM_IP" ]] || fail "MGMT_VM_IP is required (Management VM IP)"
[[ -n "$SSH_PRIVATE_KEY_PATH" ]] && [[ -f "$SSH_PRIVATE_KEY_PATH" ]] || fail "SSH_PRIVATE_KEY_PATH not found: ${SSH_PRIVATE_KEY_PATH:-}"

tmx_api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local auth_header="Authorization: Bearer ${TERMIX_API_KEY}"

  if [[ -n "$payload" ]]; then
    curl -sfS \
      -X "$method" \
      -H "$auth_header" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      --data "$payload" \
      "${TERMIX_URL}${path}" 2>/dev/null
  else
    curl -sfS \
      -X "$method" \
      -H "$auth_header" \
      -H "Accept: application/json" \
      "${TERMIX_URL}${path}" 2>/dev/null
  fi
}

log "Waiting for Termix to be ready"
for i in $(seq 1 60); do
  if curl -sfS "${TERMIX_URL}/users/database-health-check" >/dev/null 2>&1; then
    log "Termix is ready"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    fail "Termix did not become ready within 60 attempts"
  fi
  sleep 5
done

log "Checking if initial setup is required"
setup_required="$(curl -sfS "${TERMIX_URL}/users/setup-required" 2>/dev/null || echo '{"setupRequired":true}')"
if jq -e '.setupRequired == true' <<<"$setup_required" >/dev/null 2>&1; then
  log "Creating admin user"
  create_user_payload="$(
    jq -n \
      --arg username "$TERMIX_ADMIN_USER" \
      --arg password "$TERMIX_ADMIN_PASS" \
      '{username: $username, password: $password}'
  )"
  curl -sfS -X POST \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "$create_user_payload" \
    "${TERMIX_URL}/users/create" >/dev/null || fail "Failed to create admin user"

  login_payload="$(
    jq -n \
      --arg username "$TERMIX_ADMIN_USER" \
      --arg password "$TERMIX_ADMIN_PASS" \
      '{username: $username, password: $password}'
  )"
  login_result="$(curl -sfS -X POST \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "$login_payload" \
    "${TERMIX_URL}/users/login")" || fail "Failed to login"

  token="$(jq -r '.token // empty' <<<"$login_result")"
  if [[ -z "$token" ]]; then
    log "WARNING: Could not extract JWT token from login response. You may need to manually configure OIDC in Admin Settings."
    log "Login response: $(jq -c . <<<"$login_result")"
  else
    log "Admin user created and logged in successfully"
    log "To configure OIDC, run the configure-oidc endpoint manually or visit the Admin Settings UI"
  fi
else
  log "Setup already complete, skipping admin user creation"
fi

log "Reading SSH private key"
ssh_private_key="$(cat "$SSH_PRIVATE_KEY_PATH")"

log "Creating SSH credential for Management VM"
credential_payload="$(
  jq -n \
    --arg name "Twinbox Management VM" \
    --arg username "$MGMT_VM_USER" \
    --arg privateKey "$ssh_private_key" \
    '{
      name: $name,
      username: $username,
      authType: "key",
      privateKey: $privateKey
    }'
)"
credential_result="$(tmx_api POST "/credentials" "$credential_payload")" || {
  log "WARNING: Failed to create credential via API. You can create it manually in the Termix UI."
  log "Credential payload was: $(jq -c '{name, username, authType}' <<<"$credential_payload")"
  credential_id=""
}
credential_id="$(jq -r '.id // ._id // empty' <<<"${credential_result:-}")"

if [[ -n "${credential_id:-}" ]]; then
  log "Credential created with id=${credential_id}"
else
  log "Credential creation returned: ${credential_result:-unsuccessful}"
  credential_id=""
fi

log "Creating SSH host for Management VM"
host_payload="$(
  jq -n \
    --arg name "Management VM" \
    --arg hostname "$MGMT_VM_IP" \
    --arg username "$MGMT_VM_USER" \
    '{
      name: $name,
      hostname: $hostname,
      port: 22,
      username: $username
    }'
)"
host_result="$(tmx_api POST "/ssh/db/host" "$host_payload")" || {
  log "WARNING: Failed to create SSH host via API. You can create it manually in the Termix UI."
  log "Host payload was: $(jq -c '{name, hostname, port, username}' <<<"$host_payload")"
  host_id=""
}
host_id="$(jq -r '.id // ._id // empty' <<<"${host_result:-}")"

if [[ -n "${host_id:-}" && -n "${credential_id:-}" ]]; then
  log "Applying credential ${credential_id} to host ${host_id}"
  apply_payload="$(
    jq -n \
      --arg credentialId "$credential_id" \
      '{
        credentialId: $credential_id
      }'
  )"
  tmx_api POST "/credentials/apply" "$apply_payload" >/dev/null || {
    log "WARNING: Failed to apply credential to host. You can do this manually in the Termix UI."
  }
  log "Credential applied to host"
fi

log ""
log "===== Setup Summary ====="
log "Termix URL: ${TERMIX_URL}"
if [[ -n "${host_id:-}" ]]; then
  log "Management VM SSH host: created (${host_id:-})"
else
  log "Management VM SSH host: not yet configured — create manually in Termix UI"
fi
if [[ -n "${credential_id:-}" ]]; then
  log "SSH credential: created (${credential_id:-})"
else
  log "SSH credential: not yet configured — create manually in Termix UI"
fi
log ""
log "Next steps:"
log "  1. Visit Termix at https://termix.<your-zone>"
log "  2. Log in with user '${TERMIX_ADMIN_USER}'"
log "  3. Go to Admin Settings > OIDC to configure Authentik SSO"
log "  4. Add additional SSH hosts as needed"
log ""
