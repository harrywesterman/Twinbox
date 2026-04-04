#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-${REPO_ROOT}/bootstrap}"
RAW_BASE_URL="${TWINBOX_RAW_BASE_URL:-https://raw.githubusercontent.com/harrywesterman/twinbox/main}"

append_secret_env_block() {
  local management_ip=""

  if grep -q '^TWINBOX_SECRET_BACKEND=filesystem$' .env; then
    return 0
  fi

  management_ip="${MANAGEMENT_VM_IP:-$(hostname -I | awk '{print $1}')}"

  cat >> .env <<EOF

TWINBOX_SECRET_BACKEND=filesystem
MANAGEMENT_VM_IP=${management_ip}
TWINBOX_SECRET_ITEM_PREFIX=twinbox
TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap
TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets
TWINBOX_SECRET_CACHE_TTL_SEC=60
EOF
}

remove_tool_version_envs() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  awk '!/^(KUBECTL_VERSION|HELM_VERSION)=/' .env >"$tmp_file"
  mv "$tmp_file" .env
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
    python3 - "$velero_file" "$seaweedfs_password" <<'PY'
import json
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
payload = {
    "mode": "seaweedfs",
    "endpoint": "http://192.168.1.50:8333",
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

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo ".env created from .env.example. Update values before continuing."
  exit 1
fi

if [[ ! -d "$BOOTSTRAP_DIR" ]]; then
  install -d -m 0755 "$BOOTSTRAP_DIR/secrets/global" "$BOOTSTRAP_DIR/ansible" "$BOOTSTRAP_DIR/config" "$BOOTSTRAP_DIR/bin"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/ansible/management-vm-maintenance.yml" ]]; then
  curl -fsSL "${RAW_BASE_URL}/ansible/management-vm-maintenance.yml" -o "${BOOTSTRAP_DIR}/ansible/management-vm-maintenance.yml"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/config/pinned-defaults.sh" ]]; then
  curl -fsSL "${RAW_BASE_URL}/config/pinned-defaults.sh" -o "${BOOTSTRAP_DIR}/config/pinned-defaults.sh"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" ]]; then
  curl -fsSL "${RAW_BASE_URL}/scripts/install-management-tools.sh" -o "${BOOTSTRAP_DIR}/bin/install-management-tools.sh"
  chmod 0755 "${BOOTSTRAP_DIR}/bin/install-management-tools.sh"
fi

if [[ -x "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" ]]; then
  sudo "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" --env-file .env
else
  echo "Missing install-management-tools.sh in bootstrap tree"
  exit 1
fi

append_secret_env_block
remove_tool_version_envs
set -a
# shellcheck disable=SC1091
source .env
set +a
ensure_bootstrap_material

if [[ ! -f docker-compose.yml ]]; then
  curl -fsSL "${RAW_BASE_URL}/docker-compose.yml" -o docker-compose.yml
fi

docker compose pull
docker compose up -d

echo "Manager stack started"
echo "Web: http://localhost:3000"
echo "API: http://localhost:8080/api/health"
