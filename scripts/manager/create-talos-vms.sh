#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --controlplane-count N --worker-count N --cpu-cores N --memory-mb N --disk-gb N --bridge BR --start-vmid ID --start-ip IP --vip-ip IP --node-prefix-length N --gateway-ip IP --dns-servers CSV --dns-domain NAME --proxmox-node NODE --storage-pool POOL --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../config/pinned-defaults.sh"

required_env=(PROXMOX_HOST PROXMOX_PORT PROXMOX_USER PROXMOX_PASSWORD)
for var in "${required_env[@]}"; do
  [[ -n "${!var:-}" ]] || fail "Missing environment variable: $var"
done

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v talosctl >/dev/null 2>&1 || fail "talosctl not found"

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
    --node-prefix-length) NODE_PREFIX_LENGTH="$2"; shift 2 ;;
    --gateway-ip) GATEWAY_IP="$2"; shift 2 ;;
    --dns-servers) DNS_SERVERS="$2"; shift 2 ;;
    --dns-domain) DNS_DOMAIN="$2"; shift 2 ;;
    --proxmox-node) PROXMOX_NODE="$2"; shift 2 ;;
    --storage-pool) STORAGE_POOL="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "${CLUSTER_ID:-}" ]] || { usage; fail "cluster-id required"; }

clusters_dir="$DATA_DIR/clusters"
cluster_dir="$clusters_dir/$CLUSTER_ID"
talos_dir="$cluster_dir/talos"
cluster_file="$clusters_dir/${CLUSTER_ID}.json"
mkdir -p "$clusters_dir" "$talos_dir"

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

task_upload() {
  local endpoint="$1"
  local file="$2"
  local content_type="$3"
  local body_file=""
  local http_code=""
  local response=""
  local response_data=""

  body_file=$(mktemp)
  http_code=$(curl -k -sS -o "$body_file" -w '%{http_code}' -X POST \
    -b "PVEAuthCookie=${TOKEN}" \
    -H "CSRFPreventionToken: ${CSRF}" \
    -F "content=${content_type}" \
    -F "filename=@${file}" \
    "$endpoint")
  response=$(cat "$body_file")
  rm -f "$body_file"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    fail "Proxmox API upload failed (${endpoint}) [HTTP ${http_code}]: ${response}"
  fi

  response_data=$(echo "$response" | jq -r '.data // empty')
  [[ -n "$response_data" ]] || fail "Proxmox API upload returned empty data (${endpoint}): ${response}"
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

next_ip() {
  local base octet
  base=$(echo "$START_IP" | cut -d. -f1-3)
  octet=$(echo "$START_IP" | cut -d. -f4)
  echo "$base.$((octet + $1))"
}

generate_talos_configs() {
  local controlplane_patch="$talos_dir/controlplane-patch.yaml"

  cat > "$controlplane_patch" <<EOF
machine:
  network:
    interfaces:
      - interface: eth0
        vip:
          ip: ${VIP_IP}
EOF

  log "Generating Talos config"
  talosctl gen config "$NAME" "https://${VIP_IP}:6443" \
    --output-dir "$talos_dir" \
    --config-patch-control-plane "@${controlplane_patch}"

  CONTROLPLANE_SNIPPET_NAME="${CLUSTER_ID}-controlplane.yaml"
  WORKER_SNIPPET_NAME="${CLUSTER_ID}-worker.yaml"
  cp "$talos_dir/controlplane.yaml" "$talos_dir/$CONTROLPLANE_SNIPPET_NAME"
  cp "$talos_dir/worker.yaml" "$talos_dir/$WORKER_SNIPPET_NAME"
}

upload_talos_snippet() {
  local snippet_name="$1"
  local upload_resp=""
  local upload_upid=""

  log "Uploading Talos snippet ${snippet_name}"
  upload_resp=$(task_upload \
    "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/storage/${PINNED_PROXMOX_ISO_STORAGE}/upload" \
    "$talos_dir/${snippet_name}" \
    "snippets")
  upload_upid=$(echo "$upload_resp" | jq -r '.data // empty')
  [[ -n "$upload_upid" ]] || fail "Missing upload task UPID for snippet ${snippet_name}"
  wait_for_task_completion "$upload_upid"
}

create_vm() {
  local vmid="$1"
  local name="$2"
  local role_tag="$3"
  local ip="$4"
  local snippet_name="$5"
  local cluster_scope_tag=""
  local create_resp=""
  local create_upid=""
  local start_resp=""
  local start_upid=""
  local talos_iso_file="talos-${PINNED_TALOS_VERSION}.iso"
  local proxmox_dns_servers=""

  if [[ -n "${TWINBOX_CLUSTER_SLUG:-}" ]]; then
    cluster_scope_tag=";cluster-${TWINBOX_CLUSTER_SLUG}"
  fi
  proxmox_dns_servers=$(printf '%s' "$DNS_SERVERS" | tr ',' ' ' | xargs)

  create_resp=$(task_post "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu" \
    --data-urlencode "vmid=${vmid}" \
    --data-urlencode "name=${name}" \
    --data-urlencode "memory=${MEMORY_MB}" \
    --data-urlencode "cores=${CPU_CORES}" \
    --data-urlencode "cpu=host" \
    --data-urlencode "agent=1" \
    --data-urlencode "tags=twinbox;talos;${role_tag};cluster-${CLUSTER_ID}${cluster_scope_tag}" \
    --data-urlencode "net0=virtio,bridge=${BRIDGE}" \
    --data-urlencode "ipconfig0=ip=${ip}/${NODE_PREFIX_LENGTH},gw=${GATEWAY_IP}" \
    --data-urlencode "nameserver=${proxmox_dns_servers}" \
    --data-urlencode "searchdomain=${DNS_DOMAIN}" \
    --data-urlencode "cicustom=user=${PINNED_PROXMOX_ISO_STORAGE}:snippets/${snippet_name}" \
    --data-urlencode "scsihw=virtio-scsi-pci" \
    --data-urlencode "scsi0=${STORAGE_POOL}:${DISK_GB}" \
    --data-urlencode "ide2=${PINNED_PROXMOX_ISO_STORAGE}:iso/${talos_iso_file},media=cdrom" \
    --data-urlencode "ide3=${PINNED_PROXMOX_ISO_STORAGE}:cloudinit" \
    --data-urlencode "boot=order=scsi0;ide2" \
    --data-urlencode "ostype=l26")
  create_upid=$(echo "$create_resp" | jq -r '.data // empty')
  [[ -n "$create_upid" ]] || fail "Missing create task UPID for VM ${vmid}"
  wait_for_task_completion "$create_upid"

  start_resp=$(task_post "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/start")
  start_upid=$(echo "$start_resp" | jq -r '.data // empty')
  [[ -n "$start_upid" ]] || fail "Missing start task UPID for VM ${vmid}"
  wait_for_task_completion "$start_upid"
}

cp_ids=()
worker_ids=()
cp_ips=()
worker_ips=()
vm_base_name="${NAME}"

if [[ "$vm_base_name" != twinbox-* ]]; then
  vm_base_name="twinbox-${vm_base_name}"
fi

generate_talos_configs
upload_talos_snippet "$CONTROLPLANE_SNIPPET_NAME"
upload_talos_snippet "$WORKER_SNIPPET_NAME"

current_vmid="$START_VMID"
for i in $(seq 1 "$CP_COUNT"); do
  vm_name="${vm_base_name}-cp-${i}"
  ip=$(next_ip $((i - 1)))
  create_vm "$current_vmid" "$vm_name" "controlplane" "$ip" "$CONTROLPLANE_SNIPPET_NAME"
  cp_ids+=("$current_vmid")
  cp_ips+=("$ip")
  current_vmid=$((current_vmid + 1))
  log "Created controlplane VM ${vm_name} (${ip})"
done

for i in $(seq 1 "$WORKER_COUNT"); do
  vm_name="${vm_base_name}-worker-${i}"
  ip=$(next_ip $((CP_COUNT + i - 1)))
  create_vm "$current_vmid" "$vm_name" "worker" "$ip" "$WORKER_SNIPPET_NAME"
  worker_ids+=("$current_vmid")
  worker_ips+=("$ip")
  current_vmid=$((current_vmid + 1))
  log "Created worker VM ${vm_name} (${ip})"
done

if [[ -f "$cluster_file" ]]; then
  tmp=$(mktemp)
  jq \
    --argjson cp_ids "$(printf '%s\n' "${cp_ids[@]}" | jq -R . | jq -s .)" \
    --argjson worker_ids "$(printf '%s\n' "${worker_ids[@]}" | jq -R . | jq -s .)" \
    --argjson cp_ips "$(printf '%s\n' "${cp_ips[@]}" | jq -R . | jq -s .)" \
    --argjson worker_ips "$(printf '%s\n' "${worker_ips[@]}" | jq -R . | jq -s .)" \
    --arg vip "$VIP_IP" \
    --arg talos_dir "$talos_dir" \
    --arg cp_snippet "$CONTROLPLANE_SNIPPET_NAME" \
    --arg worker_snippet "$WORKER_SNIPPET_NAME" \
    '.status = "provisioned" | .updated_at = now | .controlplane_vm_ids=$cp_ids | .worker_vm_ids=$worker_ids | .controlplane_ips=$cp_ips | .worker_ips=$worker_ips | .vip_ip=$vip | .talos_config_dir=$talos_dir | .talos_snippets={controlplane:$cp_snippet,worker:$worker_snippet}' \
    "$cluster_file" > "$tmp"
  mv "$tmp" "$cluster_file"
fi

log "Cluster provisioning finished"
