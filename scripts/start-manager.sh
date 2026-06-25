#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-${REPO_ROOT}/bootstrap}"
RAW_BASE_URL="${TWINBOX_RAW_BASE_URL:-https://raw.githubusercontent.com/harrywesterman/twinbox/main}"
BOOTSTRAP_ONCE=0
BOOTSTRAP_MARKER="${BOOTSTRAP_DIR}/state/manager-stack.started"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/manager/management-ip.sh"

log() {
  printf '[start-manager] %s\n' "$1"
}

fail() {
  printf '[start-manager] ERROR: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: start-manager.sh [--bootstrap-once]

Start the Twinbox manager stack from the runtime tree.

  --bootstrap-once  Skip if the stack was already bootstrapped and write a marker after the first successful start.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-once)
      BOOTSTRAP_ONCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$BOOTSTRAP_ONCE" -eq 1 && -f "$BOOTSTRAP_MARKER" ]]; then
  log "Manager stack already bootstrapped; skipping"
  exit 0
fi

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
TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap
TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets
TWINBOX_SECRET_CACHE_TTL_SEC=60
EOF
}

append_manager_api_source_allowlist() {
  if grep -q '^MANAGER_API_TRUSTED_CIDRS=' .env; then
    return 0
  fi

  cat >> .env <<'EOF'

MANAGER_API_TRUSTED_CIDRS=127.0.0.1/32,::1/128,172.16.0.0/12,10.0.0.0/8
EOF
}

append_env_value_if_missing() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" .env; then
    return 0
  fi

  printf '%s=%s\n' "$key" "$value" >> .env
}

append_forgejo_env_block() {
  local management_ip="${MANAGEMENT_VM_IP:-}"
  local forgejo_port="${FORGEJO_HTTP_PORT:-3001}"
  local forgejo_root_url=""
  local forgejo_owner="${TWINBOX_FORGEJO_REPO_OWNER:-${FORGEJO_ADMIN_USER:-twinbox}}"
  local forgejo_repo_name="${TWINBOX_FORGEJO_REPO_NAME:-Twinbox}"

  if [[ -z "$management_ip" ]]; then
    if ! management_ip="$(resolve_management_vm_ip)"; then
      fail "Could not determine management VM IP"
    fi
  fi

  forgejo_root_url="${FORGEJO_ROOT_URL:-http://${management_ip}:${forgejo_port}/}"

  append_env_value_if_missing "FORGEJO_HTTP_PORT" "$forgejo_port"
  append_env_value_if_missing "FORGEJO_ROOT_URL" "$forgejo_root_url"
  append_env_value_if_missing "TWINBOX_UPSTREAM_GIT_REPO_URL" "https://github.com/harrywesterman/Twinbox.git"
  append_env_value_if_missing "TWINBOX_FORGEJO_REPO_OWNER" "$forgejo_owner"
  append_env_value_if_missing "TWINBOX_FORGEJO_REPO_NAME" "$forgejo_repo_name"
  append_env_value_if_missing "TWINBOX_FORGEJO_REPO_URL" "${forgejo_root_url%/}/${forgejo_owner}/${forgejo_repo_name}.git"
}

remove_tool_version_envs() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  awk '!/^(KUBECTL_VERSION|HELM_VERSION)=/' .env >"$tmp_file"
  mv "$tmp_file" .env
}

refresh_bootstrap_file() {
  local source_url="$1"
  local target_file="$2"
  local mode="${3:-0644}"
  local tmp_file=""

  tmp_file="$(mktemp)"
  if curl -fsSL "$source_url" -o "$tmp_file"; then
    install -m "$mode" "$tmp_file" "$target_file"
    rm -f "$tmp_file"
    return 0
  fi

  rm -f "$tmp_file"
  if [[ -f "$target_file" ]]; then
    log "Could not refresh ${target_file}; using cached copy"
    return 0
  fi

  return 1
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
  local username="${SEAWEEDFS_ACCESS_KEY_ID:-velero}"
  local password="${SEAWEEDFS_SECRET_ACCESS_KEY:-}"
  local bucket="${SEAWEEDFS_BUCKET:-twinbox-velero}"
  local region="${SEAWEEDFS_REGION:-seaweedfs}"

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

  if [[ -f "$velero_file" ]]; then
    local file_value=""

    file_value="$(jq -r '.username // empty' "$velero_file" 2>/dev/null || printf '')"
    [[ -n "$file_value" ]] && username="$file_value"

    file_value="$(jq -r '.password // empty' "$velero_file" 2>/dev/null || printf '')"
    [[ -n "$file_value" ]] && password="$file_value"

    file_value="$(jq -r '.bucket // empty' "$velero_file" 2>/dev/null || printf '')"
    [[ -n "$file_value" ]] && bucket="$file_value"

    file_value="$(jq -r '.region // empty' "$velero_file" 2>/dev/null || printf '')"
    [[ -n "$file_value" ]] && region="$file_value"
  fi

  if [[ -z "$password" ]]; then
    password="$(openssl rand -hex 16)"
  fi

  if ! management_ip="$(resolve_management_vm_ip)"; then
    fail "Could not determine management VM IP"
  fi

  export MANAGEMENT_VM_IP="$management_ip"
  export SEAWEEDFS_ACCESS_KEY_ID="$username"
  export SEAWEEDFS_SECRET_ACCESS_KEY="$password"
  export SEAWEEDFS_BUCKET="$bucket"
  export SEAWEEDFS_REGION="$region"

  python3 - "$velero_file" <<'PY'
import json
import os
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
management_ip = os.environ["MANAGEMENT_VM_IP"]
payload = {
    "mode": "seaweedfs",
    "endpoint": f"http://{management_ip}:8333",
    "bucket": os.environ["SEAWEEDFS_BUCKET"],
    "region": os.environ["SEAWEEDFS_REGION"],
    "username": os.environ["SEAWEEDFS_ACCESS_KEY_ID"],
    "password": os.environ["SEAWEEDFS_SECRET_ACCESS_KEY"],
}
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
target.chmod(0o600)
PY

  if [[ ! -f "$seal_key_file" ]]; then
    openssl rand -hex 32 > "$seal_key_file"
    chmod 0600 "$seal_key_file"
  fi

  if [[ ! -f "$seal_key_id_file" ]]; then
    openssl rand -hex 16 > "$seal_key_id_file"
    chmod 0600 "$seal_key_id_file"
  fi
}

ensure_seaweedfs_bootstrap() {
  local attempt=1
  local attempts=60
  local bucket_list=""

  while [[ "$attempt" -le "$attempts" ]]; do
    if docker exec twinbox-seaweedfs sh -lc 'printf "s3.config.show\n" | weed shell' >/dev/null 2>&1; then
      break
    fi

    log "Waiting for SeaweedFS S3 shell to become ready"
    sleep 5
    attempt=$((attempt + 1))
  done

  if [[ "$attempt" -gt "$attempts" ]]; then
    log "SeaweedFS S3 shell never became ready"
    return 1
  fi

  log "Reconciling SeaweedFS IAM config for ${SEAWEEDFS_ACCESS_KEY_ID}"
  docker exec twinbox-seaweedfs sh -lc \
    "printf 's3.configure --user ${SEAWEEDFS_ACCESS_KEY_ID} --access_key ${SEAWEEDFS_ACCESS_KEY_ID} --secret_key ${SEAWEEDFS_SECRET_ACCESS_KEY} --buckets ${SEAWEEDFS_BUCKET} --actions Read,Write,List,Tagging,Admin --apply true\n' | weed shell" >/dev/null

  bucket_list="$(
    docker exec twinbox-seaweedfs sh -lc 'printf "s3.bucket.list\n" | weed shell'
  )"
  if ! grep -Eq "^[[:space:]]+${SEAWEEDFS_BUCKET}[[:space:]]" <<<"$bucket_list"; then
    log "Creating SeaweedFS bucket ${SEAWEEDFS_BUCKET}"
    docker exec twinbox-seaweedfs sh -lc \
      "printf 's3.bucket.create -name ${SEAWEEDFS_BUCKET} -owner ${SEAWEEDFS_ACCESS_KEY_ID}\n' | weed shell" >/dev/null
  fi

  bucket_list="$(
    docker exec twinbox-seaweedfs sh -lc 'printf "s3.bucket.list\n" | weed shell'
  )"
  if ! grep -Eq "^[[:space:]]+${SEAWEEDFS_BUCKET}[[:space:]]" <<<"$bucket_list"; then
    log "SeaweedFS bucket ${SEAWEEDFS_BUCKET} was not created"
    return 1
  fi
}

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo ".env created from .env.example. Update values before continuing."
  exit 1
fi

if [[ ! -d "$BOOTSTRAP_DIR" ]]; then
  install -d -m 0755 "$BOOTSTRAP_DIR/secrets/global" "$BOOTSTRAP_DIR/ansible" "$BOOTSTRAP_DIR/config" "$BOOTSTRAP_DIR/bin" "$BOOTSTRAP_DIR/state"
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

refresh_bootstrap_file \
  "${RAW_BASE_URL}/scripts/manager/configure-manager-api-firewall.sh" \
  "${BOOTSTRAP_DIR}/bin/configure-manager-api-firewall.sh" \
  0755

refresh_bootstrap_file \
  "${RAW_BASE_URL}/scripts/manager/sync-manager-api-node-allowlist.sh" \
  "${BOOTSTRAP_DIR}/bin/sync-manager-api-node-allowlist.sh" \
  0755

if [[ ! -f "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh" ]]; then
  curl -fsSL "${RAW_BASE_URL}/scripts/manager/bootstrap-forgejo.sh" -o "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh"
  chmod 0755 "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh"
fi

if [[ ! -f "${BOOTSTRAP_DIR}/bin/forgejo-promote-upstream.sh" ]]; then
  curl -fsSL "${RAW_BASE_URL}/scripts/manager/forgejo-promote-upstream.sh" -o "${BOOTSTRAP_DIR}/bin/forgejo-promote-upstream.sh"
  chmod 0755 "${BOOTSTRAP_DIR}/bin/forgejo-promote-upstream.sh"
fi

if [[ -x "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" ]]; then
  sudo "${BOOTSTRAP_DIR}/bin/install-management-tools.sh" --env-file .env
else
  echo "Missing install-management-tools.sh in bootstrap tree"
  exit 1
fi

append_secret_env_block
append_manager_api_source_allowlist
remove_tool_version_envs
set -a
# shellcheck disable=SC1091
source .env
set +a
append_forgejo_env_block
set -a
# shellcheck disable=SC1091
source .env
set +a
ensure_bootstrap_material

if [[ ! -f docker-compose.yml ]]; then
  curl -fsSL "${RAW_BASE_URL}/docker-compose.yml" -o docker-compose.yml
fi

runtime_services=(
  manager-api
  manager-worker
  manager-web
  seaweedfs
  seaweedfs-admin
  beszel
  beszel-agent
)

forgejo_started="false"
if ! docker compose pull forgejo; then
  log "Forgejo image pull failed; trying to start any local image before falling back to GitHub source"
fi
if docker compose up -d forgejo; then
  forgejo_started="true"
else
  log "Forgejo startup failed; continuing with GitHub source"
fi

if [[ "$forgejo_started" == "true" && -x "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh" ]]; then
  log "Bootstrapping Forgejo"
  if ! "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh"; then
    log "Forgejo bootstrap failed; continuing with GitHub source"
  else
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
fi

docker compose pull "${runtime_services[@]}"
docker compose up -d "${runtime_services[@]}"

sudo "${BOOTSTRAP_DIR}/bin/configure-manager-api-firewall.sh"
sudo "${BOOTSTRAP_DIR}/bin/sync-manager-api-node-allowlist.sh"
ensure_seaweedfs_bootstrap

if [[ "$BOOTSTRAP_ONCE" -eq 1 ]]; then
  install -d -m 0755 "$(dirname "$BOOTSTRAP_MARKER")"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BOOTSTRAP_MARKER"
fi

echo "Manager stack started"
echo "Web: http://localhost:3000"
echo "API: http://localhost:8080/api/health"
