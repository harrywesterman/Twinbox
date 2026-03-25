#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
BW_APPDATA_DIR="${VAULTWARDEN_BOOTSTRAP_APPDATA_DIR:-${REPO_ROOT}/bootstrap/bw-host}"
CHECK_ONLY=0

usage() {
  cat <<'USAGE'
Usage: bootstrap-vaultwarden.sh [--check-only]
USAGE
}

log() {
  printf '[bootstrap-vaultwarden] %s\n' "$1"
}

fail() {
  printf '[bootstrap-vaultwarden] ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
require_cmd bw
require_cmd curl
require_cmd jq
require_cmd docker

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

VAULTWARDEN_LOCAL_PORT="${VAULTWARDEN_LOCAL_PORT:-8222}"
VAULTWARDEN_DOMAIN="${VAULTWARDEN_DOMAIN:-http://localhost:${VAULTWARDEN_LOCAL_PORT}}"
VAULTWARDEN_SERVER_URL="${VAULTWARDEN_SERVER_URL:-http://vaultwarden:80}"
VAULTWARDEN_VAULT_EMAIL="${VAULTWARDEN_VAULT_EMAIL:-twinbox@local}"
VAULTWARDEN_PASSWORD_FILE="${VAULTWARDEN_PASSWORD_FILE:-${REPO_ROOT}/bootstrap/vaultwarden-password}"
VAULTWARDEN_CLIENTID_FILE="${VAULTWARDEN_CLIENTID_FILE:-${REPO_ROOT}/bootstrap/vaultwarden-client-id}"
VAULTWARDEN_CLIENTSECRET_FILE="${VAULTWARDEN_CLIENTSECRET_FILE:-${REPO_ROOT}/bootstrap/vaultwarden-client-secret}"
VAULTWARDEN_READY_FILE="${VAULTWARDEN_READY_FILE:-${REPO_ROOT}/bootstrap/vaultwarden-ready}"
VAULTWARDEN_SIGNUPS_ALLOWED="${VAULTWARDEN_SIGNUPS_ALLOWED:-true}"
VAULTWARDEN_PUBLIC_URL="http://127.0.0.1:${VAULTWARDEN_LOCAL_PORT}"

export BITWARDENCLI_APPDATA_DIR="$BW_APPDATA_DIR"

wait_for_vaultwarden() {
  local local_url="http://127.0.0.1:${VAULTWARDEN_LOCAL_PORT}"
  local attempt=""

  for attempt in $(seq 1 60); do
    if curl -fsS "$local_url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  fail "Vaultwarden did not become ready on ${local_url}"
}

print_manual_first_user_instructions() {
  cat <<EOF
Vaultwarden is reachable, but initial account bootstrap is not complete.

Create the first user manually over an SSH tunnel:
1. ssh -L ${VAULTWARDEN_LOCAL_PORT}:127.0.0.1:${VAULTWARDEN_LOCAL_PORT} <management-vm>
2. Open http://localhost:${VAULTWARDEN_LOCAL_PORT}
3. Create the account ${VAULTWARDEN_VAULT_EMAIL}
4. Use the password from ${VAULTWARDEN_PASSWORD_FILE}
5. In Vaultwarden, create a personal API key for ${VAULTWARDEN_VAULT_EMAIL}
6. Write the API credentials on the management VM:
   printf '%s' '<client-id>' > ${VAULTWARDEN_CLIENTID_FILE}
   printf '%s' '<client-secret>' > ${VAULTWARDEN_CLIENTSECRET_FILE}
   chmod 0600 ${VAULTWARDEN_CLIENTID_FILE} ${VAULTWARDEN_CLIENTSECRET_FILE}
7. Then run:
   bash scripts/bootstrap-vaultwarden.sh
EOF
}

ensure_vaultwarden_server_config() {
  bw config server "$VAULTWARDEN_PUBLIC_URL" >/dev/null
}

read_secret_file() {
  local file="$1"
  [[ -s "$file" ]] || fail "Missing required secret file: $file"
  tr -d '\r' < "$file"
}

ensure_vaultwarden_login() {
  local status=""

  status="$(bw status 2>/dev/null | jq -r '.status // ""' || true)"
  if [[ "$status" == "unauthenticated" || -z "$status" ]]; then
    local client_id=""
    local client_secret=""
    client_id="$(read_secret_file "$VAULTWARDEN_CLIENTID_FILE")"
    client_secret="$(read_secret_file "$VAULTWARDEN_CLIENTSECRET_FILE")"
    BW_CLIENTID="$client_id" BW_CLIENTSECRET="$client_secret" bw login --apikey >/dev/null
  fi
}

unlock_session() {
  bw unlock --passwordfile "$VAULTWARDEN_PASSWORD_FILE" --raw
}

seed_proxmox_item() {
  local item_name="twinbox/global/proxmox"
  local item_json=""
  local template_json=""

  if bw list items --session "$BW_SESSION" --search "$item_name" | jq -e --arg name "$item_name" '.[] | select(.name == $name)' >/dev/null; then
    log "Proxmox item already exists"
    return 0
  fi

  template_json="$(bw get template item --session "$BW_SESSION")"
  item_json="$(printf '%s\n' "$template_json" | jq \
    --arg name "$item_name" \
    --arg host "${PROXMOX_HOST}" \
    --arg port "${PROXMOX_PORT}" \
    --arg username "${PROXMOX_USER}" \
    --arg password "${PROXMOX_PASSWORD}" \
    '
      .name = $name
      | .type = 1
      | .login.username = $username
      | .login.password = $password
      | .notes = "Seeded by Twinbox bootstrap"
      | .fields = [
          {"name":"host","value":$host,"type":0},
          {"name":"port","value":$port,"type":0},
          {"name":"endpoint","value":("https://" + $host + ":" + $port),"type":0}
        ]
    ')"

  printf '%s\n' "$item_json" | bw encode | bw create item --session "$BW_SESSION" >/dev/null
  log "Seeded ${item_name}"
}

disable_signups() {
  if grep -q '^VAULTWARDEN_SIGNUPS_ALLOWED=' "$ENV_FILE"; then
    sed -i 's/^VAULTWARDEN_SIGNUPS_ALLOWED=.*/VAULTWARDEN_SIGNUPS_ALLOWED=false/' "$ENV_FILE"
  else
    printf '\nVAULTWARDEN_SIGNUPS_ALLOWED=false\n' >> "$ENV_FILE"
  fi
}

write_ready_file() {
  mkdir -p "$(dirname "$VAULTWARDEN_READY_FILE")"
  chmod 0700 "$(dirname "$VAULTWARDEN_READY_FILE")"
  : > "$VAULTWARDEN_READY_FILE"
  chmod 0600 "$VAULTWARDEN_READY_FILE"
}

restart_vaultwarden() {
  docker compose up -d vaultwarden
}

main() {
  wait_for_vaultwarden
  mkdir -p "$BW_APPDATA_DIR"
  chmod 0700 "$BW_APPDATA_DIR"

  if [[ -f "$VAULTWARDEN_READY_FILE" ]]; then
    log "Vaultwarden bootstrap already completed"
    exit 0
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    print_manual_first_user_instructions
    exit 0
  fi

  ensure_vaultwarden_server_config
  ensure_vaultwarden_login
  BW_SESSION="$(unlock_session)"
  export BW_SESSION
  bw sync --session "$BW_SESSION" >/dev/null
  seed_proxmox_item
  disable_signups
  write_ready_file
  restart_vaultwarden
}

main "$@"
