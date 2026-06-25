#!/usr/bin/env bash
set -euo pipefail

MANAGER_API_PORT="${MANAGER_API_PORT:-8080}"
MANAGER_API_TRUSTED_CIDRS="${MANAGER_API_TRUSTED_CIDRS:-127.0.0.1/32,::1/128,172.16.0.0/12,10.0.0.0/8}"
CHAIN="TWINBOX-MANAGER-API"

log() {
  printf '[configure-manager-api-firewall] %s\n' "$1"
}

fail() {
  printf '[configure-manager-api-firewall] ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

split_cidrs() {
  local cidr=""
  IFS=',' read -ra raw_cidrs <<<"$MANAGER_API_TRUSTED_CIDRS"
  for cidr in "${raw_cidrs[@]}"; do
    cidr="${cidr//[[:space:]]/}"
    [[ -n "$cidr" ]] || continue
    printf '%s\n' "$cidr"
  done
}

is_ipv6_cidr() {
  [[ "$1" == *:* ]]
}

configure_ufw() {
  local cidr=""

  if ! command -v ufw >/dev/null 2>&1; then
    log "ufw not found; skipping host firewall rules"
    return 0
  fi

  while IFS= read -r cidr; do
    if ! ufw insert 1 allow from "$cidr" to any port "$MANAGER_API_PORT" proto tcp >/dev/null 2>&1; then
      ufw allow from "$cidr" to any port "$MANAGER_API_PORT" proto tcp >/dev/null 2>&1 || true
    fi
  done < <(split_cidrs)
  ufw deny in to any port "$MANAGER_API_PORT" proto tcp >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
}

ensure_docker_user_jump() {
  local tool="$1"

  "$tool" -N "$CHAIN" 2>/dev/null || true
  "$tool" -F "$CHAIN"
  if ! "$tool" -C DOCKER-USER -j "$CHAIN" 2>/dev/null; then
    "$tool" -I DOCKER-USER 1 -j "$CHAIN"
  fi
}

configure_docker_user_ipv4() {
  local cidr=""

  command -v iptables >/dev/null 2>&1 || return 0
  iptables -L DOCKER-USER >/dev/null 2>&1 || return 0
  ensure_docker_user_jump iptables

  while IFS= read -r cidr; do
    is_ipv6_cidr "$cidr" && continue
    iptables -A "$CHAIN" -p tcp --dport "$MANAGER_API_PORT" -s "$cidr" -j RETURN
  done < <(split_cidrs)
  iptables -A "$CHAIN" -p tcp --dport "$MANAGER_API_PORT" -j DROP
  iptables -A "$CHAIN" -j RETURN
}

configure_docker_user_ipv6() {
  local cidr=""

  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -L DOCKER-USER >/dev/null 2>&1 || return 0
  ensure_docker_user_jump ip6tables

  while IFS= read -r cidr; do
    is_ipv6_cidr "$cidr" || continue
    ip6tables -A "$CHAIN" -p tcp --dport "$MANAGER_API_PORT" -s "$cidr" -j RETURN
  done < <(split_cidrs)
  ip6tables -A "$CHAIN" -p tcp --dport "$MANAGER_API_PORT" -j DROP
  ip6tables -A "$CHAIN" -j RETURN
}

configure_ufw
configure_docker_user_ipv4
configure_docker_user_ipv6
log "manager-api:${MANAGER_API_PORT} allows sources: ${MANAGER_API_TRUSTED_CIDRS}"
