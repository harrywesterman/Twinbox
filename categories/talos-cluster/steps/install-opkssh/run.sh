#!/usr/bin/env bash
# categories/talos-cluster/steps/install-opkssh/run.sh
set -euo pipefail

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT must be set}"
: "${STEP_SECRETS_DIR:?STEP_SECRETS_DIR must be set}"

# shellcheck source=scripts/manager/logging.sh
source "${WORKSPACE_ROOT}/scripts/manager/logging.sh"

# Read opkssh OIDC credentials from OpenBao if available.
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  opkssh_secret_json="$(openbao_read_global_secret_json opkssh 2>/dev/null || true)"
  OPKSSH_ISSUER_URL="${OPKSSH_ISSUER_URL:-$(jq -r '.OIDC_ISSUER_URL // empty' <<<"${opkssh_secret_json:-null}")}"
  OPKSSH_CLIENT_ID="${OPKSSH_CLIENT_ID:-$(jq -r '.OIDC_CLIENT_ID // empty' <<<"${opkssh_secret_json:-null}")}"
fi

[[ -n "${OPKSSH_ISSUER_URL:-}" ]] || fail "OPKSSH_ISSUER_URL is required (run install-browser-ssh first)"
[[ -n "${OPKSSH_CLIENT_ID:-}" ]] || fail "OPKSSH_CLIENT_ID is required (run install-browser-ssh first)"

cluster_id="${TWINBOX_CLUSTER_ID:?TWINBOX_CLUSTER_ID must be set}"
cluster_slug="${TWINBOX_CLUSTER_SLUG:?TWINBOX_CLUSTER_SLUG must be set}"

netbird_bastion_secret="${STEP_SECRETS_DIR}/NETBIRD_BASTION_SECRET"
bastion_ip="$(jq -r '.NETBIRD_IP // empty' "$netbird_bastion_secret")"
bastion_ssh_private_key="$(jq -r '.SSH_PRIVATE_KEY // empty' "$netbird_bastion_secret")"

mgmt_vm_ip="${MANAGEMENT_VM_IP:-$("${WORKSPACE_ROOT}/scripts/manager/management-ip.sh" resolve_management_vm_ip)}"
mgmt_vm_user="${MGMT_VM_USER:-twinbox}"

# Persist opkssh config on the Management VM so daily maintenance keeps it installed.
env_file="/opt/twinbox/.env"
if [[ -f "$env_file" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a
fi

update_env_file() {
  local key="$1"
  local value="$2"
  if [[ -f "$env_file" ]]; then
    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
      printf '%s=%s\n' "$key" "$value" >>"$env_file"
    fi
  fi
}

if [[ -f "$env_file" ]]; then
  update_env_file "OPKSSH_ISSUER_URL" "$OPKSSH_ISSUER_URL"
  update_env_file "OPKSSH_CLIENT_ID" "$OPKSSH_CLIENT_ID"
  update_env_file "OPKSSH_PRINCIPAL" "$mgmt_vm_user"
fi

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
