#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BOOTSTRAP_DIR="${REPO_ROOT}/bootstrap"

append_vaultwarden_env_block() {
  if grep -q '^VAULTWARDEN_IMAGE_TAG=' .env; then
    return 0
  fi

  cat >> .env <<'EOF'

TWINBOX_SECRET_BACKEND=vaultwarden
VAULTWARDEN_IMAGE_TAG=1.35.4
VAULTWARDEN_LOCAL_PORT=8222
VAULTWARDEN_DOMAIN=http://localhost:8222
VAULTWARDEN_SERVER_URL=http://vaultwarden:80
VAULTWARDEN_VAULT_EMAIL=twinbox@local
VAULTWARDEN_PASSWORD_FILE=/opt/twinbox/bootstrap/vaultwarden-password
VAULTWARDEN_CLIENTID_FILE=/opt/twinbox/bootstrap/vaultwarden-client-id
VAULTWARDEN_CLIENTSECRET_FILE=/opt/twinbox/bootstrap/vaultwarden-client-secret
VAULTWARDEN_READY_FILE=/opt/twinbox/bootstrap/vaultwarden-ready
VAULTWARDEN_SIGNUPS_ALLOWED=true
VAULTWARDEN_BOOTSTRAP_APPDATA_DIR=/opt/twinbox/bootstrap/bw-host
BITWARDENCLI_APPDATA_DIR=/opt/twinbox/bootstrap/bw-runtime
VAULTWARDEN_ITEM_PREFIX=twinbox
TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets
TWINBOX_SECRET_CACHE_TTL_SEC=60
EOF
}

ensure_bootstrap_material() {
  install -d -m 0700 "$BOOTSTRAP_DIR"

  if [[ ! -f "${BOOTSTRAP_DIR}/vaultwarden-password" ]]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 > "${BOOTSTRAP_DIR}/vaultwarden-password"
    chmod 0600 "${BOOTSTRAP_DIR}/vaultwarden-password"
  fi
}

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo ".env created from .env.example. Update values before continuing."
  exit 1
fi

append_vaultwarden_env_block
ensure_bootstrap_material

if [[ -x scripts/install-management-tools.sh ]]; then
  sudo ./scripts/install-management-tools.sh --env-file .env
else
  echo "Missing scripts/install-management-tools.sh"
  exit 1
fi

docker compose up -d vaultwarden

if [[ -x scripts/bootstrap-vaultwarden.sh ]]; then
  ./scripts/bootstrap-vaultwarden.sh --check-only
else
  echo "Missing scripts/bootstrap-vaultwarden.sh"
  exit 1
fi

docker compose pull
docker compose up -d

echo "Manager stack started"
echo "Web: http://localhost:3000"
echo "API: http://localhost:8080/api/health"
