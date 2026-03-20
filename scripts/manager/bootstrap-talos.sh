#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --vip-ip IP --controlplane-ips CSV --worker-ips CSV --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
require_env() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || fail "Missing environment variable: ${name}"
}

task_put() {
  local endpoint="$1"
  local body_file=""
  local http_code=""
  local response=""
  local response_data=""
  shift

  body_file=$(mktemp)
  http_code=$(curl -k -sS -o "$body_file" -w '%{http_code}' -X PUT \
    -b "PVEAuthCookie=${TOKEN}" \
    -H "CSRFPreventionToken: ${CSRF}" \
    "$endpoint" \
    "$@")
  response=$(cat "$body_file")
  rm -f "$body_file"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    fail "Proxmox API PUT failed (${endpoint}) [HTTP ${http_code}]: ${response}"
  fi

  response_data=$(echo "$response" | jq -r '.data // empty')
  [[ -n "$response_data" ]] || fail "Proxmox API PUT returned empty data (${endpoint}): ${response}"
  printf '%s\n' "$response"
}

wait_for_task_completion() {
  local upid="$1"
  local attempts=120
  local status_resp=""
  local status=""
  local exitstatus=""

  while [[ "$attempts" -gt 0 ]]; do
    status_resp=$(curl -k -sS -b "PVEAuthCookie=${TOKEN}" "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/tasks/${upid}/status")
    status=$(echo "$status_resp" | jq -r '.data.status // empty')
    exitstatus=$(echo "$status_resp" | jq -r '.data.exitstatus // empty')

    if [[ "$status" == "stopped" ]]; then
      [[ "$exitstatus" == "OK" ]] || fail "Proxmox task failed (${upid}): ${exitstatus}"
      return 0
    fi

    sleep 1
    attempts=$((attempts - 1))
  done

  fail "Timed out waiting for Proxmox task (${upid})"
}

authenticate_proxmox() {
  require_env PROXMOX_HOST
  require_env PROXMOX_PORT
  require_env PROXMOX_USER
  require_env PROXMOX_PASSWORD

  local auth_resp=""
  auth_resp=$(curl -k -sS -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/access/ticket")
  TOKEN=$(echo "$auth_resp" | jq -r '.data.ticket // empty')
  CSRF=$(echo "$auth_resp" | jq -r '.data.CSRFPreventionToken // empty')
  [[ -n "$TOKEN" && -n "$CSRF" ]] || fail "Proxmox auth failed"
}

load_vm_ids() {
  mapfile -t cp_vm_ids < <(jq -r '.controlplane_vm_ids[]? // empty' "$cluster_file")
  mapfile -t worker_vm_ids < <(jq -r '.worker_vm_ids[]? // empty' "$cluster_file")
  all_vm_ids=("${cp_vm_ids[@]}" "${worker_vm_ids[@]}")
  PROXMOX_NODE="${PROXMOX_NODE:-$(jq -r '.metadata.proxmox_node // empty' "$cluster_file")}"
  [[ -n "$PROXMOX_NODE" ]] || fail "Missing Proxmox node in cluster metadata or PROXMOX_NODE"
}

detach_vm_iso() {
  local vmid="$1"
  local detach_resp=""
  local detach_upid=""

  log "Detaching Talos ISO from VM ${vmid}"
  detach_resp=$(task_put "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
    --data-urlencode "delete=ide2")
  detach_upid=$(echo "$detach_resp" | jq -r '.data // empty')
  [[ -n "$detach_upid" ]] || fail "Missing detach task UPID for VM ${vmid}"
  wait_for_task_completion "$detach_upid"
}

detach_all_vm_isos() {
  local vmid=""
  if [[ ${#all_vm_ids[@]} -eq 0 ]]; then
    log "No VM IDs recorded on cluster; skipping ISO detach"
    return 0
  fi

  authenticate_proxmox
  for vmid in "${all_vm_ids[@]}"; do
    [[ -n "$vmid" ]] || continue
    detach_vm_iso "$vmid"
  done
}

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
command -v jq >/dev/null 2>&1 || fail "jq not found"

clusters_dir="$DATA_DIR/clusters"
cluster_dir="$clusters_dir/$CLUSTER_ID"
mkdir -p "$cluster_dir"
cluster_file="$clusters_dir/${CLUSTER_ID}.json"
[[ -f "$cluster_file" ]] || fail "cluster not found: ${CLUSTER_ID}"
cp_vm_ids=()
worker_vm_ids=()
all_vm_ids=()
TOKEN=""
CSRF=""
PROXMOX_NODE="${PROXMOX_NODE:-}"

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

load_vm_ids
detach_all_vm_isos

tmp=$(mktemp)
jq --arg talos_dir "$talos_dir" '.status = "bootstrapped" | .updated_at = now | .talos_config_dir = $talos_dir' "$cluster_file" > "$tmp"
mv "$tmp" "$cluster_file"

log "Bootstrap finished"
