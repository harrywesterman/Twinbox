#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: configure-bastion-beszel-agent.sh \
  --cluster-id ID \
  --agent-secret-file PATH \
  [--bastion-secret-file PATH] \
  [--beszel-version VERSION]
USAGE
  exit 1
}

CLUSTER_ID=""
AGENT_SECRET_FILE=""
BASTION_SECRET_FILE=""
BESZEL_VERSION="${BESZEL_VERSION:-${PINNED_BESZEL_VERSION:-0.18.7}}"
REMOTE_AGENT_DIR="/opt/twinbox/beszel-agent"
SYSTEM_NAME="twinbox-netbird-bastion"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --agent-secret-file) AGENT_SECRET_FILE="$2"; shift 2 ;;
    --bastion-secret-file) BASTION_SECRET_FILE="$2"; shift 2 ;;
    --beszel-version) BESZEL_VERSION="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$CLUSTER_ID" ]] || usage
[[ -n "$AGENT_SECRET_FILE" && -f "$AGENT_SECRET_FILE" ]] || usage
[[ -n "$BESZEL_VERSION" ]] || usage

if [[ -z "$BASTION_SECRET_FILE" ]]; then
  BASTION_SECRET_FILE="/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${CLUSTER_ID}.json"
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

quote() {
  printf '%q' "$1"
}

read_json_field() {
  local file="$1"
  local key="$2"
  jq -r --arg key "$key" '.[$key] // empty' "$file"
}

command -v jq >/dev/null 2>&1 || fail "jq is required to configure the Beszel bastion agent"
command -v ssh >/dev/null 2>&1 || fail "ssh is required to configure the Beszel bastion agent"

if [[ ! -f "$BASTION_SECRET_FILE" ]]; then
  log "No NetBird bastion secret found at ${BASTION_SECRET_FILE}; skipping Beszel bastion agent setup."
  exit 0
fi

BASTION_IP="$(read_json_field "$BASTION_SECRET_FILE" NETBIRD_IP)"
SSH_PRIVATE_KEY="$(read_json_field "$BASTION_SECRET_FILE" SSH_PRIVATE_KEY)"
BESZEL_AGENT_KEY="$(read_json_field "$AGENT_SECRET_FILE" key)"
BESZEL_AGENT_TOKEN="$(read_json_field "$AGENT_SECRET_FILE" token)"
BESZEL_HUB_URL="$(read_json_field "$AGENT_SECRET_FILE" hub_url)"

[[ -n "$BASTION_IP" ]] || fail "NetBird bastion secret does not contain NETBIRD_IP"
[[ -n "$SSH_PRIVATE_KEY" ]] || fail "NetBird bastion secret does not contain SSH_PRIVATE_KEY"
[[ -n "$BESZEL_AGENT_KEY" ]] || fail "Beszel agent secret does not contain key"
[[ -n "$BESZEL_AGENT_TOKEN" ]] || fail "Beszel agent secret does not contain token"
[[ -n "$BESZEL_HUB_URL" ]] || fail "Beszel agent secret does not contain hub_url"

tmp_files=()
cleanup() {
  local file
  for file in "${tmp_files[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

ssh_key_file="$(mktemp "${TMPDIR:-/tmp}/beszel-bastion-ssh-key-XXXXXX")"
agent_env_file="$(mktemp "${TMPDIR:-/tmp}/beszel-bastion-agent-env-XXXXXX")"
tmp_files+=("$ssh_key_file" "$agent_env_file")

printf '%s\n' "$SSH_PRIVATE_KEY" >"$ssh_key_file"
chmod 600 "$ssh_key_file"
unset SSH_PRIVATE_KEY

{
  printf 'HUB_URL=%s\n' "$BESZEL_HUB_URL"
  printf 'KEY=%s\n' "$BESZEL_AGENT_KEY"
  printf 'TOKEN=%s\n' "$BESZEL_AGENT_TOKEN"
  printf 'SYSTEM_NAME=%s\n' "$SYSTEM_NAME"
  printf 'DISABLE_SSH=true\n'
} >"$agent_env_file"
chmod 600 "$agent_env_file"
unset BESZEL_AGENT_KEY BESZEL_AGENT_TOKEN

ssh_opts=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -i "$ssh_key_file"
)

log "Configuring Beszel agent on NetBird bastion ${BASTION_IP}"

remote_agent_dir_q="$(quote "$REMOTE_AGENT_DIR")"
if ! ssh "${ssh_opts[@]}" "root@${BASTION_IP}" \
  "install -d -m 0700 ${remote_agent_dir_q} && umask 077 && cat > ${remote_agent_dir_q}/agent.env" \
  <"$agent_env_file"; then
  fail "Failed to upload Beszel agent environment to the NetBird bastion"
fi

remote_env=(
  "BESZEL_VERSION=$(quote "$BESZEL_VERSION")"
  "REMOTE_AGENT_DIR=$(quote "$REMOTE_AGENT_DIR")"
)

ssh "${ssh_opts[@]}" "root@${BASTION_IP}" "${remote_env[*]} bash -s" <<'REMOTE'
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker is not installed on the NetBird bastion"
docker compose version >/dev/null 2>&1 || fail "Docker Compose is not available on the NetBird bastion"

install -d -m 0700 "$REMOTE_AGENT_DIR"
install -d -m 0750 "$REMOTE_AGENT_DIR/data"
cd "$REMOTE_AGENT_DIR"

[[ -s agent.env ]] || fail "Beszel agent environment file is missing"
chmod 0600 agent.env

cat >docker-compose.yml <<EOF
services:
  beszel-agent:
    image: henrygd/beszel-agent:${BESZEL_VERSION}
    container_name: twinbox-beszel-bastion-agent
    restart: unless-stopped
    network_mode: host
    env_file:
      - ./agent.env
    volumes:
      - /opt/twinbox/beszel-agent/data:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF
chmod 0644 docker-compose.yml

docker compose pull beszel-agent
docker compose up -d beszel-agent

for attempt in $(seq 1 30); do
  status="$(docker inspect -f '{{.State.Status}}' twinbox-beszel-bastion-agent 2>/dev/null || true)"
  if [[ "$status" == "running" ]]; then
    log "Beszel bastion agent is running"
    exit 0
  fi
  sleep 2
done

docker logs --tail 80 twinbox-beszel-bastion-agent >&2 || true
fail "Beszel bastion agent did not reach running state"
REMOTE
