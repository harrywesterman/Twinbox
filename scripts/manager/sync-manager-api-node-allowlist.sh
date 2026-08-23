#!/usr/bin/env bash
set -euo pipefail

DEFAULT_MANAGER_API_TRUSTED_CIDRS="127.0.0.1/32,::1/128,172.16.0.0/12,10.0.0.0/8"
ENV_FILE="/opt/twinbox/.env"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/opt/twinbox}"
MANAGER_DATA_DIR="${MANAGER_DATA_DIR:-/data}"
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

env_file_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
    }
    END { print value }
  ' "$ENV_FILE" | sed 's/^["'\'']//;s/["'\'']$//'
}

resolve_runtime_paths() {
  local host_runtime_dir="${TWINBOX_HOST_RUNTIME_DIR:-}"

  if [[ -z "$host_runtime_dir" && -d /host/opt/twinbox ]]; then
    host_runtime_dir="/host/opt/twinbox"
  fi

  if [[ -n "$host_runtime_dir" ]]; then
    if [[ ( "$ENV_FILE" == "/opt/twinbox/.env" || ! -f "$ENV_FILE" ) && -f "${host_runtime_dir}/.env" ]]; then
      ENV_FILE="${host_runtime_dir}/.env"
    fi

    if [[ "$WORKSPACE_ROOT" == "/opt/twinbox" && -f "${host_runtime_dir}/docker-compose.yml" ]]; then
      WORKSPACE_ROOT="$host_runtime_dir"
    fi
  fi

  if [[ "$MANAGER_DATA_DIR" == "/data" && -d "${WORKSPACE_ROOT}/manager-data" ]]; then
    MANAGER_DATA_DIR="${WORKSPACE_ROOT}/manager-data"
  fi
}

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

bootstrap_dir() {
  local dir="${TWINBOX_BOOTSTRAP_DIR:-}"

  if [[ -z "$dir" ]]; then
    dir="$(env_file_value TWINBOX_BOOTSTRAP_DIR)"
  fi
  if [[ -z "$dir" && -d "${WORKSPACE_ROOT}/bootstrap" ]]; then
    dir="${WORKSPACE_ROOT}/bootstrap"
  fi
  if [[ -z "$dir" && -d /opt/twinbox/bootstrap ]]; then
    dir="/opt/twinbox/bootstrap"
  fi

  printf '%s\n' "$dir"
}

discover_kubeconfig_path() {
  local bootstrap_root=""
  local cluster_id="${TWINBOX_CLUSTER_ID:-}"
  local candidate=""

  bootstrap_root="$(bootstrap_dir)"
  [[ -n "$bootstrap_root" ]] || return 0

  if [[ -z "$cluster_id" && -d "${MANAGER_DATA_DIR}/clusters" ]] && command -v python3 >/dev/null 2>&1; then
    cluster_id="$(
      python3 - "${MANAGER_DATA_DIR}/clusters" <<'PY'
import json
import pathlib
import sys

cluster_dir = pathlib.Path(sys.argv[1])
records = []
for path in cluster_dir.glob("*.json"):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    cluster_id = data.get("id") or data.get("slug") or path.stem
    if not cluster_id:
        continue
    stamp = data.get("updated_at") or data.get("created_at") or ""
    records.append((stamp, path.stat().st_mtime, cluster_id))

for _, _, cluster_id in sorted(records, reverse=True):
    print(cluster_id)
    break
PY
    )"
  fi

  if [[ -n "$cluster_id" ]]; then
    candidate="${bootstrap_root}/secrets/cluster/${cluster_id}/kubeconfig/kubeconfig"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [[ -d "${bootstrap_root}/secrets/cluster" ]]; then
    find "${bootstrap_root}/secrets/cluster" \
      -mindepth 3 \
      -maxdepth 3 \
      -path '*/kubeconfig/kubeconfig' \
      -type f \
      -print 2>/dev/null \
      | sort \
      | tail -n 1
  fi
}

node_cidrs() {
  local kubectl_args=()
  local nodes_json=""

  if [[ -z "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG_PATH="$(discover_kubeconfig_path)"
  fi

  if [[ -n "$KUBECONFIG_PATH" ]]; then
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
      log "kubeconfig not found at ${KUBECONFIG_PATH}; skipping Talos node CIDRs"
      return 0
    fi
    kubectl_args+=(--kubeconfig "$KUBECONFIG_PATH")
  fi

  if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
    log "kubectl not found; skipping Talos node CIDRs"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found; skipping Talos node CIDRs"
    return 0
  fi

  if ! nodes_json="$("$KUBECTL_BIN" "${kubectl_args[@]}" get nodes -o json 2>/dev/null)"; then
    log "could not read Talos nodes from Kubernetes; skipping Talos node CIDRs"
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
  if [[ -z "$mgmt_ip" ]]; then
    mgmt_ip="$(env_file_value MANAGEMENT_VM_IP)"
  fi
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

  if [[ -n "$managed_cidrs" ]]; then
    {
      printf '\n%s\n' "$BEGIN_MARKER"
      printf '# Managed by scripts/manager/sync-manager-api-node-allowlist.sh; do not edit this block.\n'
      printf '%s%s\n' "$MANAGED_LINE_PREFIX" "$managed_cidrs"
      printf '%s\n' "$END_MARKER"
    } >>"$tmp_file"
  fi

  chmod --reference="$ENV_FILE" "$tmp_file" 2>/dev/null || chmod 0600 "$tmp_file"
  chown --reference="$ENV_FILE" "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$ENV_FILE"
}

run_firewall_helper_container() {
  local helper_image="${TWINBOX_MANAGER_FIREWALL_HELPER_IMAGE:-}"

  command -v docker >/dev/null 2>&1 || return 1

  if [[ -z "$helper_image" ]]; then
    helper_image="$(docker inspect -f '{{.Config.Image}}' twinbox-manager-worker 2>/dev/null || true)"
  fi
  helper_image="${helper_image:-ghcr.io/harrywesterman/twinbox-manager-worker:${TWINBOX_IMAGE_TAG:-sha-43e0a3a}}"

  log "applying manager-api firewall through privileged host-network helper"
  docker run --rm \
    --network host \
    --privileged \
    -e "MANAGER_API_PORT=${MANAGER_API_PORT:-8080}" \
    -e "MANAGER_API_TRUSTED_CIDRS=${next_cidrs}" \
    "$helper_image" \
    bash /opt/twinbox/scripts/manager/configure-manager-api-firewall.sh
}

apply_firewall() {
  local firewall_script="${WORKSPACE_ROOT}/bootstrap/bin/configure-manager-api-firewall.sh"
  if [[ -f /.dockerenv && -n "${TWINBOX_HOST_RUNTIME_DIR:-}" ]]; then
    if run_firewall_helper_container; then
      return 0
    fi
    log "manager-api firewall helper failed; cannot safely update host firewall from this container"
    return 1
  fi

  if [[ ! -x "$firewall_script" ]]; then
    firewall_script="${WORKSPACE_ROOT}/scripts/manager/configure-manager-api-firewall.sh"
  fi
  if [[ ! -x "$firewall_script" ]]; then
    log "manager-api firewall script not found; skipping firewall refresh"
    return 0
  fi

  MANAGER_API_TRUSTED_CIDRS="$next_cidrs" "$firewall_script"
}

restart_manager_api() {
  local compose_args=()

  if [[ ! -d "$WORKSPACE_ROOT" ]]; then
    log "workspace root ${WORKSPACE_ROOT} not found; skipping manager-api restart"
    return 0
  fi
  if [[ -f "$ENV_FILE" ]]; then
    compose_args+=(--env-file "$ENV_FILE")
  fi
  (cd "$WORKSPACE_ROOT" && docker compose "${compose_args[@]}" up -d manager-api)
}

resolve_runtime_paths

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
management_lan_cidr >"$mgmt_file"

if [[ ! -s "$nodes_file" && ! -s "$mgmt_file" ]]; then
  log "no Talos node InternalIP CIDRs or management VM LAN CIDR found; leaving manager-api allowlist unchanged"
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

if [[ -s "$mgmt_file" ]]; then
  cat "$mgmt_file" >>"$manual_file"
fi

cat "$manual_file" "$nodes_file" | awk '!seen[$0]++' >"$next_file"
next_cidrs="$(join_csv_file "$next_file")"
managed_cidrs="$(join_csv_file "$nodes_file")"

replace_env_file "$next_cidrs" "$managed_cidrs"
if [[ -s "$nodes_file" ]]; then
  log "updated manager-api trusted sources with Talos node CIDRs: ${managed_cidrs}"
else
  log "updated manager-api trusted sources without Talos node CIDRs"
fi
if [[ -s "$mgmt_file" ]]; then
  log "updated manager-api trusted sources with management VM LAN CIDR: $(join_csv_file "$mgmt_file")"
fi

if [[ "$SKIP_FIREWALL" -ne 1 ]]; then
  apply_firewall
fi

if [[ "$SKIP_RESTART" -ne 1 ]]; then
  restart_manager_api
fi
