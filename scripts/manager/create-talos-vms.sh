#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --controlplane-count N --worker-count N --cpu-cores N --memory-mb N --disk-gb N --bridge BR --start-vmid ID --start-ip IP --vip-ip IP --proxmox-node NODE --storage-pool POOL --iso-storage STORE --talos-iso-file FILE --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; exit 1; }

required_env=(PROXMOX_HOST PROXMOX_PORT PROXMOX_USER PROXMOX_PASSWORD)
for var in "${required_env[@]}"; do
  [[ -n "${!var:-}" ]] || fail "Missing environment variable: $var"
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --controlplane-count) CP_COUNT="$2"; shift 2 ;;
    --worker-count) WORKER_COUNT="$2"; shift 2 ;;
    --cpu-cores) CPU_CORES="$2"; shift 2 ;;
    --memory-mb) MEMORY_MB="$2"; shift 2 ;;
    --disk-gb) DISK_GB="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --start-vmid) START_VMID="$2"; shift 2 ;;
    --start-ip) START_IP="$2"; shift 2 ;;
    --vip-ip) VIP_IP="$2"; shift 2 ;;
    --proxmox-node) PROXMOX_NODE="$2"; shift 2 ;;
    --storage-pool) STORAGE_POOL="$2"; shift 2 ;;
    --iso-storage) ISO_STORAGE="$2"; shift 2 ;;
    --talos-iso-file) TALOS_ISO_FILE="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "${CLUSTER_ID:-}" ]] || { usage; fail "cluster-id required"; }

clusters_dir="$DATA_DIR/clusters"
mkdir -p "$clusters_dir"

auth_resp=$(curl -k -sS -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/access/ticket")
TOKEN=$(echo "$auth_resp" | jq -r '.data.ticket // empty')
CSRF=$(echo "$auth_resp" | jq -r '.data.CSRFPreventionToken // empty')
[[ -n "$TOKEN" && -n "$CSRF" ]] || fail "Proxmox auth failed"

task_post() {
  local endpoint="$1"
  local body_file=""
  local http_code=""
  local response=""
  local response_data=""
  shift

  body_file=$(mktemp)
  http_code=$(curl -k -sS -o "$body_file" -w '%{http_code}' -X POST \
    -b "PVEAuthCookie=${TOKEN}" \
    -H "CSRFPreventionToken: ${CSRF}" \
    "$endpoint" \
    "$@")
  response=$(cat "$body_file")
  rm -f "$body_file"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    fail "Proxmox API POST failed (${endpoint}) [HTTP ${http_code}]: ${response}"
  fi

  response_data=$(echo "$response" | jq -r '.data // empty')
  [[ -n "$response_data" ]] || fail "Proxmox API POST returned empty data (${endpoint}): ${response}"
  printf '%s\n' "$response"
}

next_ip() {
  local base octet
  base=$(echo "$START_IP" | cut -d. -f1-3)
  octet=$(echo "$START_IP" | cut -d. -f4)
  echo "$base.$((octet + $1))"
}

create_vm() {
  local vmid="$1"
  local name="$2"
  local role_tag="$3"
  task_post "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu" \
    --data-urlencode "vmid=${vmid}" \
    --data-urlencode "name=${name}" \
    --data-urlencode "memory=${MEMORY_MB}" \
    --data-urlencode "cores=${CPU_CORES}" \
    --data-urlencode "tags=twinbox;talos;${role_tag};cluster-${CLUSTER_ID}" \
    --data-urlencode "net0=virtio,bridge=${BRIDGE}" \
    --data-urlencode "scsihw=virtio-scsi-pci" \
    --data-urlencode "scsi0=${STORAGE_POOL}:${DISK_GB}" \
    --data-urlencode "ide2=${ISO_STORAGE}:iso/${TALOS_ISO_FILE},media=cdrom" \
    --data-urlencode "boot=order=scsi0;ide2" \
    --data-urlencode "ostype=l26" >/dev/null

  task_post "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/start" >/dev/null
}

cp_ids=()
worker_ids=()
cp_ips=()
worker_ips=()

current_vmid="$START_VMID"
for i in $(seq 1 "$CP_COUNT"); do
  vm_name="${NAME}-cp-${i}"
  ip=$(next_ip $((i - 1)))
  create_vm "$current_vmid" "$vm_name" "controlplane"
  cp_ids+=("$current_vmid")
  cp_ips+=("$ip")
  current_vmid=$((current_vmid + 1))
  log "Created controlplane VM ${vm_name} (${ip})"
done

for i in $(seq 1 "$WORKER_COUNT"); do
  vm_name="${NAME}-worker-${i}"
  ip=$(next_ip $((CP_COUNT + i - 1)))
  create_vm "$current_vmid" "$vm_name" "worker"
  worker_ids+=("$current_vmid")
  worker_ips+=("$ip")
  current_vmid=$((current_vmid + 1))
  log "Created worker VM ${vm_name} (${ip})"
done

cluster_file="$clusters_dir/${CLUSTER_ID}.json"
if [[ -f "$cluster_file" ]]; then
  tmp=$(mktemp)
  jq \
    --argjson cp_ids "$(printf '%s\n' "${cp_ids[@]}" | jq -R . | jq -s .)" \
    --argjson worker_ids "$(printf '%s\n' "${worker_ids[@]}" | jq -R . | jq -s .)" \
    --argjson cp_ips "$(printf '%s\n' "${cp_ips[@]}" | jq -R . | jq -s .)" \
    --argjson worker_ips "$(printf '%s\n' "${worker_ips[@]}" | jq -R . | jq -s .)" \
    --arg vip "$VIP_IP" \
    '.status = "provisioned" | .updated_at = now | .controlplane_vm_ids=$cp_ids | .worker_vm_ids=$worker_ids | .controlplane_ips=$cp_ips | .worker_ips=$worker_ips | .vip_ip=$vip' \
    "$cluster_file" > "$tmp"
  mv "$tmp" "$cluster_file"
fi

log "Cluster provisioning finished"
