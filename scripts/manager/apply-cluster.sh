#!/bin/bash
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --controlplane-count N --worker-count N --cpu-cores N --memory-mb N --disk-gb N --bridge BR --start-vmid ID --start-ip IP --vip-ip IP --node-prefix-length N --gateway-ip IP --dns-servers CSV --dns-domain NAME --proxmox-node NODE --storage-pool POOL --file-datastore STORE --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
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
command -v curl >/dev/null 2>&1 || fail "curl not found"
TOFU_BIN="${TOFU_BIN:-tofu}"
command -v "$TOFU_BIN" >/dev/null 2>&1 || fail "tofu not found"
command -v talosctl >/dev/null 2>&1 || fail "talosctl not found"
export TF_IN_AUTOMATION=1
export NO_COLOR=1

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

INSTALL_DISK="${INSTALL_DISK:-/dev/vda}"

clusters_dir="$DATA_DIR/clusters"
cluster_dir="$clusters_dir/$CLUSTER_ID"
cluster_file="$clusters_dir/${CLUSTER_ID}.json"
iac_dir="$cluster_dir/iac"
work_module_dir="$iac_dir/module"
tfvars_file="$work_module_dir/cluster.auto.tfvars.json"
kubeconfig_file="$cluster_dir/kubeconfig"
talos_dir="$cluster_dir/talos"

mkdir -p "$clusters_dir" "$cluster_dir" "$iac_dir" "$talos_dir"
[[ -f "$cluster_file" ]] || fail "cluster not found: ${CLUSTER_ID}"

on_error() {
  local status=$?
  if [[ -f "$cluster_file" ]]; then
    local tmp=""
    tmp="$(mktemp)"
    jq \
      --arg status "failed" \
      --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --arg last_error "apply_cluster failed" \
      '.status = $status | .updated_at = $updated_at | .last_error = $last_error' \
      "$cluster_file" > "$tmp"
    mv "$tmp" "$cluster_file"
  fi
  exit "$status"
}

trap on_error ERR

resolve_talos_image_assets() {
  image_arch="${TALOS_IMAGE_ARCH:-$PINNED_TALOS_IMAGE_ARCH}"
  image_platform="${TALOS_IMAGE_PLATFORM:-$PINNED_TALOS_IMAGE_PLATFORM}"

  local talos_image_preset="${TALOS_IMAGE_PRESET:-qemu-guest-agent}"
  local helper_output=""
  local line=""
  helper_output="$("$WORKSPACE_ROOT/scripts/get-talos-image-factory.sh" \
    --preset "$talos_image_preset" \
    --version "$PINNED_TALOS_VERSION" \
    --arch "$image_arch" \
    --platform "$image_platform" \
    --output shell)"
  while IFS= read -r line; do
    case "$line" in
      TALOS_IMAGE_SCHEMATIC=*)
        image_schematic="${line#TALOS_IMAGE_SCHEMATIC=}"
        ;;
      TALOS_IMAGE_FACTORY_URL=*)
        image_factory_url="${line#TALOS_IMAGE_FACTORY_URL=}"
        ;;
      TALOS_IMAGE_DOWNLOAD_URL=*)
        image_download_url="${line#TALOS_IMAGE_DOWNLOAD_URL=}"
        ;;
    esac
  done <<<"$helper_output"

  image_cache_key="${image_platform}-${image_arch}-${image_schematic}-${PINNED_TALOS_VERSION}"
}

resolve_talos_image_assets

download_talos_image() {
  local target_path="$1"
  local tmp_compressed=""

  [[ -n "${image_download_url:-}" ]] || fail "Talos download URL not resolved"

  if [[ -s "$target_path" ]]; then
    log "Reusing cached Talos image at ${target_path}"
    talos_image_local_path="$target_path"
    return 0
  fi

  tmp_compressed="$(mktemp "$talos_dir/.talos-image.XXXXXX.iso")"
  log "Downloading Talos ISO to ${target_path}"
  curl -fsSL --retry 3 --retry-delay 2 --output "$tmp_compressed" "$image_download_url"
  mv "$tmp_compressed" "$target_path"
  talos_image_local_path="$target_path"
}

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
  local i=""
  local ip=""
  local name=""
  local mac=""

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

node_array() {
  local field="$1"
  local type="$2"
  jq -c --arg type "$type" --arg field "$field" '
    to_entries
    | sort_by(.key)
    | map(select(.value.type == $type) | .value[$field])
  ' <<<"$nodes_json"
}

json_array_from_args() {
  jq -nc '$ARGS.positional' --args "$@"
}

flatten_ipv4_candidates() {
  jq -r '
    flatten
    | .[]
    | select(type == "string")
    | select(length > 0)
    | select(startswith("127.") | not)
    | select(startswith("169.254.") | not)
  '
}

update_cluster_file() {
  local status="$1"
  local planned_controlplane_ips="$2"
  local planned_worker_ips="$3"
  local discovered_controlplane_ips="$4"
  local discovered_worker_ips="$5"
  local controlplane_vm_ids="$6"
  local worker_vm_ids="$7"
  local talos_dir_value="$8"
  local kubeconfig_value="$9"
  local tmp=""

  tmp="$(mktemp)"
  jq \
    --arg status "$status" \
    --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson planned_controlplane_ips "$planned_controlplane_ips" \
    --argjson planned_worker_ips "$planned_worker_ips" \
    --argjson discovered_controlplane_ips "$discovered_controlplane_ips" \
    --argjson discovered_worker_ips "$discovered_worker_ips" \
    --argjson controlplane_vm_ids "$controlplane_vm_ids" \
    --argjson worker_vm_ids "$worker_vm_ids" \
    --arg talos_dir "$talos_dir_value" \
    --arg kubeconfig_path "$kubeconfig_value" \
    --argjson controlplane_ips "$discovered_controlplane_ips" \
    --argjson worker_ips "$discovered_worker_ips" \
    '
      .status = $status
      | .updated_at = $updated_at
      | .planned_controlplane_ips = $planned_controlplane_ips
      | .planned_worker_ips = $planned_worker_ips
      | .discovered_controlplane_ips = $discovered_controlplane_ips
      | .discovered_worker_ips = $discovered_worker_ips
      | .controlplane_ips = $controlplane_ips
      | .worker_ips = $worker_ips
      | .controlplane_vm_ids = $controlplane_vm_ids
      | .worker_vm_ids = $worker_vm_ids
      | .bootstrap_mode = "dhcp-first"
      | .talos_config_dir = $talos_dir
      | .talosconfig_path = ($talos_dir + "/talosconfig")
      | .kubeconfig_path = $kubeconfig_path
      | del(.last_error)
    ' "$cluster_file" > "$tmp"
  mv "$tmp" "$cluster_file"
}

discover_node_ip() {
  local label="$1"
  shift
  local candidates=("$@")
  local candidate=""
  local attempts=60

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    log "Guest agent reported ${label} at ${candidate}"
    printf '%s\n' "$candidate"
    return 0
  done

  while [[ "$attempts" -gt 0 ]]; do
    for candidate in "${candidates[@]}"; do
      [[ -n "$candidate" ]] || continue
      if talosctl version --insecure --nodes "$candidate" >/dev/null 2>&1; then
        log "Discovered ${label} at ${candidate}"
        printf '%s\n' "$candidate"
        return 0
      fi
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
      break
    fi
    sleep 5
    attempts=$((attempts - 1))
  done

  fail "Timed out waiting for ${label} to answer on ${candidate}"
}

wait_for_talos_api() {
  local label="$1"
  local candidate="$2"
  local attempts=60

  while [[ "$attempts" -gt 0 ]]; do
    if talosctl version \
      --nodes "$candidate" \
      --endpoints "$candidate" \
      --talosconfig "$talos_dir/talosconfig" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    attempts=$((attempts - 1))
  done

  fail "Timed out waiting for Talos API on ${label} at ${candidate}"
}

write_node_patch() {
  local name="$1"
  local type="$2"
  local mac="$3"
  local patch_file="$4"
  local nameserver_block=""
  local search_domain_block=""

  if [[ -n "${DNS_SERVERS:-}" ]]; then
    IFS=',' read -r -a dns_servers_array <<< "$DNS_SERVERS"
    if [[ ${#dns_servers_array[@]} -gt 0 ]]; then
      nameserver_block=$'    nameservers:\n'
      for server in "${dns_servers_array[@]}"; do
        server="${server//[[:space:]]/}"
        [[ -n "$server" ]] || continue
        nameserver_block+=$'      - '"$server"$'\n'
      done
    fi
  fi

  if [[ -n "${DNS_DOMAIN:-}" ]]; then
    search_domain_block=$'    searchDomains:\n      - '"$DNS_DOMAIN"$'\n'
  fi

  {
    echo "machine:"
    echo "  network:"
    [[ -n "$nameserver_block" ]] && printf '%s' "$nameserver_block"
    [[ -n "$search_domain_block" ]] && printf '%s' "$search_domain_block"
    echo "    interfaces:"
    echo "      - deviceSelector:"
    echo "          hardwareAddr: ${mac}"
    echo "        dhcp: true"
    if [[ "$type" == "controlplane" ]]; then
      echo "        vip:"
      echo "          ip: ${VIP_IP}"
    fi
  } > "$patch_file"
}

generate_talos_configs() {
  local base_dir="$talos_dir/base"
  local node_dir=""
  local patch_file=""
  local name=""
  local type=""
  local mac=""
  local config_file=""

  rm -rf "$talos_dir/base" "$talos_dir/generated"
  mkdir -p "$base_dir" "$talos_dir/generated"

  if [[ -s "$talos_dir/secrets.yaml" ]]; then
    log "Reusing Talos secrets at ${talos_dir}/secrets.yaml"
  else
    log "Generating Talos secrets"
    talosctl gen secrets -o "$talos_dir/secrets.yaml"
  fi

  log "Generating base Talos config"
  talosctl gen config "$NAME" "https://${VIP_IP}:6443" \
    --output-dir "$base_dir" \
    --with-secrets "$talos_dir/secrets.yaml" \
    --install-disk "$INSTALL_DISK"

  cp "$base_dir/talosconfig" "$talos_dir/talosconfig"

  while IFS=$'\t' read -r name type mac; do
    [[ -n "$name" ]] || continue
    node_dir="$talos_dir/generated/$name"
    patch_file="$node_dir/patch.yaml"
    mkdir -p "$node_dir"
    write_node_patch "$name" "$type" "$mac" "$patch_file"

    log "Generating Talos config for ${name}"
    if [[ "$type" == "controlplane" ]]; then
      talosctl gen config "$NAME" "https://${VIP_IP}:6443" \
        --output-dir "$node_dir" \
        --with-secrets "$talos_dir/secrets.yaml" \
        --install-disk "$INSTALL_DISK" \
        --config-patch-control-plane "@${patch_file}"
      config_file="$talos_dir/${name}-controlplane.yaml"
      cp "$node_dir/controlplane.yaml" "$config_file"
    else
      talosctl gen config "$NAME" "https://${VIP_IP}:6443" \
        --output-dir "$node_dir" \
        --with-secrets "$talos_dir/secrets.yaml" \
        --install-disk "$INSTALL_DISK" \
        --config-patch-worker "@${patch_file}"
      config_file="$talos_dir/${name}-worker.yaml"
      cp "$node_dir/worker.yaml" "$config_file"
    fi
  done < <(jq -r '
      to_entries
      | sort_by(.key)
      | .[]
      | [.key, .value.type, .value.mac]
      | @tsv
    ' <<<"$nodes_json")
}

apply_node_config() {
  local ip="$1"
  local config_file="$2"
  log "Applying Talos config to ${ip}"
  talosctl apply-config \
    --insecure \
    --nodes "$ip" \
    --talosconfig "$talos_dir/talosconfig" \
    --file "$config_file"
}

bootstrap_cluster() {
  local first_cp_ip="$1"
  wait_for_talos_api "control plane" "$first_cp_ip"
  log "Bootstrapping cluster from ${first_cp_ip}"
  talosctl bootstrap \
    --nodes "$first_cp_ip" \
    --endpoints "$first_cp_ip" \
    --talosconfig "$talos_dir/talosconfig"

  log "Writing kubeconfig"
  talosctl kubeconfig "$kubeconfig_file" \
    --nodes "$first_cp_ip" \
    --endpoints "$first_cp_ip" \
    --talosconfig "$talos_dir/talosconfig" \
    --force
}

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

  # Update node/endpoint as the mapped user (using sudo if we are root)
  if [[ "$(id -u)" -eq 0 ]]; then
    sudo -u "#${owner_uid}" -g "#${owner_gid}" talosctl config node "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null
    sudo -u "#${owner_uid}" -g "#${owner_gid}" talosctl config endpoint "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null
  else
    talosctl config node "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null
    talosctl config endpoint "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null
  fi
  log "Copied talosconfig to ${target_talosconfig}"
}

talos_image_local_path="$talos_dir/talos-${image_cache_key}.iso"
download_talos_image "$talos_image_local_path"

nodes_json="$(generate_nodes_json)"
planned_controlplane_ips_json="$(node_array "ip" "controlplane")"
planned_worker_ips_json="$(node_array "ip" "worker")"
controlplane_vm_ids_json="$(node_array "vmid" "controlplane")"
worker_vm_ids_json="$(node_array "vmid" "worker")"

if [[ -f "$work_module_dir/terraform.tfstate" ]]; then
  log "Reusing existing OpenTofu workspace at ${work_module_dir}"
else
  rm -rf "$work_module_dir"
  mkdir -p "$work_module_dir"
fi
cp -R "$MODULE_SOURCE/." "$work_module_dir/"

jq -n \
  --arg proxmox_endpoint "https://${PROXMOX_HOST}:${PROXMOX_PORT}" \
  --arg proxmox_username "$PROXMOX_USER" \
  --arg proxmox_password "$PROXMOX_PASSWORD" \
  --arg proxmox_node "$PROXMOX_NODE" \
  --arg vm_datastore "$STORAGE_POOL" \
  --arg file_datastore "$FILE_DATASTORE" \
  --arg bridge "$BRIDGE" \
  --arg gateway "$GATEWAY_IP" \
  --arg cluster_name "$NAME" \
  --arg cluster_slug "$CLUSTER_ID" \
  --arg cluster_endpoint "https://${VIP_IP}:6443" \
  --arg vip_ip "$VIP_IP" \
  --arg talos_version "$PINNED_TALOS_VERSION" \
  --arg talos_image_local_path "$talos_image_local_path" \
  --arg talos_image_cache_key "$image_cache_key" \
  --argjson dns_servers "$(printf '%s' "$DNS_SERVERS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')" \
  --argjson prefix "$NODE_PREFIX_LENGTH" \
  --argjson nodes "$nodes_json" \
  '{
    proxmox_endpoint: $proxmox_endpoint,
    proxmox_username: $proxmox_username,
    proxmox_password: $proxmox_password,
    proxmox_node: $proxmox_node,
    vm_datastore: $vm_datastore,
    file_datastore: $file_datastore,
    bridge: $bridge,
    gateway: $gateway,
    dns_servers: $dns_servers,
    prefix: $prefix,
    cluster_name: $cluster_name,
    cluster_slug: $cluster_slug,
    cluster_endpoint: $cluster_endpoint,
    vip_ip: $vip_ip,
    talos_version: $talos_version,
    talos_image_local_path: $talos_image_local_path,
    talos_image_cache_key: $talos_image_cache_key,
    install_disk: "'"$INSTALL_DISK"'",
    nodes: $nodes
  }' > "$tfvars_file"

log "Preparing OpenTofu module"
"$TOFU_BIN" -chdir="$work_module_dir" init -input=false -no-color
log "Creating Proxmox VMs"
"$TOFU_BIN" -chdir="$work_module_dir" apply -input=false -auto-approve -no-color -var-file="$tfvars_file"

tf_outputs_json="$("$TOFU_BIN" -chdir="$work_module_dir" output -json -no-color)"
controlplane_ipv4_candidates_json="$(jq -c '.controlplane_ipv4_addresses.value // []' <<<"$tf_outputs_json")"
worker_ipv4_candidates_json="$(jq -c '.worker_ipv4_addresses.value // []' <<<"$tf_outputs_json")"

update_cluster_file "provisioned" "$planned_controlplane_ips_json" "$planned_worker_ips_json" "[]" "[]" "$controlplane_vm_ids_json" "$worker_vm_ids_json" "$talos_dir" ""

log "Discovering DHCP addresses"
discovered_controlplane_ips_json="[]"
discovered_worker_ips_json="[]"
discovered_controlplane_ips=()
discovered_worker_ips=()
mapfile -t controlplane_actual_candidates < <(jq -r 'flatten | .[] | select(type == "string") | select(length > 0) | select(startswith("127.") | not) | select(startswith("169.254.") | not)' <<<"$controlplane_ipv4_candidates_json")
mapfile -t worker_actual_candidates < <(jq -r 'flatten | .[] | select(type == "string") | select(length > 0) | select(startswith("127.") | not) | select(startswith("169.254.") | not)' <<<"$worker_ipv4_candidates_json")
controlplane_index=0
worker_index=0

while IFS=$'\t' read -r name type ip; do
  [[ -n "$name" ]] || continue
  if [[ "$type" == "controlplane" ]]; then
    candidates=()
    if [[ -n "${controlplane_actual_candidates[$controlplane_index]:-}" ]]; then
      candidates+=("${controlplane_actual_candidates[$controlplane_index]}")
    fi
    candidates+=("$ip")
    discovered_ip="$(discover_node_ip "$name" "${candidates[@]}")"
    controlplane_index=$((controlplane_index + 1))
    discovered_controlplane_ips+=("$discovered_ip")
  else
    candidates=()
    if [[ -n "${worker_actual_candidates[$worker_index]:-}" ]]; then
      candidates+=("${worker_actual_candidates[$worker_index]}")
    fi
    candidates+=("$ip")
    discovered_ip="$(discover_node_ip "$name" "${candidates[@]}")"
    worker_index=$((worker_index + 1))
    discovered_worker_ips+=("$discovered_ip")
  fi
done < <(jq -r '
    to_entries
    | sort_by(.key)
    | .[]
    | [.key, .value.type, .value.ip]
    | @tsv
  ' <<<"$nodes_json")

discovered_controlplane_ips_json="$(json_array_from_args "${discovered_controlplane_ips[@]}")"
discovered_worker_ips_json="$(json_array_from_args "${discovered_worker_ips[@]}")"

generate_talos_configs

controlplane_apply_index=0
worker_apply_index=0
while IFS=$'\t' read -r name type ip; do
  [[ -n "$name" ]] || continue
  if [[ "$type" == "controlplane" ]]; then
    discovered_ip="${discovered_controlplane_ips[$controlplane_apply_index]:-$ip}"
    apply_node_config "$discovered_ip" "$talos_dir/${name}-controlplane.yaml"
    controlplane_apply_index=$((controlplane_apply_index + 1))
  else
    discovered_ip="${discovered_worker_ips[$worker_apply_index]:-$ip}"
    apply_node_config "$discovered_ip" "$talos_dir/${name}-worker.yaml"
    worker_apply_index=$((worker_apply_index + 1))
  fi
done < <(jq -r '
    to_entries
    | sort_by(.key)
    | .[]
    | [.key, .value.type, .value.ip]
    | @tsv
  ' <<<"$nodes_json")

first_controlplane_ip="${discovered_controlplane_ips[0]:-}"
[[ -n "$first_controlplane_ip" ]] || fail "No control plane IP discovered"

bootstrap_cluster "$first_controlplane_ip"
sync_user_talosconfig "$talos_dir/talosconfig" "$first_controlplane_ip"
sync_user_kubeconfig "$kubeconfig_file"

tmp="$(mktemp)"
jq \
  --arg status "bootstrapped" \
  --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson planned_controlplane_ips "$planned_controlplane_ips_json" \
  --argjson planned_worker_ips "$planned_worker_ips_json" \
  --argjson discovered_controlplane_ips "$discovered_controlplane_ips_json" \
  --argjson discovered_worker_ips "$discovered_worker_ips_json" \
  --argjson controlplane_vm_ids "$controlplane_vm_ids_json" \
  --argjson worker_vm_ids "$worker_vm_ids_json" \
  --arg talos_dir "$talos_dir" \
  --arg kubeconfig_path "$kubeconfig_file" \
  '
    .status = $status
    | .updated_at = $updated_at
    | .planned_controlplane_ips = $planned_controlplane_ips
    | .planned_worker_ips = $planned_worker_ips
    | .discovered_controlplane_ips = $discovered_controlplane_ips
    | .discovered_worker_ips = $discovered_worker_ips
    | .controlplane_ips = $discovered_controlplane_ips
    | .worker_ips = $discovered_worker_ips
    | .controlplane_vm_ids = $controlplane_vm_ids
    | .worker_vm_ids = $worker_vm_ids
    | .bootstrap_mode = "dhcp-first"
    | .talos_config_dir = $talos_dir
    | .talosconfig_path = ($talos_dir + "/talosconfig")
    | .kubeconfig_path = $kubeconfig_path
    | del(.last_error)
  ' "$cluster_file" > "$tmp"
mv "$tmp" "$cluster_file"

log "Cluster provisioning finished"
