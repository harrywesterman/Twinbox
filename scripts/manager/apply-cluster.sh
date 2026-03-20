#!/bin/bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --controlplane-count N --worker-count N --cpu-cores N --memory-mb N --disk-gb N --bridge BR --start-vmid ID --start-ip IP --vip-ip IP --node-prefix-length N --gateway-ip IP --dns-servers CSV --dns-domain NAME --proxmox-node NODE --storage-pool POOL --file-datastore STORE --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODULE_SOURCE="$WORKSPACE_ROOT/infra/opentofu/talos-proxmox"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

required_env=(PROXMOX_HOST PROXMOX_PORT PROXMOX_USER PROXMOX_PASSWORD)
for var in "${required_env[@]}"; do
  [[ -n "${!var:-}" ]] || fail "Missing environment variable: $var"
done

command -v jq >/dev/null 2>&1 || fail "jq not found"
TOFU_BIN="${TOFU_BIN:-tofu}"
command -v "$TOFU_BIN" >/dev/null 2>&1 || fail "tofu not found"

update_cluster_status() {
  local status="$1"
  local extra_filter="${2:-.}"
  local tmp=""

  [[ -f "$cluster_file" ]] || return 0
  tmp="$(mktemp)"
  jq --arg status "$status" --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    ".status = \$status | .updated_at = \$updated_at | ${extra_filter}" "$cluster_file" > "$tmp"
  mv "$tmp" "$cluster_file"
}

on_error() {
  local status=$?
  update_cluster_status "failed" ".last_error = \"apply_cluster failed\""
  exit "$status"
}

trap on_error ERR

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
    --file-datastore) FILE_DATASTORE="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "${CLUSTER_ID:-}" ]] || { usage; fail "cluster-id required"; }

clusters_dir="$DATA_DIR/clusters"
cluster_dir="$clusters_dir/$CLUSTER_ID"
cluster_file="$clusters_dir/${CLUSTER_ID}.json"
iac_dir="$cluster_dir/iac"
work_module_dir="$iac_dir/module"
tfvars_file="$iac_dir/cluster.auto.tfvars.json"
outputs_file="$iac_dir/outputs.json"
kubeconfig_file="$cluster_dir/kubeconfig"

mkdir -p "$clusters_dir" "$cluster_dir" "$iac_dir"
[[ -f "$cluster_file" ]] || fail "cluster not found: ${CLUSTER_ID}"

image_schematic="${TALOS_IMAGE_SCHEMATIC:-$PINNED_TALOS_IMAGE_SCHEMATIC}"
image_arch="${TALOS_IMAGE_ARCH:-$PINNED_TALOS_IMAGE_ARCH}"
image_platform="${TALOS_IMAGE_PLATFORM:-$PINNED_TALOS_IMAGE_PLATFORM}"
image_url="${TALOS_IMAGE_FACTORY_URL:-https://factory.talos.dev/image/${image_schematic}/${PINNED_TALOS_VERSION}/nocloud-${image_arch}.raw.xz}"
image_cache_key="${image_platform}-${image_arch}-${image_schematic}-${PINNED_TALOS_VERSION}"

next_ip() {
  local base octet
  base=$(echo "$START_IP" | cut -d. -f1-3)
  octet=$(echo "$START_IP" | cut -d. -f4)
  echo "$base.$((octet + $1))"
}

deterministic_mac() {
  local vmid="$1"
  printf '52:54:%02x:%02x:%02x:%02x\n' \
    $(( (vmid >> 24) & 255 )) \
    $(( (vmid >> 16) & 255 )) \
    $(( (vmid >> 8) & 255 )) \
    $(( vmid & 255 ))
}

generate_nodes_json() {
  local nodes_json="{}"
  local current_vmid="$START_VMID"
  local ip=""
  local name=""
  local mac=""
  local i=""

  for i in $(seq 1 "$CP_COUNT"); do
    name="cp-${i}"
    ip="$(next_ip $((i - 1)))"
    mac="$(deterministic_mac "$current_vmid")"
    nodes_json="$(jq \
      --arg key "$name" \
      --arg ip "$ip" \
      --arg type "controlplane" \
      --arg mac "$mac" \
      --argjson vmid "$current_vmid" \
      --argjson cpu "$CPU_CORES" \
      --argjson ram "$MEMORY_MB" \
      --argjson disk "$DISK_GB" \
      '. + {($key): {ip: $ip, type: $type, vmid: $vmid, cpu: $cpu, ram_mb: $ram, disk_gb: $disk, mac: $mac}}' \
      <<<"$nodes_json")"
    current_vmid=$((current_vmid + 1))
  done

  for i in $(seq 1 "$WORKER_COUNT"); do
    name="worker-${i}"
    ip="$(next_ip $((CP_COUNT + i - 1)))"
    mac="$(deterministic_mac "$current_vmid")"
    nodes_json="$(jq \
      --arg key "$name" \
      --arg ip "$ip" \
      --arg type "worker" \
      --arg mac "$mac" \
      --argjson vmid "$current_vmid" \
      --argjson cpu "$CPU_CORES" \
      --argjson ram "$MEMORY_MB" \
      --argjson disk "$DISK_GB" \
      '. + {($key): {ip: $ip, type: $type, vmid: $vmid, cpu: $cpu, ram_mb: $ram, disk_gb: $disk, mac: $mac}}' \
      <<<"$nodes_json")"
    current_vmid=$((current_vmid + 1))
  done

  printf '%s\n' "$nodes_json"
}

log "Resolving Talos image"
nodes_json="$(generate_nodes_json)"
dns_servers_json="$(printf '%s' "$DNS_SERVERS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"

rm -rf "$work_module_dir"
mkdir -p "$work_module_dir"
cp -R "$MODULE_SOURCE/." "$work_module_dir/"

cat > "$tfvars_file" <<EOF
{
  "proxmox_endpoint": "https://${PROXMOX_HOST}:${PROXMOX_PORT}",
  "proxmox_username": ${PROXMOX_USER@Q},
  "proxmox_password": ${PROXMOX_PASSWORD@Q},
  "proxmox_node": ${PROXMOX_NODE@Q},
  "vm_datastore": ${STORAGE_POOL@Q},
  "file_datastore": ${FILE_DATASTORE@Q},
  "bridge": ${BRIDGE@Q},
  "gateway": ${GATEWAY_IP@Q},
  "dns_servers": ${dns_servers_json},
  "prefix": ${NODE_PREFIX_LENGTH},
  "cluster_name": ${NAME@Q},
  "cluster_slug": ${CLUSTER_ID@Q},
  "cluster_endpoint": "https://${VIP_IP}:6443",
  "vip_ip": ${VIP_IP@Q},
  "talos_version": ${PINNED_TALOS_VERSION@Q},
  "talos_image_url": ${image_url@Q},
  "talos_image_cache_key": ${image_cache_key@Q},
  "nodes": ${nodes_json}
}
EOF

update_cluster_status "applying" \
  ".iac = {
      workdir: \"$work_module_dir\",
      state_path: \"$work_module_dir/terraform.tfstate\",
      tfvars_path: \"$tfvars_file\",
      outputs_path: \"$outputs_file\",
      image_cache_key: \"$image_cache_key\",
      image_url: \"$image_url\"
    } | del(.last_error)"

export TF_IN_AUTOMATION=1
export TF_DATA_DIR="$iac_dir/.terraform"

pushd "$work_module_dir" >/dev/null
log "Preparing OpenTofu module"
"$TOFU_BIN" init -input=false
log "Generating NoCloud artifacts"
log "Applying OpenTofu cluster plan"
"$TOFU_BIN" apply -input=false -auto-approve
log "Collecting OpenTofu outputs"
"$TOFU_BIN" output -json > "$outputs_file"
popd >/dev/null

jq -r '.kubeconfig.value // empty' "$outputs_file" > "$kubeconfig_file"

update_cluster_status "bootstrapped" \
  ".controlplane_ips = (.controlplane_ips // []) |
   .worker_ips = (.worker_ips // []) |
   .controlplane_vm_ids = (.controlplane_vm_ids // []) |
   .worker_vm_ids = (.worker_vm_ids // []) |
   .controlplane_ips = ($(jq -c '.controlplane_ips.value // []' "$outputs_file")) |
   .worker_ips = ($(jq -c '.worker_ips.value // []' "$outputs_file")) |
   .controlplane_vm_ids = ($(jq -c '.controlplane_vm_ids.value // []' "$outputs_file")) |
   .worker_vm_ids = ($(jq -c '.worker_vm_ids.value // []' "$outputs_file")) |
   .vip_ip = ($(jq -r '.vip_ip.value // empty' "$outputs_file" | jq -R '.')) |
   .kubeconfig_path = \"$kubeconfig_file\" |
   .iac = (.iac + {
      module_path: \"$MODULE_SOURCE\"
    })"

log "Fetching kubeconfig"
log "Cluster apply completed"
