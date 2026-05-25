#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
hostname="twinbox-mgmt-${cluster_slug}"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

lan_router_secret="/opt/twinbox/bootstrap/secrets/global/netbird-management-lan-router-${cluster_id}.json"
admin_secret="/opt/twinbox/bootstrap/secrets/global/netbird-admin-access-${cluster_id}.json"
if [[ -f "$lan_router_secret" ]]; then
  secret_file="$lan_router_secret"
else
  secret_file="$admin_secret"
fi
[[ -f "$secret_file" ]] || fail "NetBird Management VM access secret not found at $lan_router_secret or $admin_secret"

setup_key="$(jq -r '.NB_SETUP_KEY // empty' "$secret_file")"
management_url="$(jq -r '.NB_MANAGEMENT_URL // empty' "$secret_file")"
[[ -n "$setup_key" ]] || fail "NB_SETUP_KEY is missing from $secret_file"
[[ -n "$management_url" ]] || fail "NB_MANAGEMENT_URL is missing from $secret_file"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring NetBird admin access and LAN routing peer: $hostname"

if command -v netbird >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Using host NetBird client"
  netbird up --setup-key "$setup_key" --management-url "$management_url" --hostname "$hostname"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Using Dockerized NetBird client with host networking"
  docker volume create twinbox-netbird >/dev/null
  if docker ps -a --format '{{.Names}}' | grep -qx twinbox-netbird; then
    docker rm -f twinbox-netbird >/dev/null
  fi
  docker run -d \
    --name twinbox-netbird \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --cap-add SYS_RESOURCE \
    -e NB_SETUP_KEY="$setup_key" \
    -e NB_MANAGEMENT_URL="$management_url" \
    -e NB_HOSTNAME="$hostname" \
    -e NB_LOG_LEVEL=info \
    -v twinbox-netbird:/var/lib/netbird \
    -v /dev/net/tun:/dev/net/tun \
    "netbirdio/netbird:${PINNED_NETBIRD_VERSION:-latest}" >/dev/null
elif command -v docker >/dev/null 2>&1; then
  fail "Docker CLI is available, but the host Docker daemon is not reachable for Management VM enrollment"
else
  fail "Neither host netbird client nor docker is available for Management VM enrollment"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird admin access and LAN routing peer configured"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg hostname "$hostname" \
    --arg management_url "$management_url" \
    '{status: $status, outputs: {hostname: $hostname, management_url: $management_url}}' >"$STEP_RESULT_FILE"
fi
