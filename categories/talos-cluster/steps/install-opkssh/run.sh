#!/usr/bin/env bash
# categories/talos-cluster/steps/install-opkssh/run.sh
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT must be set}"
: "${STEP_CONTEXT_JSON:?STEP_CONTEXT_JSON must be set}"

# shellcheck disable=SC1091
source "${WORKSPACE_ROOT}/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "${WORKSPACE_ROOT}/scripts/manager/management-ip.sh"

cluster_id="${TWINBOX_CLUSTER_ID:-$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.id // empty')}"
[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID"

# Read opkssh OIDC credentials from OpenBao if available.
opkssh_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  opkssh_secret_json="$(openbao_read_global_secret_json opkssh 2>/dev/null || true)"
fi

OPKSSH_ISSUER_URL="${OPKSSH_ISSUER_URL:-$(jq -r '.OIDC_ISSUER_URL // empty' <<<"${opkssh_secret_json:-null}")}"
OPKSSH_CLIENT_ID="${OPKSSH_CLIENT_ID:-$(jq -r '.OIDC_CLIENT_ID // empty' <<<"${opkssh_secret_json:-null}")}"

[[ -n "${OPKSSH_ISSUER_URL:-}" ]] || fail "OPKSSH_ISSUER_URL is required (run install-browser-ssh first)"
[[ -n "${OPKSSH_CLIENT_ID:-}" ]] || fail "OPKSSH_CLIENT_ID is required (run install-browser-ssh first)"

netbird_bastion_secret="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global/netbird-bastion-${cluster_id}.json"
[[ -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found at ${netbird_bastion_secret}"

bastion_ip="$(jq -r '.NETBIRD_IP // empty' "$netbird_bastion_secret")"
bastion_ssh_private_key="$(jq -r '.SSH_PRIVATE_KEY // empty' "$netbird_bastion_secret")"

mgmt_vm_ip="${MANAGEMENT_VM_IP:-$(resolve_management_vm_ip)}"
mgmt_vm_user="${MGMT_VM_USER:-twinbox}"

# Persist opkssh config on the Management VM host so daily maintenance keeps it installed.
# Inside the worker container the host filesystem is mounted under TWINBOX_HOST_RUNTIME_DIR.
host_runtime_dir="${TWINBOX_HOST_RUNTIME_DIR:-/opt/twinbox}"
env_file="${host_runtime_dir}/.env"

update_env_file() {
  local key="$1"
  local value="$2"

  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

  if [[ ! -w "$env_file" ]]; then
    log "WARNING: ${env_file} is not writable; skipping persistence of ${key}"
    return 0
  fi

  if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$env_file"
  fi
}

update_env_file "OPKSSH_ISSUER_URL" "$OPKSSH_ISSUER_URL"
update_env_file "OPKSSH_CLIENT_ID" "$OPKSSH_CLIENT_ID"
update_env_file "OPKSSH_PRINCIPAL" "$mgmt_vm_user"

log "Installing opkssh on Management VM (${mgmt_vm_ip})"
OPKSSH_ISSUER_URL="$OPKSSH_ISSUER_URL" \
OPKSSH_CLIENT_ID="$OPKSSH_CLIENT_ID" \
OPKSSH_PRINCIPAL="$mgmt_vm_user" \
bash "${WORKSPACE_ROOT}/scripts/manager/install-opkssh-on-host.sh" \
  --host "$mgmt_vm_ip" \
  --user "$mgmt_vm_user"

log "Installing opkssh on Bastion (${bastion_ip})"
if [[ -n "$bastion_ssh_private_key" ]]; then
  key_file="$(mktemp)"
  printf '%s\n' "$bastion_ssh_private_key" >"$key_file"
  chmod 600 "$key_file"
  OPKSSH_ISSUER_URL="$OPKSSH_ISSUER_URL" \
  OPKSSH_CLIENT_ID="$OPKSSH_CLIENT_ID" \
  OPKSSH_PRINCIPAL="root" \
  bash "${WORKSPACE_ROOT}/scripts/manager/install-opkssh-on-host.sh" \
    --host "$bastion_ip" \
    --user root \
    --ssh-key "$key_file"
  rm -f "$key_file"
else
  log "WARNING: no bastion SSH private key found; skipping bastion opkssh install"
fi

log "opkssh installation complete"
