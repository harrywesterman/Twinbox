#!/usr/bin/env bash
set -euo pipefail

DEFAULT_MANAGER_API_TRUSTED_CIDRS="127.0.0.1/32,::1/128,172.16.0.0/12,10.0.0.0/8"
ENV_FILE="/opt/twinbox/.env"
WORKSPACE_ROOT="/opt/twinbox"
KUBECONFIG_PATH="${KUBECONFIG_FILE:-${KUBECONFIG:-}}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
SKIP_FIREWALL=0
SKIP_RESTART=0

BEGIN_MARKER="# BEGIN TWINBOX MANAGER API NODE ALLOWLIST"
END_MARKER="# END TWINBOX MANAGER API NODE ALLOWLIST"
MANAGED_LINE_PREFIX="# TWINBOX_MANAGER_API_NODE_CIDRS="

log() {
  printf '[sync-manager-api-node-allowlist] %s\n' "$1" >&2
}

usage() {
  cat <<'USAGE'
Usage: sync-manager-api-node-allowlist.sh [options]

Synchronize MANAGER_API_TRUSTED_CIDRS with the current Talos node InternalIP /32s and the management VM LAN CIDR.

Options:
  --env-file PATH       Env file to update (default: /opt/twinbox/.env)
  --workspace-root DIR  Management VM workspace (default: /opt/twinbox)
  --kubeconfig PATH     Cluster kubeconfig path
  --skip-firewall       Do not re-apply manager-api firewall rules
  --skip-restart        Do not recreate manager-api with the updated env
  -h, --help            Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --workspace-root)
      WORKSPACE_ROOT="${2:-}"
      shift 2
      ;;
    --kubeconfig)
      KUBECONFIG_PATH="${2:-}"
      shift 2
      ;;
    --skip-firewall)
      SKIP_FIREWALL=1
      shift
      ;;
    --skip-restart)
      SKIP_RESTART=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

split_csv() {
  tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF'
}

join_csv_file() {
  paste -sd, "$1"
}

previous_managed_cidrs() {
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v prefix="$MANAGED_LINE_PREFIX" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    inside && index($0, prefix) == 1 {
      print substr($0, length(prefix) + 1)
    }
  ' "$ENV_FILE" | split_csv
}

current_trusted_cidrs() {
  awk -F= '$1 == "MANAGER_API_TRUSTED_CIDRS" { value = substr($0, index($0, "=") + 1) } END { print value }' "$ENV_FILE" | split_csv
}

node_cidrs() {
  local kubectl_args=()
  local nodes_json=""

  if [[ -n "$KUBECONFIG_PATH" ]]; then
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
      log "kubeconfig not found at ${KUBECONFIG_PATH}; leaving manager-api allowlist unchanged"
      return 0
    fi
    kubectl_args+=(--kubeconfig "$KUBECONFIG_PATH")
  fi

  if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
    log "kubectl not found; leaving manager-api allowlist unchanged"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found; leaving manager-api allowlist unchanged"
    return 0
  fi

  if ! nodes_json="$("$KUBECTL_BIN" "${kubectl_args[@]}" get nodes -o json 2>/dev/null)"; then
    log "could not read Talos nodes from Kubernetes; leaving manager-api allowlist unchanged"
    return 0
  fi

  printf '%s\n' "$nodes_json" \
    | jq -r '
      .items[]?.status.addresses[]?
      | select(.type == "InternalIP")
      | .address
    ' \
    | awk '
      /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $0 "/32"; next }
      /:/ { print $0 "/128" }
    ' \
    | awk '!seen[$0]++'
}

management_lan_cidr() {
  local mgmt_ip="${MANAGEMENT_VM_IP:-}"
  [[ -n "$mgmt_ip" ]] || return 0

  local prefix=""
  prefix="$(ip -o -f inet addr show 2>/dev/null | awk -v ip="$mgmt_ip" '
    $0 ~ " inet " ip "/" {
      n = split($4, parts, "/")
      if (n == 2) {
        print parts[2]
        exit
      }
    }
  ')"
  [[ -n "$prefix" ]] || return 0

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$mgmt_ip" "$prefix" <<'PY'
import sys, ipaddress
print(str(ipaddress.ip_interface(f"{sys.argv[1]}/{sys.argv[2]}").network))
PY
  fi
}

replace_env_file() {
  local next_cidrs="$1"
  local managed_cidrs="$2"
  local tmp_file=""
  tmp_file="$(mktemp)"

  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v cidrs="$next_cidrs" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0; next }
    inside { next }
    /^MANAGER_API_TRUSTED_CIDRS=/ && ! done {
      print "MANAGER_API_TRUSTED_CIDRS=" cidrs
      done = 1
      next
    }
    /^MANAGER_API_TRUSTED_CIDRS=/ { next }
    { print }
    END {
      if (!done) {
        print "MANAGER_API_TRUSTED_CIDRS=" cidrs
      }
    }
  ' "$ENV_FILE" >"$tmp_file"

  {
    printf '\n%s\n' "$BEGIN_MARKER"
    printf '# Managed by scripts/manager/sync-manager-api-node-allowlist.sh; do not edit this block.\n'
    printf '%s%s\n' "$MANAGED_LINE_PREFIX" "$managed_cidrs"
    printf '%s\n' "$END_MARKER"
  } >>"$tmp_file"

  chmod --reference="$ENV_FILE" "$tmp_file" 2>/dev/null || chmod 0600 "$tmp_file"
  chown --reference="$ENV_FILE" "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$ENV_FILE"
}

apply_firewall() {
  local firewall_script="${WORKSPACE_ROOT}/bootstrap/bin/configure-manager-api-firewall.sh"
  if [[ ! -x "$firewall_script" ]]; then
    firewall_script="${WORKSPACE_ROOT}/scripts/manager/configure-manager-api-firewall.sh"
  fi
  if [[ ! -x "$firewall_script" ]]; then
    log "manager-api firewall script not found; skipping firewall refresh"
    return 0
  fi

  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  "$firewall_script"
}

restart_manager_api() {
  if [[ ! -d "$WORKSPACE_ROOT" ]]; then
    log "workspace root ${WORKSPACE_ROOT} not found; skipping manager-api restart"
    return 0
  fi
  (cd "$WORKSPACE_ROOT" && docker compose up -d manager-api)
}

if [[ ! -f "$ENV_FILE" ]]; then
  log "env file not found at ${ENV_FILE}; leaving manager-api allowlist unchanged"
  exit 0
fi

previous_file="$(mktemp)"
current_file="$(mktemp)"
manual_file="$(mktemp)"
nodes_file="$(mktemp)"
next_file="$(mktemp)"
mgmt_file="$(mktemp)"
trap 'rm -f "$previous_file" "$current_file" "$manual_file" "$nodes_file" "$next_file" "$mgmt_file"' EXIT

previous_managed_cidrs >"$previous_file"
current_trusted_cidrs >"$current_file"
node_cidrs >"$nodes_file"

if [[ ! -s "$nodes_file" ]]; then
  log "no Talos node InternalIP CIDRs found; leaving manager-api allowlist unchanged"
  exit 0
fi

if [[ -s "$previous_file" ]]; then
  grep -vxFf "$previous_file" "$current_file" >"$manual_file" || true
else
  cp "$current_file" "$manual_file"
fi

if [[ ! -s "$manual_file" ]]; then
  printf '%s\n' "$DEFAULT_MANAGER_API_TRUSTED_CIDRS" | split_csv >"$manual_file"
fi

management_lan_cidr >"$mgmt_file"
if [[ -s "$mgmt_file" ]]; then
  cat "$mgmt_file" >>"$manual_file"
fi

cat "$manual_file" "$nodes_file" | awk '!seen[$0]++' >"$next_file"
next_cidrs="$(join_csv_file "$next_file")"
managed_cidrs="$(join_csv_file "$nodes_file")"

replace_env_file "$next_cidrs" "$managed_cidrs"
log "updated manager-api trusted sources with Talos node CIDRs: ${managed_cidrs}"
if [[ -s "$mgmt_file" ]]; then
  log "updated manager-api trusted sources with management VM LAN CIDR: $(join_csv_file "$mgmt_file")"
fi

if [[ "$SKIP_FIREWALL" -ne 1 ]]; then
  apply_firewall
fi

if [[ "$SKIP_RESTART" -ne 1 ]]; then
  restart_manager_api
fi
