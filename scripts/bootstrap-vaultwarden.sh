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
require_cmd openssl
require_cmd xxd

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

print_bootstrap_status() {
  cat <<EOF
Vaultwarden is reachable, but Twinbox bootstrap has not completed yet.

Run the full bootstrap to:
1. register the local Vaultwarden account ${VAULTWARDEN_VAULT_EMAIL}
2. generate the personal API key files under ${VAULTWARDEN_CLIENTID_FILE} and ${VAULTWARDEN_CLIENTSECRET_FILE}
3. seed the initial Twinbox Proxmox item
4. disable Vaultwarden signups and write ${VAULTWARDEN_READY_FILE}

Then run:
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

reset_bitwarden_state() {
  bw logout >/dev/null 2>&1 || true
}

password_login() {
  bw login "$VAULTWARDEN_VAULT_EMAIL" --passwordfile "$VAULTWARDEN_PASSWORD_FILE" --raw >/dev/null
}

derive_master_key_hex() {
  local email_lower="$1"
  local password="$2"
  local kdf_iterations="$3"

  openssl kdf -keylen 32 -kdfopt digest:SHA256 \
    -kdfopt "pass:${password}" \
    -kdfopt "hexsalt:$(printf '%s' "$email_lower" | xxd -p | tr -d '\n')" \
    -kdfopt "iter:${kdf_iterations}" -binary PBKDF2 | xxd -p | tr -d '\n'
}

derive_server_master_password_hash() {
  local master_key_hex="$1"
  local password="$2"

  openssl kdf -keylen 32 -kdfopt digest:SHA256 \
    -kdfopt "hexpass:${master_key_hex}" \
    -kdfopt "hexsalt:$(printf '%s' "$password" | xxd -p | tr -d '\n')" \
    -kdfopt 'iter:1' -binary PBKDF2 | openssl base64 -A
}

derive_wrapping_key_hex() {
  local master_key_hex="$1"
  local info_hex="$2"

  openssl kdf -keylen 32 -kdfopt digest:SHA256 \
    -kdfopt mode:EXPAND_ONLY \
    -kdfopt "hexkey:${master_key_hex}" \
    -kdfopt "hexinfo:${info_hex}" \
    -binary HKDF | xxd -p | tr -d '\n'
}

encrypt_hex_payload() {
  local plaintext_hex="$1"
  local enc_key_hex="$2"
  local mac_key_hex="$3"
  local iv_hex=""
  local ct_b64=""
  local iv_b64=""
  local mac_b64=""

  iv_hex="$(openssl rand -hex 16)"
  ct_b64="$(
    printf '%s' "$plaintext_hex" | xxd -r -p \
      | openssl enc -aes-256-cbc -nosalt -K "$enc_key_hex" -iv "$iv_hex" \
      | openssl base64 -A
  )"
  iv_b64="$(printf '%s' "$iv_hex" | xxd -r -p | openssl base64 -A)"
  mac_b64="$(
    {
      printf '%s' "$iv_hex" | xxd -r -p
      printf '%s' "$ct_b64" | openssl base64 -A -d
    } | openssl dgst -sha256 -mac hmac -macopt "hexkey:${mac_key_hex}" -binary | openssl base64 -A
  )"

  printf '2.%s|%s|%s' "$iv_b64" "$ct_b64" "$mac_b64"
}

request_email_verification_token() {
  local request_body=""

  request_body="$(jq -n \
    --arg email "$VAULTWARDEN_VAULT_EMAIL" \
    '
      {
        email: $email,
        name: "Twinbox",
        receiveMarketingEmails: false
      }
    '
  )"

  curl -fsS -X POST "${VAULTWARDEN_PUBLIC_URL}/identity/accounts/register/send-verification-email" \
    -H 'Content-Type: application/json' \
    -d "$request_body" | jq -r '.'
}

register_initial_account() {
  local password=""
  local email_lower=""
  local master_key_hex=""
  local master_password_hash=""
  local stretched_enc_key_hex=""
  local stretched_mac_key_hex=""
  local user_key_hex=""
  local user_enc_key_hex=""
  local user_mac_key_hex=""
  local user_symmetric_key=""
  local email_verification_token=""
  local key_dir=""
  local public_key_b64=""
  local private_key_hex=""
  local encrypted_private_key=""
  local register_payload=""

  password="$(read_secret_file "$VAULTWARDEN_PASSWORD_FILE")"
  email_lower="$(printf '%s' "$VAULTWARDEN_VAULT_EMAIL" | tr '[:upper:]' '[:lower:]')"
  master_key_hex="$(derive_master_key_hex "$email_lower" "$password" '600000')"
  master_password_hash="$(derive_server_master_password_hash "$master_key_hex" "$password")"
  stretched_enc_key_hex="$(derive_wrapping_key_hex "$master_key_hex" '656e63')"
  stretched_mac_key_hex="$(derive_wrapping_key_hex "$master_key_hex" '6d6163')"
  user_key_hex="$(openssl rand -hex 64)"
  user_enc_key_hex="${user_key_hex:0:64}"
  user_mac_key_hex="${user_key_hex:64:64}"
  user_symmetric_key="$(encrypt_hex_payload "$user_key_hex" "$stretched_enc_key_hex" "$stretched_mac_key_hex")"
  email_verification_token="$(request_email_verification_token)"

  key_dir="$(mktemp -d)"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -outform DER -out "${key_dir}/private.der" >/dev/null 2>&1
  openssl pkey -inform DER -in "${key_dir}/private.der" -pubout -outform DER -out "${key_dir}/public.der" >/dev/null 2>&1
  public_key_b64="$(openssl base64 -A < "${key_dir}/public.der")"
  private_key_hex="$(xxd -p "${key_dir}/private.der" | tr -d '\n')"
  encrypted_private_key="$(encrypt_hex_payload "$private_key_hex" "$user_enc_key_hex" "$user_mac_key_hex")"

  register_payload="$(jq -n \
    --arg email "$VAULTWARDEN_VAULT_EMAIL" \
    --arg master_password_hash "$master_password_hash" \
    --arg user_symmetric_key "$user_symmetric_key" \
    --arg public_key "$public_key_b64" \
    --arg encrypted_private_key "$encrypted_private_key" \
    --arg email_verification_token "$email_verification_token" \
    '
      {
        email: $email,
        masterPasswordHash: $master_password_hash,
        masterPasswordHint: "",
        userSymmetricKey: $user_symmetric_key,
        userAsymmetricKeys: {
          publicKey: $public_key,
          encryptedPrivateKey: $encrypted_private_key
        },
        kdf: 0,
        kdfIterations: 600000,
        emailVerificationToken: $email_verification_token
      }
    '
  )"

  curl -fsS -X POST "${VAULTWARDEN_PUBLIC_URL}/identity/accounts/register/finish" \
    -H 'Content-Type: application/json' \
    -d "$register_payload" >/dev/null
  rm -rf "$key_dir"
  log "Registered ${VAULTWARDEN_VAULT_EMAIL}"
}

read_bitwarden_access_context() {
  local appdata_file="${BW_APPDATA_DIR}/data.json"
  local user_id=""
  local access_token=""
  local kdf_type=""
  local kdf_iterations=""

  [[ -f "$appdata_file" ]] || fail "Bitwarden CLI state file not found: ${appdata_file}"

  user_id="$(jq -r '.activeUserId // empty' "$appdata_file")"
  access_token="$(jq -r --arg uid "$user_id" '.[$uid].tokens.accessToken // empty' "$appdata_file")"
  kdf_type="$(jq -r --arg uid "$user_id" '.[$uid].profile.kdfType // empty' "$appdata_file")"
  kdf_iterations="$(jq -r --arg uid "$user_id" '.[$uid].profile.kdfIterations // empty' "$appdata_file")"

  [[ -n "$user_id" ]] || fail "Bitwarden CLI did not record an active user id"
  [[ -n "$access_token" ]] || fail "Bitwarden CLI did not record an access token"
  [[ -n "$kdf_type" ]] || fail "Bitwarden CLI did not record a KDF type"
  [[ -n "$kdf_iterations" ]] || fail "Bitwarden CLI did not record KDF iterations"

  printf '%s\n%s\n%s\n%s\n' "$user_id" "$access_token" "$kdf_type" "$kdf_iterations"
}

create_personal_api_key_files() {
  local password=""
  local email_lower=""
  local user_id=""
  local access_token=""
  local kdf_type=""
  local kdf_iterations=""
  local master_key_hex=""
  local master_password_hash=""
  local api_key=""

  password="$(read_secret_file "$VAULTWARDEN_PASSWORD_FILE")"
  email_lower="$(printf '%s' "$VAULTWARDEN_VAULT_EMAIL" | tr '[:upper:]' '[:lower:]')"

  mapfile -t bw_context < <(read_bitwarden_access_context)
  user_id="${bw_context[0]}"
  access_token="${bw_context[1]}"
  kdf_type="${bw_context[2]}"
  kdf_iterations="${bw_context[3]}"

  [[ "$kdf_type" == '0' ]] || fail "Unsupported Vaultwarden KDF type for automated bootstrap: ${kdf_type}"

  master_key_hex="$(derive_master_key_hex "$email_lower" "$password" "$kdf_iterations")"
  master_password_hash="$(derive_server_master_password_hash "$master_key_hex" "$password")"
  api_key="$(
    curl -fsS -X POST "${VAULTWARDEN_PUBLIC_URL}/api/accounts/api-key" \
      -H "Authorization: Bearer ${access_token}" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg master_password_hash "$master_password_hash" '{masterPasswordHash: $master_password_hash}')" \
      | jq -r '.ApiKey // empty'
  )"

  [[ -n "$api_key" ]] || fail "Vaultwarden did not return an API key"

  printf 'user.%s' "$user_id" > "$VAULTWARDEN_CLIENTID_FILE"
  printf '%s' "$api_key" > "$VAULTWARDEN_CLIENTSECRET_FILE"
  chmod 0600 "$VAULTWARDEN_CLIENTID_FILE" "$VAULTWARDEN_CLIENTSECRET_FILE"
  log "Wrote Vaultwarden API key bootstrap files"
}

ensure_local_account_bootstrap() {
  if [[ -s "$VAULTWARDEN_CLIENTID_FILE" && -s "$VAULTWARDEN_CLIENTSECRET_FILE" ]]; then
    return 0
  fi

  reset_bitwarden_state

  if ! password_login >/dev/null 2>&1; then
    register_initial_account
    reset_bitwarden_state
    password_login >/dev/null 2>&1 || fail "Vaultwarden password login failed after account registration"
  fi

  create_personal_api_key_files
  reset_bitwarden_state
}

ensure_vaultwarden_login() {
  local status=""

  status="$(bw status 2>/dev/null | jq -r '.status // ""' || true)"
  if [[ "$status" == "unauthenticated" || -z "$status" ]]; then
    local client_id=""
    local client_secret=""
    client_id="$(read_secret_file "$VAULTWARDEN_CLIENTID_FILE")"
    client_secret="$(read_secret_file "$VAULTWARDEN_CLIENTSECRET_FILE")"
    if ! BW_CLIENTID="$client_id" BW_CLIENTSECRET="$client_secret" bw login --apikey >/dev/null 2>&1; then
      log "Stored Vaultwarden API key is invalid; regenerating from password login"
      reset_bitwarden_state
      password_login >/dev/null 2>&1 || fail "Password login failed while refreshing Vaultwarden API key"
      create_personal_api_key_files
      client_id="$(read_secret_file "$VAULTWARDEN_CLIENTID_FILE")"
      client_secret="$(read_secret_file "$VAULTWARDEN_CLIENTSECRET_FILE")"
      reset_bitwarden_state
      BW_CLIENTID="$client_id" BW_CLIENTSECRET="$client_secret" bw login --apikey >/dev/null
    fi
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

  if [[ -f "$VAULTWARDEN_READY_FILE" && -s "$VAULTWARDEN_CLIENTID_FILE" && -s "$VAULTWARDEN_CLIENTSECRET_FILE" ]]; then
    log "Vaultwarden bootstrap already completed"
    exit 0
  fi

  ensure_vaultwarden_server_config

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    print_bootstrap_status
    exit 0
  fi

  ensure_local_account_bootstrap
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
