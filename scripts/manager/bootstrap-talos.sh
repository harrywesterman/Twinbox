#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --vip-ip IP --controlplane-ips CSV --worker-ips CSV --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; exit 1; }

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

IFS=',' read -r -a cp_ips <<< "${CONTROLPLANE_IPS:-}"
IFS=',' read -r -a worker_ips <<< "${WORKER_IPS:-}"
[[ ${#cp_ips[@]} -gt 0 && -n "${cp_ips[0]}" ]] || fail "At least one controlplane IP is required"
command -v talosctl >/dev/null 2>&1 || fail "talosctl not found"

clusters_dir="$DATA_DIR/clusters"
cluster_dir="$clusters_dir/$CLUSTER_ID"
mkdir -p "$cluster_dir"

talos_dir="$cluster_dir/talos"
mkdir -p "$talos_dir"
pushd "$talos_dir" >/dev/null

log "Generating Talos config"
talosctl gen config "$NAME" "https://${VIP_IP}:6443"

log "Applying controlplane config"
for ip in "${cp_ips[@]}"; do
  talosctl apply-config --insecure --nodes "$ip" --file controlplane.yaml
done

log "Applying worker config"
for ip in "${worker_ips[@]}"; do
  [[ -n "$ip" ]] || continue
  talosctl apply-config --insecure --nodes "$ip" --file worker.yaml
done

log "Bootstrapping cluster"
talosctl bootstrap --nodes "${cp_ips[0]}" --endpoints "${cp_ips[0]}" --talosconfig talosconfig

log "Generating kubeconfig"
talosctl kubeconfig --nodes "${cp_ips[0]}" --endpoints "${cp_ips[0]}" --talosconfig talosconfig
popd >/dev/null

cluster_file="$clusters_dir/${CLUSTER_ID}.json"
if [[ -f "$cluster_file" ]]; then
  tmp=$(mktemp)
  jq --arg talos_dir "$talos_dir" '.status = "bootstrapped" | .updated_at = now | .talos_config_dir = $talos_dir' "$cluster_file" > "$tmp"
  mv "$tmp" "$cluster_file"
fi

log "Bootstrap finished"
