#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${TWINBOX_REPO_URL:-https://github.com/harrywesterman/twinbox.git}"
TARGET_DIR="${TWINBOX_TARGET_DIR:-/opt/twinbox}"
BRANCH="${TWINBOX_BRANCH:-main}"
BOOTSTRAP_DIR="${TARGET_DIR}/bootstrap"

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
    command -v openssl >/dev/null 2>&1 || fail "Missing required command: openssl"
    openssl rand -hex 24 > "${BOOTSTRAP_DIR}/vaultwarden-password"
    chmod 0600 "${BOOTSTRAP_DIR}/vaultwarden-password"
  fi
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
require_cmd git
require_cmd docker

if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose plugin is missing (docker compose ...)"
fi

if [[ ! -d "$TARGET_DIR/.git" ]]; then
  log "Cloning repository into $TARGET_DIR"
  sudo install -d -m 0755 "$(dirname "$TARGET_DIR")"
  sudo git clone "$REPO_URL" "$TARGET_DIR"
fi

if [[ ! -w "$TARGET_DIR" ]]; then
  log "Taking ownership of $TARGET_DIR for current user"
  sudo chown -R "$USER":"$USER" "$TARGET_DIR"
fi

cd "$TARGET_DIR"

log "Fetching latest changes"
git fetch --all --prune
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

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

append_vaultwarden_env_block
ensure_bootstrap_material

if [[ -x scripts/install-management-tools.sh ]]; then
  log "Installing management host tools from .env versions"
  sudo ./scripts/install-management-tools.sh --env-file .env
else
  fail "Missing scripts/install-management-tools.sh"
fi

log "Starting Vaultwarden"
docker compose up -d vaultwarden

if [[ -x scripts/bootstrap-vaultwarden.sh ]]; then
  log "Checking Vaultwarden bootstrap readiness"
  ./scripts/bootstrap-vaultwarden.sh --check-only
else
  fail "Missing scripts/bootstrap-vaultwarden.sh"
fi

log "Starting development stack"
docker compose up -d --build

log "Done"
printf '\nNext steps:\n'
printf '1. Create a feature branch: git checkout -b codex/<feature>\n'
printf '2. Open local browser via SSH tunnel: http://localhost:3000\n'
printf '3. Follow logs when needed: docker compose logs -f manager-web manager-api\n'
