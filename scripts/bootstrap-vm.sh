#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGET_DIR="${TWINBOX_TARGET_DIR:-/opt/twinbox}"
BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-${TARGET_DIR}/bootstrap}"
RAW_BASE_URL="${TWINBOX_RAW_BASE_URL:-https://raw.githubusercontent.com/harrywesterman/twinbox/main}"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/manager/management-ip.sh"

append_secret_env_block() {
  local management_ip=""

  if grep -q '^TWINBOX_SECRET_BACKEND=filesystem$' .env; then
    return 0
  fi

  if ! management_ip="$(resolve_management_vm_ip)"; then
    fail "Could not determine management VM IP"
  fi

  cat >> .env <<EOF

TWINBOX_SECRET_BACKEND=filesystem
MANAGEMENT_VM_IP=${management_ip}
TWINBOX_SECRET_ITEM_PREFIX=twinbox
TWINBOX_TIME_SERVER=time.cloudflare.com
TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap
TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets
TWINBOX_SECRET_CACHE_TTL_SEC=60
EOF
}

ensure_time_server_env() {
  if ! grep -q '^TWINBOX_TIME_SERVER=' .env; then
    printf '\nTWINBOX_TIME_SERVER=%s\n' "${TWINBOX_TIME_SERVER:-time.cloudflare.com}" >> .env
  fi
}

configure_management_time_sync() {
  local time_server="${TWINBOX_TIME_SERVER:-time.cloudflare.com}"
  local timesyncd_dropin="/etc/systemd/timesyncd.conf.d/99-twinbox.conf"

  log "Configuring management VM time synchronization"
  sudo install -d -m 0755 "$(dirname "$timesyncd_dropin")"
  sudo tee "$timesyncd_dropin" >/dev/null <<EOF
[Time]
NTP=${time_server}
FallbackNTP=
EOF
  sudo systemctl enable --now systemd-timesyncd.service
  sudo systemctl restart systemd-timesyncd.service
}

ensure_bootstrap_material() {
  local secret_dir="${BOOTSTRAP_DIR}/secrets/global"
  local openbao_seal_dir="${BOOTSTRAP_DIR}/openbao/seal"
  local openbao_init_dir="${BOOTSTRAP_DIR}/openbao/init"
  local proxmox_file="${secret_dir}/proxmox.json"
  local traefik_file="${secret_dir}/traefik-dashboard.json"
  local velero_file="${secret_dir}/velero.json"
  local seal_key_file="${openbao_seal_dir}/current.key"
  local seal_key_id_file="${openbao_seal_dir}/current-key-id"
  local management_ip=""

  install -d -m 0700 "$secret_dir" "$openbao_seal_dir" "$openbao_init_dir"

  if [[ ! -f "$proxmox_file" ]]; then
    python3 - "$proxmox_file" <<'PY'
import json
import os
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
payload = {
    "username": os.environ["PROXMOX_USER"],
    "password": os.environ["PROXMOX_PASSWORD"],
    "host": os.environ["PROXMOX_HOST"],
    "port": os.environ.get("PROXMOX_PORT", "8006"),
}
payload["endpoint"] = f"https://{payload['host']}:{payload['port']}"
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
target.chmod(0o600)
PY
  fi

  if [[ ! -f "$traefik_file" ]]; then
    local traefik_password=""
    local traefik_users=""
    traefik_password="$(openssl rand -hex 16)"
    traefik_users="$(printf 'admin:%s' "$(openssl passwd -apr1 "$traefik_password")")"
    python3 - "$traefik_file" "$traefik_password" "$traefik_users" <<'PY'
import json
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
payload = {
    "username": "admin",
    "password": sys.argv[2],
    "users": sys.argv[3],
}
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
target.chmod(0o600)
PY
  fi

  if [[ ! -f "$velero_file" ]]; then
    local seaweedfs_password=""
    seaweedfs_password="$(openssl rand -hex 16)"
    if ! management_ip="$(resolve_management_vm_ip)"; then
      fail "Could not determine management VM IP"
    fi
    export MANAGEMENT_VM_IP="$management_ip"
    python3 - "$velero_file" "$seaweedfs_password" <<'PY'
import json
import os
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
management_ip = os.environ["MANAGEMENT_VM_IP"]
payload = {
    "mode": "seaweedfs",
    "endpoint": f"http://{management_ip}:8333",
    "bucket": "twinbox-velero",
    "region": "seaweedfs",
    "username": "velero",
    "password": sys.argv[2],
}
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
target.chmod(0o600)
PY
  fi

  if [[ ! -f "$seal_key_file" ]]; then
    openssl rand -hex 32 > "$seal_key_file"
    chmod 0600 "$seal_key_file"
  fi

  if [[ ! -f "$seal_key_id_file" ]]; then
    openssl rand -hex 16 > "$seal_key_id_file"
    chmod 0600 "$seal_key_id_file"
  fi
}

ensure_seaweedfs_data_dir() {
  install -d -m 0755 "$TARGET_DIR/seaweedfs/data"
  sudo chown -R "$USER":"$USER" "$TARGET_DIR/seaweedfs/data"
}

log() {
  printf '[bootstrap-vm] %s\n' "$1"
}

fail() {
  printf '[bootstrap-vm] ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

log "Validating required tools"
require_cmd docker

if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose plugin is missing (docker compose ...)"
fi

if [[ ! -d "$TARGET_DIR/manager-data" ]]; then
  sudo install -d -m 0755 "$TARGET_DIR/manager-data"
fi

if [[ ! -d "$BOOTSTRAP_DIR" ]]; then
  sudo install -d -m 0755 "$BOOTSTRAP_DIR/secrets/global" "$BOOTSTRAP_DIR/ansible" "$BOOTSTRAP_DIR/config" "$BOOTSTRAP_DIR/bin"
fi

if [[ ! -d "$TARGET_DIR/gitops" ]]; then
  sudo install -d -m 0755 "$TARGET_DIR/gitops"
fi

if [[ ! -w "$TARGET_DIR" ]]; then
  log "Taking ownership of $TARGET_DIR for current user"
  sudo chown -R "$USER":"$USER" "$TARGET_DIR"
fi

ensure_seaweedfs_data_dir

cd "$TARGET_DIR"

if [[ ! -f .env ]]; then
  if [[ -f /opt/twinbox/.env ]]; then
    log "Copying existing /opt/twinbox/.env"
    cp /opt/twinbox/.env .env
  elif [[ -f .env.example ]]; then
    log "Creating .env from .env.example"
    cp .env.example .env
  else
    fail "No .env or .env.example found in $TARGET_DIR"
  fi
fi

if ! grep -q "^TWINBOX_HOST_REPO_ROOT=" .env; then
  log "Recording host repository root in .env"
  printf '\nTWINBOX_HOST_REPO_ROOT=%s\n' "$TARGET_DIR" >> .env
fi

if [[ ! -f "${BOOTSTRAP_DIR}/ansible/management-vm-maintenance.yml" ]]; then
  log "Fetching maintenance playbook into bootstrap tree"
  sudo install -d -m 0755 "${BOOTSTRAP_DIR}/ansible"
  curl -fsSL "${RAW_BASE_URL}/ansible/management-vm-maintenance.yml" -o "${BOOTSTRAP_DIR}/ansible/management-vm-maintenance.yml"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/config/pinned-defaults.sh" ]]; then
  log "Fetching pinned defaults into bootstrap tree"
  sudo install -d -m 0755 "${BOOTSTRAP_DIR}/config"
  curl -fsSL "${RAW_BASE_URL}/config/pinned-defaults.sh" -o "${BOOTSTRAP_DIR}/config/pinned-defaults.sh"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" ]]; then
  log "Fetching management tools installer into bootstrap tree"
  sudo install -d -m 0755 "${BOOTSTRAP_DIR}/bin"
  curl -fsSL "${RAW_BASE_URL}/scripts/install-management-tools.sh" -o "${BOOTSTRAP_DIR}/bin/install-management-tools.sh"
  chmod 0755 "${BOOTSTRAP_DIR}/bin/install-management-tools.sh"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh" ]]; then
  log "Fetching Forgejo bootstrap helper into bootstrap tree"
  sudo install -d -m 0755 "${BOOTSTRAP_DIR}/bin"
  curl -fsSL "${RAW_BASE_URL}/scripts/manager/bootstrap-forgejo.sh" -o "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh"
  chmod 0755 "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/bin/forgejo-promote-upstream.sh" ]]; then
  log "Fetching Forgejo promotion helper into bootstrap tree"
  sudo install -d -m 0755 "${BOOTSTRAP_DIR}/bin"
  curl -fsSL "${RAW_BASE_URL}/scripts/manager/forgejo-promote-upstream.sh" -o "${BOOTSTRAP_DIR}/bin/forgejo-promote-upstream.sh"
  chmod 0755 "${BOOTSTRAP_DIR}/bin/forgejo-promote-upstream.sh"
fi

if [[ -x "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" ]]; then
  log "Installing management host tools from .env versions"
  sudo "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" --env-file .env
else
  fail "Missing install-management-tools.sh in bootstrap tree"
fi

append_secret_env_block
ensure_time_server_env
set -a
# shellcheck disable=SC1091
source .env
set +a
ensure_bootstrap_material
configure_management_time_sync

log "Starting manager stack once"
./scripts/start-manager.sh --bootstrap-once

log "Done"
printf '\nNext steps:\n'
printf '1. Create a feature branch: git checkout -b codex/<feature>\n'
printf '2. Open local browser via SSH tunnel: http://localhost:3000\n'
printf '3. Follow logs when needed: docker compose logs -f manager-web manager-api\n'
