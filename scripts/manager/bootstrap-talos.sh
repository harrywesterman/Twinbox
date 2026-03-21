#!/bin/bash
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --vip-ip IP --controlplane-ips CSV --worker-ips CSV --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --vip-ip) VIP_IP="$2"; shift 2 ;;
    --controlplane-ips) CONTROLPLANE_IPS="$2"; shift 2 ;;
    --worker-ips) WORKER_IPS="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "${CLUSTER_ID:-}" ]] || { usage; fail "cluster-id required"; }
[[ -n "${DATA_DIR:-}" ]] || { usage; fail "data-dir required"; }

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v talosctl >/dev/null 2>&1 || fail "talosctl not found"

clusters_dir="$DATA_DIR/clusters"
cluster_file="$clusters_dir/${CLUSTER_ID}.json"
[[ -f "$cluster_file" ]] || fail "cluster not found: ${CLUSTER_ID}"

on_error() {
  local status=$?
  if [[ -f "$cluster_file" ]]; then
    local tmp=""
    tmp="$(mktemp)"
    jq \
      --arg status "failed" \
      --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --arg last_error "bootstrap_talos failed" \
      '.status = $status | .updated_at = $updated_at | .last_error = $last_error' \
      "$cluster_file" > "$tmp"
    mv "$tmp" "$cluster_file"
  fi
  exit "$status"
}

trap on_error ERR

talos_dir="$DATA_DIR/clusters/$CLUSTER_ID/talos"
talosconfig_file="$talos_dir/talosconfig"
kubeconfig_file="$DATA_DIR/clusters/$CLUSTER_ID/kubeconfig"

mkdir -p "$talos_dir"

if [[ -n "${CONTROLPLANE_IPS:-}" ]]; then
  IFS=',' read -r -a cp_ips <<< "$CONTROLPLANE_IPS"
else
  mapfile -t cp_ips < <(jq -r '((.discovered_controlplane_ips // .controlplane_ips // [])[])' "$cluster_file")
fi

if [[ -n "${WORKER_IPS:-}" ]]; then
  IFS=',' read -r -a worker_ips <<< "$WORKER_IPS"
else
  mapfile -t worker_ips < <(jq -r '((.discovered_worker_ips // .worker_ips // [])[])' "$cluster_file")
fi

[[ ${#cp_ips[@]} -gt 0 && -n "${cp_ips[0]}" ]] || fail "At least one control plane IP is required"
[[ -f "$talosconfig_file" ]] || fail "talosconfig not found in ${talos_dir}"

first_cp_ip="${cp_ips[0]}"

log "Bootstrapping cluster from ${first_cp_ip}"
talosctl bootstrap \
  --nodes "$first_cp_ip" \
  --endpoints "$first_cp_ip" \
  --talosconfig "$talosconfig_file"

log "Writing kubeconfig"
talosctl kubeconfig "$kubeconfig_file" \
  --nodes "$first_cp_ip" \
  --endpoints "$first_cp_ip" \
  --talosconfig "$talosconfig_file" \
  --force

tmp="$(mktemp)"
jq \
  --arg status "bootstrapped" \
  --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg kubeconfig_path "$kubeconfig_file" \
  --arg talos_dir "$talos_dir" \
  '
    .status = $status
    | .updated_at = $updated_at
    | .kubeconfig_path = $kubeconfig_path
    | .talos_config_dir = $talos_dir
    | .talosconfig_path = ($talos_dir + "/talosconfig")
  ' "$cluster_file" > "$tmp"
mv "$tmp" "$cluster_file"

sync_user_kubeconfig() {
  local source_kubeconfig="$1"
  local target_user="${2:-}"
  local target_home=""

  if [[ -z "$target_user" ]]; then
    if [[ -d "/home/twinbox" ]]; then
      target_home="/home/twinbox"
    elif id "twinbox" >/dev/null 2>&1; then
      target_user="twinbox"
    elif [[ -n "${SUDO_USER:-}" ]]; then
      target_user="${SUDO_USER}"
    else
      target_user="$(id -un)"
    fi
  fi

  if [[ -z "$target_home" ]]; then
    target_home="$(getent passwd "$target_user" | cut -d: -f6 || echo "/home/$target_user")"
  fi

  local target_kube_dir="${target_home}/.kube"
  local target_kubeconfig="${target_kube_dir}/config"

  [[ -d "$target_home" ]] || fail "home directory not found: ${target_home}"

  local owner_uid
  owner_uid=$(stat -c '%u' "$target_home")
  local owner_gid
  owner_gid=$(stat -c '%g' "$target_home")

  install -d -m 700 -o "$owner_uid" -g "$owner_gid" "$target_kube_dir"
  install -m 600 -o "$owner_uid" -g "$owner_gid" "$source_kubeconfig" "$target_kubeconfig"
  log "Copied kubeconfig to ${target_kubeconfig}"
}

sync_user_talosconfig() {
  local source_talosconfig="$1"
  local default_node_ip="$2"
  local target_user="${3:-}"
  local target_home=""

  if [[ -z "$target_user" ]]; then
    if [[ -d "/home/twinbox" ]]; then
      target_home="/home/twinbox"
    elif id "twinbox" >/dev/null 2>&1; then
      target_user="twinbox"
    elif [[ -n "${SUDO_USER:-}" ]]; then
      target_user="${SUDO_USER}"
    else
      target_user="$(id -un)"
    fi
  fi

  if [[ -z "$target_home" ]]; then
    target_home="$(getent passwd "$target_user" | cut -d: -f6 || echo "/home/$target_user")"
  fi

  local target_talos_dir="${target_home}/.talos"
  local target_talosconfig="${target_talos_dir}/config"

  [[ -d "$target_home" ]] || fail "home directory not found: ${target_home}"

  local owner_uid
  owner_uid=$(stat -c '%u' "$target_home")
  local owner_gid
  owner_gid=$(stat -c '%g' "$target_home")

  install -d -m 700 -o "$owner_uid" -g "$owner_gid" "$target_talos_dir"
  install -m 600 -o "$owner_uid" -g "$owner_gid" "$source_talosconfig" "$target_talosconfig"

  # Update node/endpoint
  talosctl config node "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null
  talosctl config endpoint "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null

  # Fix ownership if we ran as root
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$owner_uid:$owner_gid" "$target_talosconfig"
  fi
  log "Copied talosconfig to ${target_talosconfig}"
}

sync_user_talosconfig "$talosconfig_file" "$first_cp_ip"
sync_user_kubeconfig "$kubeconfig_file"

log "Bootstrap finished"
