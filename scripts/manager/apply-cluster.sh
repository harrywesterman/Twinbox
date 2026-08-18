#!/bin/bash
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --name NAME --controlplane-count N --worker-count N --cpu-cores N --memory-mb N --bridge BR --start-vmid ID --start-ip IP --vip-ip IP --node-prefix-length N --gateway-ip IP --dns-servers CSV --dns-domain NAME --vm-node-map JSON --vm-size-map JSON --vm-storage-map JSON --vm-ip-map JSON --proxmox-node NODE --storage-pool POOL --file-datastore STORE --data-dir DIR
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
array_contains() {
  local needle="$1"
  shift || true
  local item=""

  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done

  return 1
}

file_size_bytes() {
  local path="$1"

  stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODULE_SOURCE="$WORKSPACE_ROOT/infra/opentofu/talos-proxmox"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

required_env=(PROXMOX_HOST PROXMOX_PORT PROXMOX_USER)
for var in "${required_env[@]}"; do
  [[ -n "${!var:-}" ]] || fail "Missing environment variable: $var"
done

export TF_VAR_proxmox_endpoint="${TF_VAR_proxmox_endpoint:-https://${PROXMOX_HOST}:${PROXMOX_PORT}}"
export TF_VAR_proxmox_username="${TF_VAR_proxmox_username:-$PROXMOX_USER}"
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-${TF_VAR_proxmox_password:-}}"
[[ -n "${PROXMOX_PASSWORD:-}" ]] || fail "Missing environment variable: PROXMOX_PASSWORD or TF_VAR_proxmox_password"
export PROXMOX_PASSWORD

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v xz >/dev/null 2>&1 || fail "xz not found"
TOFU_BIN="${TOFU_BIN:-tofu}"
command -v "$TOFU_BIN" >/dev/null 2>&1 || fail "tofu not found"
command -v talosctl >/dev/null 2>&1 || fail "talosctl not found"
NODE_BIN="${NODE_BIN:-node}"
command -v "$NODE_BIN" >/dev/null 2>&1 || fail "node not found"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v helm >/dev/null 2>&1 || fail "helm not found"
export TF_IN_AUTOMATION=1
export NO_COLOR=1
TOFU_PARALLELISM="${TOFU_PARALLELISM:-1}"
PROXMOX_UPLOAD_MAX_ATTEMPTS="${PROXMOX_UPLOAD_MAX_ATTEMPTS:-5}"
# Proxmox may report a successful upload before the imported raw image has
# finished being written to its storage backend. Keep polling long enough for
# the slowest supported node instead of treating that in-progress write as a
# corrupt import. This permits just over three minutes of settling time.
PROXMOX_VERIFY_MAX_ATTEMPTS="${PROXMOX_VERIFY_MAX_ATTEMPTS:-24}"
PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES="${PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES:-1073741824}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --controlplane-count) CP_COUNT="$2"; shift 2 ;;
    --worker-count) WORKER_COUNT="$2"; shift 2 ;;
    --cpu-cores) CPU_CORES="$2"; shift 2 ;;
    --memory-mb) MEMORY_MB="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --start-vmid) START_VMID="$2"; shift 2 ;;
    --start-ip) START_IP="$2"; shift 2 ;;
    --vip-ip) VIP_IP="$2"; shift 2 ;;
    --node-prefix-length) NODE_PREFIX_LENGTH="$2"; shift 2 ;;
    --gateway-ip) GATEWAY_IP="$2"; shift 2 ;;
    --dns-servers) DNS_SERVERS="$2"; shift 2 ;;
    --dns-domain) DNS_DOMAIN="$2"; shift 2 ;;
    # --vm-node-map) shift 2 ;;
    --vm-node-map) VM_NODE_MAP="$2"; shift 2 ;;
    --vm-size-map) VM_SIZE_MAP="$2"; shift 2 ;;
    --vm-storage-map) VM_STORAGE_MAP="$2"; shift 2 ;;
    --vm-ip-map) VM_IP_MAP="$2"; shift 2 ;;
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
image_cache_dir="$cluster_dir/cache"
runtime_secret_root="${TWINBOX_SECRET_TEMP_DIR:-/tmp/twinbox-secrets}"
mkdir -p "$runtime_secret_root"
talos_runtime_root="$(mktemp -d "${runtime_secret_root%/}/talos-${CLUSTER_ID}-XXXXXX")"
runtime_talos_dir="$talos_runtime_root/talos"
talos_secrets_file="${TWINBOX_TALOS_SECRETS_FILE:-$runtime_talos_dir/secrets.yaml}"
talosconfig_file="${TWINBOX_TALOSCONFIG_FILE:-$runtime_talos_dir/talosconfig}"
kubeconfig_file="${TWINBOX_KUBECONFIG_FILE:-$runtime_talos_dir/kubeconfig}"
bootstrap_secret_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/cluster/${CLUSTER_ID}"

mkdir -p "$clusters_dir" "$cluster_dir" "$iac_dir" "$image_cache_dir" "$runtime_talos_dir"
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

cleanup_runtime() {
  rm -rf "$talos_runtime_root"
}

trap cleanup_runtime EXIT

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
      TALOS_IMAGE_INSTALLER=*)
        image_installer="${line#TALOS_IMAGE_INSTALLER=}"
        ;;
      TALOS_IMAGE_DISK_URL=*)
        image_disk_url="${line#TALOS_IMAGE_DISK_URL=}"
        ;;
      TALOS_IMAGE_DOWNLOAD_URL=*)
        [[ -n "${image_disk_url:-}" ]] || image_disk_url="${line#TALOS_IMAGE_DOWNLOAD_URL=}"
        ;;
    esac
  done <<<"$helper_output"

  image_cache_key="${image_platform}-${image_arch}-${image_schematic}-${PINNED_TALOS_VERSION}"
}

resolve_talos_image_assets

download_talos_image() {
  local target_path="$1"
  local tmpdir=""
  local tmp_compressed=""
  local tmp_image=""

  [[ -n "${image_disk_url:-}" ]] || fail "Talos disk image URL not resolved"

  if [[ -s "$target_path" ]]; then
    log "Reusing cached Talos disk image at ${target_path}"
    talos_image_local_path="$target_path"
    return 0
  fi

  tmpdir="$(mktemp -d "${image_cache_dir%/}/talos-image-XXXXXX")"
  tmp_compressed="${tmpdir}/image.raw.xz"
  tmp_image="${tmpdir}/image.img"
  log "Downloading Talos disk image to ${target_path}"
  curl -fsSL --retry 3 --retry-delay 2 --output "$tmp_compressed" "$image_disk_url"
  xz -dc "$tmp_compressed" > "$tmp_image"
  mv "$tmp_image" "$target_path"
  rm -rf "$tmpdir"
  talos_image_local_path="$target_path"
}

proxmox_api_login() {
  if [[ -n "${PROXMOX_TICKET_COOKIE:-}" && -n "${PROXMOX_CSRF_TOKEN:-}" ]]; then
    return 0
  fi

  local auth_response=""
  auth_response="$(
    curl -ksS --fail \
      --data-urlencode "username=${PROXMOX_USER}" \
      --data-urlencode "password=${PROXMOX_PASSWORD}" \
      "${TF_VAR_proxmox_endpoint}/api2/json/access/ticket"
  )" || fail "Failed to obtain Proxmox API ticket from ${TF_VAR_proxmox_endpoint}"

  PROXMOX_TICKET_COOKIE="PVEAuthCookie=$(jq -r '.data.ticket' <<<"$auth_response")"
  PROXMOX_CSRF_TOKEN="$(jq -r '.data.CSRFPreventionToken' <<<"$auth_response")"

  [[ -n "${PROXMOX_TICKET_COOKIE#PVEAuthCookie=}" ]] || fail "Proxmox API ticket response did not include a cookie"
  [[ -n "$PROXMOX_CSRF_TOKEN" ]] || fail "Proxmox API ticket response did not include a CSRF token"
}

proxmox_cluster_status() {
  local cluster_status=""

  if [[ -n "${PROXMOX_CLUSTER_STATUS_JSON:-}" ]]; then
    printf '%s' "$PROXMOX_CLUSTER_STATUS_JSON"
    return 0
  fi

  proxmox_api_login
  cluster_status="$(curl -ksS --fail \
    --cookie "$PROXMOX_TICKET_COOKIE" \
    --header "CSRFPreventionToken: ${PROXMOX_CSRF_TOKEN}" \
    "${TF_VAR_proxmox_endpoint}/api2/json/cluster/status")" || fail "Failed to fetch Proxmox cluster status"
  PROXMOX_CLUSTER_STATUS_JSON="$cluster_status"
  printf '%s' "$cluster_status"
}

proxmox_node_ip() {
  local node="$1"
  local cluster_status=""

  cluster_status="$(proxmox_cluster_status)"
  jq -r --arg node "$node" '.data[]? | select(.type == "node" and .name == $node) | .ip // empty' <<<"$cluster_status"
}

proxmox_node_endpoint() {
  local node="$1"
  local node_ip=""

  node_ip="$(proxmox_node_ip "$node")"
  [[ -n "$node_ip" ]] || fail "Unable to resolve Proxmox endpoint for ${node}"
  printf 'https://%s:%s' "$node_ip" "$PROXMOX_PORT"
}

proxmox_get_all_vm_ids() {
  # Returns all VM IDs across all nodes in the cluster
  local cluster_status=""
  cluster_status="$(proxmox_cluster_status)"

  local node_names=()
  while IFS= read -r node_name; do
    [[ -n "$node_name" ]] || continue
    node_names+=("$node_name")
  done < <(jq -r '.data[]? | select(.type == "node") | .name' <<<"$cluster_status" 2>/dev/null | sort -u)

  local all_vm_ids=()
  local node=""
  for node in "${node_names[@]}"; do
    local node_vms=""
    node_vms="$(curl -ksS --fail \
      --cookie "$PROXMOX_TICKET_COOKIE" \
      --header "CSRFPreventionToken: ${PROXMOX_CSRF_TOKEN}" \
      "${TF_VAR_proxmox_endpoint}/api2/json/nodes/${node}/qemu")" || continue

    while IFS= read -r vmid; do
      [[ -n "$vmid" ]] || continue
      all_vm_ids+=("$vmid")
    done < <(jq -r '.data[].vmid' <<<"$node_vms" 2>/dev/null)
  done

  printf '%s\n' "${all_vm_ids[@]}" | sort -n | uniq
}

validate_vm_ids_available() {
  local planned_vms_json="$1"
  local existing_vm_ids=()
  local managed_vm_ids=()
  local planned_vm_ids=()
  local vmid=""
  local conflicts=()
  local existing_vm_ids_output=""
  local managed_vm_ids_output=""

  log "Checking for VM ID conflicts across the Proxmox cluster"

  if ! existing_vm_ids_output="$(proxmox_get_all_vm_ids)"; then
    fail "Failed to fetch Proxmox cluster status"
  fi

  while IFS= read -r vmid; do
    [[ -n "$vmid" ]] || continue
    existing_vm_ids+=("$vmid")
  done <<<"$existing_vm_ids_output"

  if managed_vm_ids_output="$(managed_vm_ids_from_state)"; then
    while IFS= read -r vmid; do
      [[ -n "$vmid" ]] || continue
      managed_vm_ids+=("$vmid")
    done <<<"$managed_vm_ids_output"
  fi

  while IFS= read -r vmid; do
    [[ -n "$vmid" ]] || continue
    planned_vm_ids+=("$vmid")
  done < <(jq -r '.[].vmid' <<<"$planned_vms_json" | sort -n | uniq)

  for vmid in "${planned_vm_ids[@]}"; do
    if array_contains "$vmid" ${existing_vm_ids[@]+"${existing_vm_ids[@]}"}; then
      if array_contains "$vmid" ${managed_vm_ids[@]+"${managed_vm_ids[@]}"}; then
        continue
      fi
      conflicts+=("$vmid")
    fi
  done

  if [[ ${#conflicts[@]} -gt 0 ]]; then
    local existing_list=""
    existing_list="$(printf '%s\n' ${existing_vm_ids[@]+"${existing_vm_ids[@]}"} | tr '\n' ' ')"
    fail "VM ID conflict: the following VM IDs are already in use in the Proxmox cluster: ${conflicts[*]}. Existing VM IDs: ${existing_list}"
  fi

  if [[ ${#managed_vm_ids[@]} -gt 0 ]]; then
    log "Ignoring VM IDs already managed by this cluster OpenTofu state: ${managed_vm_ids[*]}"
  fi

  log "All planned VM IDs are available: ${planned_vm_ids[*]}"
}

managed_vm_ids_from_state() {
  local state_file="${work_module_dir}/terraform.tfstate"

  [[ -s "$state_file" ]] || return 0

  jq -r '
    .resources[]?
    | select(.mode == "managed" and .type == "proxmox_virtual_environment_vm" and .name == "node")
    | .instances[]?.attributes.vm_id // empty
  ' "$state_file" 2>/dev/null | sort -n | uniq
}

validate_file_datastore_import_content() {
  local datastore="$1"
  local storage_json=""
  local content=""

  proxmox_api_login
  storage_json="$(curl -ksS --fail \
    --cookie "$PROXMOX_TICKET_COOKIE" \
    --header "CSRFPreventionToken: ${PROXMOX_CSRF_TOKEN}" \
    "${TF_VAR_proxmox_endpoint}/api2/json/storage/${datastore}")" || fail "Failed to inspect Proxmox storage ${datastore}"

  content="$(jq -r '.data.content // ""' <<<"$storage_json")"
  if [[ ",${content}," != *",import,"* ]]; then
    fail "Proxmox file datastore ${datastore} must allow Import content for Talos disk-image provisioning. Re-run the setup wizard or enable Import under Datacenter > Storage."
  fi
}

proxmox_get_storage_content() {
  local node="$1"
  local datastore="$2"
  local node_endpoint=""

  node_endpoint="$(proxmox_node_endpoint "$node")"
  proxmox_api_login
  curl -ksS --fail \
    --cookie "$PROXMOX_TICKET_COOKIE" \
    --header "CSRFPreventionToken: ${PROXMOX_CSRF_TOKEN}" \
    "${node_endpoint}/api2/json/nodes/${node}/storage/${datastore}/content"
}

proxmox_get_storage_status() {
  local node="$1"
  local datastore="$2"
  local node_endpoint=""

  node_endpoint="$(proxmox_node_endpoint "$node")"
  proxmox_api_login
  curl -ksS --fail \
    --cookie "$PROXMOX_TICKET_COOKIE" \
    --header "CSRFPreventionToken: ${PROXMOX_CSRF_TOKEN}" \
    "${node_endpoint}/api2/json/nodes/${node}/storage/${datastore}/status"
}

proxmox_talos_image_size() {
  local node="$1"
  local datastore="$2"
  local image_name="$3"
  local expected_volid="${datastore}:import/${image_name}"
  local content_json=""
  local image_size=""

  if ! content_json="$(proxmox_get_storage_content "$node" "$datastore")"; then
    PROXMOX_TALOS_IMAGE_ERROR="Failed to read Proxmox storage content for ${node}/${datastore}"
    return 2
  fi

  image_size="$(jq -r --arg volid "$expected_volid" '
    [.data[]? | select(.volid == $volid and .content == "import") | (.size // empty)]
    | .[0] // ""
  ' <<<"$content_json")"

  [[ -n "$image_size" ]] || return 1
  printf '%s\n' "$image_size"
}

proxmox_require_talos_upload_space() {
  local node="$1"
  local datastore="$2"
  local image_size_bytes="$3"
  local storage_json=""
  local available_bytes=""
  local required_bytes=$((image_size_bytes + PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES))

  if ! storage_json="$(proxmox_get_storage_status "$node" "$datastore")"; then
    PROXMOX_TALOS_IMAGE_ERROR="Failed to read Proxmox storage status for ${node}/${datastore}"
    log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
    return 1
  fi

  available_bytes="$(jq -r '.data.avail // empty' <<<"$storage_json")"
  if [[ ! "$available_bytes" =~ ^[0-9]+$ ]]; then
    PROXMOX_TALOS_IMAGE_ERROR="Proxmox storage status for ${node}/${datastore} did not include available bytes"
    log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
    return 1
  fi

  if (( available_bytes < required_bytes )); then
    PROXMOX_TALOS_IMAGE_ERROR="Proxmox file datastore ${node}/${datastore} has insufficient free space for Talos disk image upload: available=${available_bytes} bytes, required=${required_bytes} bytes (image=${image_size_bytes} bytes plus ${PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES} bytes buffer). Free space on ${node}/${datastore} or remove stale import/backup content before retrying."
    log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
    return 1
  fi

  log "Proxmox file datastore ${node}/${datastore} has ${available_bytes} bytes available for Talos disk image upload"
}

proxmox_upload_talos_image() {
  local node="$1"
  local datastore="$2"
  local image_path="$3"
  local image_name="$4"
  local node_endpoint=""
  local upload_url=""
  local attempt=1

  node_endpoint="$(proxmox_node_endpoint "$node")"
  upload_url="${node_endpoint}/api2/json/nodes/${node}/storage/${datastore}/upload"

  while true; do
    proxmox_api_login

    local response_file=""
    local response_body=""
    local http_code=""
    local curl_exit=0
    response_file="$(mktemp)"

    if http_code="$(
      curl -ksS --show-error \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --header "Expect:" \
        --cookie "$PROXMOX_TICKET_COOKIE" \
        --header "CSRFPreventionToken: ${PROXMOX_CSRF_TOKEN}" \
        --form "content=import" \
        --form "filename=@${image_path};filename=${image_name}" \
        "$upload_url"
    )"; then
      curl_exit=0
    else
      curl_exit=$?
    fi

    response_body="$(tr -d '\r' <"$response_file" | head -c 500 || true)"
    rm -f "$response_file"

    if [[ "$curl_exit" -eq 0 && "$http_code" == 2* ]]; then
      log "Uploaded Talos disk image to ${node}/${datastore}"
      PROXMOX_TALOS_IMAGE_ERROR=""
      return 0
    fi

    local reason=""
    if [[ "$curl_exit" -ne 0 ]]; then
      reason="curl exit ${curl_exit}"
    else
      reason="HTTP ${http_code}"
    fi

    if [[ "$http_code" == 4* ]]; then
      PROXMOX_TALOS_IMAGE_ERROR="Talos disk image upload to ${node}/${datastore} failed permanently (${reason}): ${response_body:-no response body}"
      log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
      return 1
    fi

    if [[ "$attempt" -ge "$PROXMOX_UPLOAD_MAX_ATTEMPTS" ]]; then
      PROXMOX_TALOS_IMAGE_ERROR="Talos disk image upload to ${node}/${datastore} failed after ${PROXMOX_UPLOAD_MAX_ATTEMPTS} attempts (${reason}): ${response_body:-no response body}"
      log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
      return 1
    fi

    local delay=$((2 ** (attempt - 1)))
    if [[ "$delay" -gt 30 ]]; then
      delay=30
    fi

    log "Talos disk image upload to ${node}/${datastore} failed (${reason}); retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

proxmox_verify_talos_image() {
  local node="$1"
  local datastore="$2"
  local image_name="$3"
  local expected_size_bytes="$4"
  local expected_volid="${datastore}:import/${image_name}"
  local attempt=1

  while true; do
    local image_size=""
    local status=0

    if image_size="$(proxmox_talos_image_size "$node" "$datastore" "$image_name")"; then
      if [[ "$image_size" != "$expected_size_bytes" ]]; then
        if [[ "$attempt" -ge "$PROXMOX_VERIFY_MAX_ATTEMPTS" ]]; then
          PROXMOX_TALOS_IMAGE_ERROR="Talos disk image on ${node}/${datastore} has unexpected size for ${expected_volid}: expected=${expected_size_bytes} bytes, actual=${image_size} bytes. Free space on ${node}/${datastore} and remove/re-upload the stale import image before retrying."
          log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
          return 1
        fi
        local delay=$((2 ** (attempt - 1)))
        if [[ "$delay" -gt 10 ]]; then
          delay=10
        fi
        log "Talos disk image on ${node}/${datastore} is ${image_size} bytes, expected ${expected_size_bytes}; retrying in ${delay}s"
        sleep "$delay"
        attempt=$((attempt + 1))
        continue
      fi
      log "Verified Talos disk image on ${node}/${datastore}: ${expected_volid} (${image_size} bytes)"
      PROXMOX_TALOS_IMAGE_ERROR=""
      return 0
    else
      status=$?
    fi

    if [[ "$status" -ne 1 ]]; then
      PROXMOX_TALOS_IMAGE_ERROR="${PROXMOX_TALOS_IMAGE_ERROR:-Failed to read Proxmox storage content for ${node}/${datastore}}"
      log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
      return 1
    fi

    if [[ "$attempt" -ge "$PROXMOX_VERIFY_MAX_ATTEMPTS" ]]; then
      PROXMOX_TALOS_IMAGE_ERROR="Talos disk image not visible after upload on ${node}/${datastore}: ${expected_volid}"
      log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
      return 1
    fi

    local delay=$((2 ** (attempt - 1)))
    if [[ "$delay" -gt 10 ]]; then
      delay=10
    fi

    log "Talos disk image not visible yet on ${node}/${datastore}; retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

proxmox_talos_image_present() {
  local node="$1"
  local datastore="$2"
  local image_name="$3"
  local expected_size_bytes="$4"
  local expected_volid="${datastore}:import/${image_name}"
  local image_size=""
  local status=0

  if image_size="$(proxmox_talos_image_size "$node" "$datastore" "$image_name")"; then
    if [[ "$image_size" == "$expected_size_bytes" ]]; then
      return 0
    fi
    PROXMOX_TALOS_IMAGE_ERROR="Talos disk image on ${node}/${datastore} has unexpected size for ${expected_volid}: expected=${expected_size_bytes} bytes, actual=${image_size} bytes. Free space on ${node}/${datastore} and remove/re-upload the stale import image before retrying."
    return 2
  else
    status=$?
  fi

  [[ "$status" -eq 1 ]] && return 1
  PROXMOX_TALOS_IMAGE_ERROR="${PROXMOX_TALOS_IMAGE_ERROR:-Failed to read Proxmox storage content for ${node}/${datastore}}"
  return 2
}

upload_talos_image_to_nodes() {
  local image_path="$1"
  local image_name="$2"
  local nodes_json="$3"
  local expected_size_bytes=""
  local node=""
  local image_status=0
  local success_nodes=()
  local failed_nodes=()
  local failure_messages=()

  if ! expected_size_bytes="$(file_size_bytes "$image_path")"; then
    PROXMOX_TALOS_IMAGE_ERROR="Failed to inspect local Talos disk image size: ${image_path}"
    log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
    return 1
  fi
  if [[ ! "$expected_size_bytes" =~ ^[0-9]+$ ]]; then
    PROXMOX_TALOS_IMAGE_ERROR="Local Talos disk image size is not numeric for ${image_path}: ${expected_size_bytes}"
    log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
    return 1
  fi

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    PROXMOX_TALOS_IMAGE_ERROR=""
    if proxmox_talos_image_present "$node" "$FILE_DATASTORE" "$image_name" "$expected_size_bytes"; then
      log "Talos disk image already present on ${node}/${FILE_DATASTORE}: ${image_name} (${expected_size_bytes} bytes)"
      success_nodes+=("$node")
      continue
    else
      image_status=$?
    fi
    if [[ "$image_status" -eq 2 ]]; then
      failed_nodes+=("$node")
      failure_messages+=("${PROXMOX_TALOS_IMAGE_ERROR:-Talos disk image validation failed for ${node}/${FILE_DATASTORE}}")
      continue
    fi
    PROXMOX_TALOS_IMAGE_ERROR=""
    if ! proxmox_require_talos_upload_space "$node" "$FILE_DATASTORE" "$expected_size_bytes"; then
      failed_nodes+=("$node")
      failure_messages+=("${PROXMOX_TALOS_IMAGE_ERROR:-Talos disk image upload preflight failed for ${node}/${FILE_DATASTORE}}")
      continue
    fi
    log "Uploading Talos disk image directly to ${node}/${FILE_DATASTORE} via $(proxmox_node_endpoint "$node")"
    PROXMOX_TALOS_IMAGE_ERROR=""
    if ! proxmox_upload_talos_image "$node" "$FILE_DATASTORE" "$image_path" "$image_name"; then
      failed_nodes+=("$node")
      failure_messages+=("${PROXMOX_TALOS_IMAGE_ERROR:-Talos disk image upload to ${node}/${FILE_DATASTORE} failed}")
      continue
    fi
    PROXMOX_TALOS_IMAGE_ERROR=""
    if ! proxmox_verify_talos_image "$node" "$FILE_DATASTORE" "$image_name" "$expected_size_bytes"; then
      failed_nodes+=("$node")
      failure_messages+=("${PROXMOX_TALOS_IMAGE_ERROR:-Talos disk image verification failed for ${node}/${FILE_DATASTORE}}")
      continue
    fi
    success_nodes+=("$node")
  done < <(jq -r '.[]' <<<"$nodes_json")

  if [[ ${#failed_nodes[@]} -gt 0 ]]; then
    log "Talos disk image upload summary: succeeded=${success_nodes[*]:-none}; failed=${failed_nodes[*]}"
    local failure_message=""
    local failure=""
    for failure in "${failure_messages[@]}"; do
      failure_message+="${failure}"$'\n'
    done
    while IFS= read -r failure; do
      [[ -n "$failure" ]] || continue
      log "Talos disk image upload failure: ${failure}"
    done <<<"${failure_message%$'\n'}"
    return 1
  fi

  log "Talos disk image upload summary: succeeded=${success_nodes[*]:-none}; failed=none"
}

remove_legacy_talos_file_state() {
  local workdir="$1"
  local legacy_addresses=()
  local address=""

  while IFS= read -r address; do
    [[ -n "$address" ]] || continue
    legacy_addresses+=("$address")
  done < <(
    "$TOFU_BIN" -chdir="$workdir" state list 2>/dev/null \
      | grep '^proxmox_virtual_environment_file.talos_nocloud' \
      || true
  )

  if [[ ${#legacy_addresses[@]} -eq 0 ]]; then
    return 0
  fi

  log "Removing legacy Talos ISO resources from OpenTofu state: ${legacy_addresses[*]}"
  "$TOFU_BIN" -chdir="$workdir" state rm "${legacy_addresses[@]}"
}

next_ip() {
  local base octet
  base=$(echo "$START_IP" | cut -d. -f1-3)
  octet=$(echo "$START_IP" | cut -d. -f4)
  echo "$base.$((octet + $1))"
}

build_legacy_vm_ip_map() {
  local start_ip="$1"
  local cp_count="$2"
  local worker_count="$3"
  local base
  local octet
  local map='{}'
  local i=""
  local name=""
  local ip=""

  base="$(echo "$start_ip" | cut -d. -f1-3)"
  octet="$(echo "$start_ip" | cut -d. -f4)"

  if [[ "$cp_count" -gt 0 ]]; then
    for i in $(seq 1 "$cp_count"); do
      name="cp-${i}"
      ip="${base}.$((octet + i - 1))"
      map="$(jq --arg key "$name" --arg ip "$ip" '. + {($key): $ip}' <<<"$map")"
    done
  fi

  if [[ "$worker_count" -gt 0 ]]; then
    for i in $(seq 1 "$worker_count"); do
      name="worker-${i}"
      ip="${base}.$((octet + cp_count + i - 1))"
      map="$(jq --arg key "$name" --arg ip "$ip" '. + {($key): $ip}' <<<"$map")"
    done
  fi

  printf '%s\n' "$map"
}

resolve_vm_ip_map() {
  local raw_vm_ip_map="${VM_IP_MAP:-}"

  if [[ -n "$raw_vm_ip_map" ]]; then
    if ! jq -e . >/dev/null 2>&1 <<<"$raw_vm_ip_map"; then
      fail "vm_ip_map is not valid JSON: ${raw_vm_ip_map}"
    fi

    if [[ "$(jq -r 'type' <<<"$raw_vm_ip_map")" != "object" ]]; then
      fail "vm_ip_map must be a JSON object"
    fi

    if [[ "$(jq -r 'length' <<<"$raw_vm_ip_map")" -eq 0 ]]; then
      [[ -n "${START_IP:-}" ]] || fail "Missing vm_ip_map or start_ip for cluster ${CLUSTER_ID}"
      build_legacy_vm_ip_map "$START_IP" "$CP_COUNT" "$WORKER_COUNT"
      return 0
    fi

    printf '%s\n' "$(jq -c '.' <<<"$raw_vm_ip_map")"
    return 0
  fi

  [[ -n "${START_IP:-}" ]] || fail "Missing vm_ip_map or start_ip for cluster ${CLUSTER_ID}"
  build_legacy_vm_ip_map "$START_IP" "$CP_COUNT" "$WORKER_COUNT"
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
  local cpu=""
  local ram=""
  local disk=""
  local datastore=""

  if [[ "$CP_COUNT" -gt 0 ]]; then
    for i in $(seq 1 "$CP_COUNT"); do
      name="cp-${i}"
      ip="$(jq -r --arg key "$name" '.[$key] // empty' <<<"$vm_ip_map_json")"
      [[ -n "$ip" ]] || fail "Missing vm_ip_map entry for ${name}"
      cpu="$(jq -r --arg key "$name" '.[$key].cpu // empty' <<<"$vm_size_map_json")"
      ram="$(jq -r --arg key "$name" '.[$key].memory_mb // empty' <<<"$vm_size_map_json")"
      disk="$(jq -r --arg key "$name" '.[$key].disk_gb // empty' <<<"$vm_size_map_json")"
      datastore="$(jq -r --arg key "$name" '.[$key] // empty' <<<"$vm_storage_map_json")"
      [[ -n "$cpu" && -n "$ram" && -n "$disk" ]] || fail "Missing vm_size_map entry for ${name}"
      [[ -n "$datastore" ]] || fail "Missing vm_storage_map entry for ${name}"
      mac="$(deterministic_mac "$current_vmid")"
      nodes_json="$(jq \
        --arg key "$name" \
        --arg ip "$ip" \
        --arg type "controlplane" \
        --arg mac "$mac" \
        --argjson vmid "$current_vmid" \
        --argjson cpu "$cpu" \
        --argjson ram "$ram" \
        --argjson disk "$disk" \
        --arg datastore "$datastore" \
        '. + {($key): {ip: $ip, type: $type, vmid: $vmid, cpu: $cpu, ram_mb: $ram, disk_gb: $disk, datastore_id: $datastore, mac: $mac}}' \
        <<<"$nodes_json")"
      current_vmid=$((current_vmid + 1))
    done
  fi

  if [[ "$WORKER_COUNT" -gt 0 ]]; then
    for i in $(seq 1 "$WORKER_COUNT"); do
      name="worker-${i}"
      ip="$(jq -r --arg key "$name" '.[$key] // empty' <<<"$vm_ip_map_json")"
      [[ -n "$ip" ]] || fail "Missing vm_ip_map entry for ${name}"
      cpu="$(jq -r --arg key "$name" '.[$key].cpu // empty' <<<"$vm_size_map_json")"
      ram="$(jq -r --arg key "$name" '.[$key].memory_mb // empty' <<<"$vm_size_map_json")"
      disk="$(jq -r --arg key "$name" '.[$key].disk_gb // empty' <<<"$vm_size_map_json")"
      datastore="$(jq -r --arg key "$name" '.[$key] // empty' <<<"$vm_storage_map_json")"
      [[ -n "$cpu" && -n "$ram" && -n "$disk" ]] || fail "Missing vm_size_map entry for ${name}"
      [[ -n "$datastore" ]] || fail "Missing vm_storage_map entry for ${name}"
      mac="$(deterministic_mac "$current_vmid")"
      nodes_json="$(jq \
        --arg key "$name" \
        --arg ip "$ip" \
        --arg type "worker" \
        --arg mac "$mac" \
        --argjson vmid "$current_vmid" \
        --argjson cpu "$cpu" \
        --argjson ram "$ram" \
        --argjson disk "$disk" \
        --arg datastore "$datastore" \
        '. + {($key): {ip: $ip, type: $type, vmid: $vmid, cpu: $cpu, ram_mb: $ram, disk_gb: $disk, datastore_id: $datastore, mac: $mac}}' \
        <<<"$nodes_json")"
      current_vmid=$((current_vmid + 1))
    done
  fi

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

json_array_from_csv() {
  local csv="${1:-}"

  jq -Rn --arg csv "$csv" '
    $csv
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
  '
}

normalize_json_object() {
  local raw="${1:-}"

  if [[ -z "$raw" ]]; then
    printf '{}'
    return 0
  fi

  if ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
    printf '{}'
    return 0
  fi

  if [[ "$(jq -r 'type' <<<"$raw")" != "object" ]]; then
    printf '{}'
    return 0
  fi

  jq -c '.' <<<"$raw"
}

validate_vm_node_map() {
  local missing=()
  local name=""

  while IFS=$'\t' read -r name _; do
    [[ -n "$name" ]] || continue
    if ! jq -e --arg key "$name" 'has($key)' <<<"$vm_node_map_json" >/dev/null; then
      missing+=("$name")
    fi
  done < <(jq -r '
      to_entries
      | sort_by(.key)
      | .[]
      | [.key, .value.type]
      | @tsv
    ' <<<"$nodes_json")

  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing vm_node_map entry for: ${missing[*]}"
  fi
}

log_vm_node_map() {
  local name=""
  local host=""

  while IFS=$'\t' read -r name host; do
    [[ -n "$name" ]] || continue
    log "Talos placement ${name} -> ${host}"
  done < <(jq -r '
      to_entries
      | sort_by(.key)
      | .[]
      | [.key, .value]
      | @tsv
    ' <<<"$vm_node_map_json")
}

update_cluster_file() {
  local status="$1"
  local planned_controlplane_ips="$2"
  local planned_worker_ips="$3"
  local discovered_controlplane_ips="$4"
  local discovered_worker_ips="$5"
  local controlplane_vm_ids="$6"
  local worker_vm_ids="$7"
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
      | .bootstrap_mode = "static-nocloud"
      | del(.talos_config_dir)
      | del(.talosconfig_path)
      | del(.kubeconfig_path)
      | del(.last_error)
    ' "$cluster_file" > "$tmp"
  mv "$tmp" "$cluster_file"
}

wait_for_talos_api() {
  local label="$1"
  local candidate="$2"
  local attempts=60

  while [[ "$attempts" -gt 0 ]]; do
    if talosctl version \
      --nodes "$candidate" \
      --endpoints "$candidate" \
      --talosconfig "$talosconfig_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    attempts=$((attempts - 1))
  done

  fail "Timed out waiting for Talos API on ${label} at ${candidate}"
}

render_cilium_manifest() {
  local output_file="$1"
  local values_file="$WORKSPACE_ROOT/config/cilium-values.yaml"
  local helm_args=()

  [[ -f "$values_file" ]] || fail "Cilium values file not found: ${values_file}"

  helm_args+=(--set-string "k8sServiceHost=${VIP_IP}")
  helm_args+=(--set-string "k8sServicePort=6443")

  if ! helm repo list 2>/dev/null | awk '$1 == "cilium" { found = 1 } END { exit found ? 0 : 1 }'; then
    helm repo add cilium https://helm.cilium.io >/dev/null
  fi
  helm repo update >/dev/null

  mkdir -p "$(dirname "$output_file")"
  log "Rendering Cilium bootstrap manifest to ${output_file}"
  helm template cilium cilium/cilium \
    --version "$PINNED_CILIUM_CHART_VERSION" \
    --namespace kube-system \
    --include-crds \
    --values "$values_file" \
    "${helm_args[@]}" \
    > "$output_file"
}

wait_for_kubernetes_rollout() {
  local resource="$1"
  local namespace="$2"
  local label="${3:-$resource}"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl --kubeconfig "$kubeconfig_file" -n "$namespace" rollout status "$resource" --timeout=15s >/dev/null 2>&1; then
      log "${label} is ready"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for ${label}"
    fi

    log "Waiting for ${label}"
    sleep 5
    attempt=$((attempt + 1))
  done
}

write_node_patch() {
  local name="$1"
  local type="$2"
  local ip="$3"
  local mac="$4"
  local patch_file="$5"
  local nameserver_block=""
  local search_domain_block=""
  local time_server="${TWINBOX_TIME_SERVER:-time.cloudflare.com}"
  local role_label="$type"

  if [[ "$type" == "controlplane" ]]; then
    role_label="control-plane"
  fi

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
    echo "  nodeLabels:"
    echo "    twinbox.io/role: ${role_label}"
    if [[ "$type" == "worker" ]]; then
      echo "    node.longhorn.io/create-default-disk: \"true\""
    fi
    # Collabora-based document servers create a user namespace for each jail.
    # Talos defaults this kernel limit to zero, which prevents those editors from starting.
    echo "  sysctls:"
    echo "    user.max_user_namespaces: \"11255\""
    echo "  network:"
    [[ -n "$nameserver_block" ]] && printf '%s' "$nameserver_block"
    [[ -n "$search_domain_block" ]] && printf '%s' "$search_domain_block"
    echo "    interfaces:"
    echo "      - deviceSelector:"
    echo "          hardwareAddr: ${mac}"
    echo "        dhcp: false"
    echo "        addresses:"
    echo "          - ${ip}/${NODE_PREFIX_LENGTH}"
    echo "        routes:"
    echo "          - network: 0.0.0.0/0"
    echo "            gateway: ${GATEWAY_IP}"
    if [[ "$type" == "controlplane" ]]; then
      echo "        vip:"
      echo "          ip: ${VIP_IP}"
    fi
    if [[ -n "${image_installer:-}" ]]; then
      echo "  install:"
      echo "    image: ${image_installer}"
    fi
    echo "  time:"
    echo "    servers:"
    echo "      - ${time_server}"
    echo "  features:"
    echo "    kubePrism:"
    echo "      enabled: true"
    echo "      port: 7445"
    echo "    hostDNS:"
    echo "      forwardKubeDNSToHost: false"
echo "cluster:"
echo "  network:"
echo "    cni:"
echo "      name: none"
echo "  proxy:"
echo "    disabled: true"
if [[ "$type" == "controlplane" ]]; then
  echo "  apiServer:"
  echo "    resources:"
  echo "      requests:"
  echo "        cpu: 500m"
  echo "        memory: 1Gi"
  echo "      limits:"
  echo "        memory: 2Gi"
fi
  } > "$patch_file"
}

append_hostname_config_patch() {
  local name="$1"
  local patch_file="$2"

  {
    echo "---"
    echo "apiVersion: v1alpha1"
    echo "kind: HostnameConfig"
    echo "hostname: ${NAME}-${name}"
    echo "auto: off"
  } >> "$patch_file"
}

upsert_secret_artifact() {
  local item="$1"
  local attachment="$2"
  local source_file="$3"

  [[ -s "$source_file" ]] || return 0

  "$NODE_BIN" "$WORKSPACE_ROOT/scripts/manager/upsert-secret-artifact.mjs" \
    --scope cluster \
    --cluster-id "$CLUSTER_ID" \
    --item "$item" \
    --attachment "$attachment" \
    --source "$source_file"
}

restore_secret_artifact() {
  local item="$1"
  local attachment="$2"
  local target_file="$3"
  local source_file="${bootstrap_secret_dir}/${item}/${attachment}"

  [[ ! -s "$target_file" ]] || return 0
  [[ -s "$source_file" ]] || return 0

  mkdir -p "$(dirname "$target_file")"
  cp "$source_file" "$target_file"
  log "Reusing existing ${item}/${attachment} artifact"
}

generate_talos_configs() {
  local base_dir="$runtime_talos_dir/base"
  local node_dir=""
  local patch_file=""
  local controlplane_patch_file=""
  local name=""
  local type=""
  local ip=""
  local mac=""
  local config_file=""

  rm -rf "$runtime_talos_dir/base" "$runtime_talos_dir/generated"
  mkdir -p "$base_dir" "$runtime_talos_dir/generated"

  restore_secret_artifact "talos-secrets" "secrets.yaml" "$talos_secrets_file"

  if [[ -s "$talos_secrets_file" ]]; then
    log "Reusing Talos secrets at ${talos_secrets_file}"
  else
    log "Generating Talos secrets"
    talosctl gen secrets -o "$talos_secrets_file"
  fi

  log "Generating base Talos config"
  talosctl gen config "$NAME" "https://${VIP_IP}:6443" \
    --output-dir "$base_dir" \
    --with-secrets "$talos_secrets_file" \
    --install-disk "$INSTALL_DISK"

  cp "$base_dir/talosconfig" "$talosconfig_file"
  upsert_secret_artifact "talos-secrets" "secrets.yaml" "$talos_secrets_file"
  upsert_secret_artifact "talosconfig" "talosconfig" "$talosconfig_file"

  while IFS=$'\t' read -r name type ip mac; do
    [[ -n "$name" ]] || continue
    node_dir="$runtime_talos_dir/generated/$name"
    patch_file="$node_dir/patch.yaml"
    mkdir -p "$node_dir"
    write_node_patch "$name" "$type" "$ip" "$mac" "$patch_file"

    log "Generating Talos config for ${name}"
    if [[ "$type" == "controlplane" ]]; then
      controlplane_patch_file="$node_dir/controlplane-patch.yaml"
      cp "$patch_file" "$controlplane_patch_file"
      {
        echo "  inlineManifests:"
        echo "    - name: cilium"
        echo "      contents: |"
        sed 's/^/        /' "$cilium_manifest_file"
      } >> "$controlplane_patch_file"
      append_hostname_config_patch "$name" "$controlplane_patch_file"
      talosctl gen config "$NAME" "https://${VIP_IP}:6443" \
        --output-dir "$node_dir" \
        --with-secrets "$talos_secrets_file" \
        --install-disk "$INSTALL_DISK" \
        --config-patch-control-plane "@${controlplane_patch_file}"
      config_file="$runtime_talos_dir/${name}-controlplane.yaml"
      cp "$node_dir/controlplane.yaml" "$config_file"
    else
      append_hostname_config_patch "$name" "$patch_file"
      talosctl gen config "$NAME" "https://${VIP_IP}:6443" \
        --output-dir "$node_dir" \
        --with-secrets "$talos_secrets_file" \
        --install-disk "$INSTALL_DISK" \
        --config-patch-worker "@${patch_file}"
      config_file="$runtime_talos_dir/${name}-worker.yaml"
      cp "$node_dir/worker.yaml" "$config_file"
    fi
  done < <(jq -r '
      to_entries
      | sort_by(.key)
      | .[]
      | [.key, .value.type, .value.ip, .value.mac]
      | @tsv
    ' <<<"$nodes_json")
}

bootstrap_cluster() {
  local first_cp_ip="$1"
  local bootstrap_output=""
  local attempt=1
  local max_attempts="${TALOS_BOOTSTRAP_MAX_ATTEMPTS:-60}"
  local retry_delay="${TALOS_BOOTSTRAP_RETRY_DELAY_SECONDS:-5}"

  wait_for_talos_api "control plane" "$first_cp_ip"

  while true; do
    log "Bootstrapping cluster from ${first_cp_ip}"
    if bootstrap_output="$(
      talosctl bootstrap \
        --nodes "$first_cp_ip" \
        --endpoints "$first_cp_ip" \
        --talosconfig "$talosconfig_file" \
        2>&1
    )"; then
      break
    fi

    if grep -q 'AlreadyExists desc = etcd data directory is not empty' <<<"$bootstrap_output"; then
      log "Talos bootstrap already completed on ${first_cp_ip}; continuing"
      break
    fi

    if grep -q 'bootstrap is not available yet' <<<"$bootstrap_output" && [[ "$attempt" -lt "$max_attempts" ]]; then
      log "Talos bootstrap is not available yet on ${first_cp_ip}; retrying in ${retry_delay}s (attempt ${attempt}/${max_attempts})"
      sleep "$retry_delay"
      attempt=$((attempt + 1))
      continue
    fi

    printf '%s\n' "$bootstrap_output" >&2
    return 1
  done

  log "Writing kubeconfig"
  talosctl kubeconfig "$kubeconfig_file" \
    --nodes "$first_cp_ip" \
    --endpoints "$first_cp_ip" \
    --talosconfig "$talosconfig_file" \
    --force

  upsert_secret_artifact "kubeconfig" "kubeconfig" "$kubeconfig_file"
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

  # Update node/endpoint
  talosctl config node "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null
  talosctl config endpoint "$default_node_ip" --talosconfig "$target_talosconfig" >/dev/null

  # Fix ownership if we ran as root
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$owner_uid:$owner_gid" "$target_talosconfig"
  fi
  log "Copied talosconfig to ${target_talosconfig}"
}

cilium_bootstrap_dir="$runtime_talos_dir/cilium"
cilium_manifest_file="$cilium_bootstrap_dir/cilium-bootstrap.yaml"
render_cilium_manifest "$cilium_manifest_file"
upsert_secret_artifact "cilium" "cilium-bootstrap.yaml" "$cilium_manifest_file"

vm_ip_map_json="$(resolve_vm_ip_map)"
if [[ -z "${VM_SIZE_MAP:-}" ]]; then
  fail "Missing vm_size_map for cluster ${CLUSTER_ID}; pass --vm-size-map from the current run"
fi
if ! jq -e . >/dev/null 2>&1 <<<"$VM_SIZE_MAP"; then
  fail "vm_size_map for cluster ${CLUSTER_ID} is not valid JSON: ${VM_SIZE_MAP}"
fi
vm_size_map_json="$(normalize_json_object "$VM_SIZE_MAP")"
if [[ "$(jq -r 'length' <<<"$vm_size_map_json")" -eq 0 ]]; then
  fail "vm_size_map for cluster ${CLUSTER_ID} is empty; pass a non-empty --vm-size-map from the current run"
fi
if [[ -z "${VM_STORAGE_MAP:-}" ]]; then
  fail "Missing vm_storage_map for cluster ${CLUSTER_ID}; pass --vm-storage-map from the current run"
fi
if ! jq -e . >/dev/null 2>&1 <<<"$VM_STORAGE_MAP"; then
  fail "vm_storage_map for cluster ${CLUSTER_ID} is not valid JSON: ${VM_STORAGE_MAP}"
fi
vm_storage_map_json="$(normalize_json_object "$VM_STORAGE_MAP")"
if [[ "$(jq -r 'length' <<<"$vm_storage_map_json")" -eq 0 ]]; then
  fail "vm_storage_map for cluster ${CLUSTER_ID} is empty"
fi

nodes_json="$(generate_nodes_json)"
planned_controlplane_ips_json="$(node_array "ip" "controlplane")"
planned_worker_ips_json="$(node_array "ip" "worker")"
controlplane_vm_ids_json="$(node_array "vmid" "controlplane")"
worker_vm_ids_json="$(node_array "vmid" "worker")"
generate_talos_configs
raw_vm_node_map="${VM_NODE_MAP:-}"
# vm_node_map_json="$(normalize_json_object "${VM_NODE_MAP:-{}}")"

if [[ -z "$raw_vm_node_map" ]]; then
  fail "Missing vm_node_map for cluster ${CLUSTER_ID}; pass --vm-node-map from the current run"
fi

if ! jq -e . >/dev/null 2>&1 <<<"$raw_vm_node_map"; then
  fail "vm_node_map for cluster ${CLUSTER_ID} is not valid JSON: ${raw_vm_node_map}"
fi

vm_node_map_json="$(normalize_json_object "$raw_vm_node_map")"

if [[ "$(jq -r 'length' <<<"$vm_node_map_json")" -eq 0 ]]; then
  fail "vm_node_map for cluster ${CLUSTER_ID} is empty; pass a non-empty --vm-node-map from the current run"
fi
validate_vm_node_map
log_vm_node_map

[[ -n "${image_disk_url:-}" ]] || fail "Talos disk image URL not resolved"
validate_file_datastore_import_content "$FILE_DATASTORE"
talos_image_local_path="$image_cache_dir/talos-${CLUSTER_ID}-${image_cache_key}.raw"
talos_image_file_name="talos-${CLUSTER_ID}-${image_cache_key}.raw"
download_talos_image "$talos_image_local_path"
target_nodes_json="$(jq -nc --arg proxmox_node "$PROXMOX_NODE" --argjson vm_node_map "$vm_node_map_json" '([ $proxmox_node ] + ($vm_node_map | to_entries | map(.value))) | unique')"
log "Uploading Talos disk image to Proxmox nodes: $(jq -r 'join(", ")' <<<"$target_nodes_json")"
upload_talos_image_to_nodes "$talos_image_local_path" "$talos_image_file_name" "$target_nodes_json"

if [[ -f "$work_module_dir/terraform.tfstate" ]]; then
  log "Reusing existing OpenTofu workspace at ${work_module_dir}"
else
  rm -rf "$work_module_dir"
  mkdir -p "$work_module_dir"
fi
cp -R "$MODULE_SOURCE/." "$work_module_dir/"
mkdir -p "$work_module_dir/talos-configs"
while IFS=$'\t' read -r name type; do
  [[ -n "$name" ]] || continue
  cp "$runtime_talos_dir/${name}-${type}.yaml" "$work_module_dir/talos-configs/${name}.yaml"
done < <(jq -r '
    to_entries
    | sort_by(.key)
    | .[]
    | [.key, .value.type]
    | @tsv
  ' <<<"$nodes_json")

jq -n \
  --arg proxmox_node "$PROXMOX_NODE" \
  --arg file_datastore "$FILE_DATASTORE" \
  --arg bridge "$BRIDGE" \
  --arg gateway "$GATEWAY_IP" \
  --arg cluster_name "$NAME" \
  --arg cluster_slug "$CLUSTER_ID" \
  --arg cluster_endpoint "https://${VIP_IP}:6443" \
  --arg vip_ip "$VIP_IP" \
  --arg talos_version "$PINNED_TALOS_VERSION" \
  --arg talos_image_cache_key "$image_cache_key" \
  --argjson vm_node_map "$vm_node_map_json" \
  --argjson dns_servers "$(json_array_from_csv "${DNS_SERVERS:-1.1.1.1,8.8.8.8}")" \
  --argjson prefix "${NODE_PREFIX_LENGTH:-24}" \
  --argjson nodes "$nodes_json" \
  '{
    proxmox_node: $proxmox_node,
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
    talos_image_cache_key: $talos_image_cache_key,
    vm_node_map: $vm_node_map,
    install_disk: "'"$INSTALL_DISK"'",
    nodes: $nodes
  }' > "$tfvars_file"
log "Talos host placement map written to tfvars"
log "Talos host map: $(jq -c '.vm_node_map' "$tfvars_file")"

validate_vm_ids_available "$nodes_json"

log "Preparing OpenTofu module"
"$TOFU_BIN" -chdir="$work_module_dir" init -input=false -no-color
remove_legacy_talos_file_state "$work_module_dir"
log "Creating Proxmox VMs"
"$TOFU_BIN" -chdir="$work_module_dir" apply -input=false -auto-approve -no-color -parallelism="$TOFU_PARALLELISM" -var-file="$tfvars_file"

update_cluster_file "provisioned" "$planned_controlplane_ips_json" "$planned_worker_ips_json" "$planned_controlplane_ips_json" "$planned_worker_ips_json" "$controlplane_vm_ids_json" "$worker_vm_ids_json"

first_controlplane_ip="$(jq -r '.[0] // empty' <<<"$planned_controlplane_ips_json")"
[[ -n "$first_controlplane_ip" ]] || fail "No control plane IP configured"

bootstrap_cluster "$first_controlplane_ip"
wait_for_kubernetes_rollout "daemonset/cilium" "kube-system" "Cilium DaemonSet"
wait_for_kubernetes_rollout "deployment/cilium-operator" "kube-system" "Cilium operator"
wait_for_kubernetes_rollout "deployment/coredns" "kube-system" "CoreDNS"

patch_coredns_deployment() {
  log "Patching CoreDNS with topology spread constraints"
  kubectl --kubeconfig "$kubeconfig_file" patch deployment coredns -n kube-system --type merge -p '{
    "spec": {
      "template": {
        "spec": {
          "topologySpreadConstraints": [
            {
              "maxSkew": 1,
              "topologyKey": "kubernetes.io/hostname",
              "whenUnsatisfiable": "DoNotSchedule",
              "labelSelector": {
                "matchLabels": {
                  "k8s-app": "kube-dns"
                }
              }
            }
          ]
        }
      }
    }
  }'
}
patch_coredns_deployment

if kubectl --kubeconfig "$kubeconfig_file" -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  fail "kube-proxy daemonset should not exist in kube-proxy-free mode"
fi
if [[ "${TWINBOX_SYNC_LOCAL_CLIENT_CONFIGS:-false}" == "true" ]]; then
  sync_user_talosconfig "$talosconfig_file" "$first_controlplane_ip"
  sync_user_kubeconfig "$kubeconfig_file"
fi

log "Waiting for workers at their configured static addresses"
while IFS=$'\t' read -r name type ip; do
  [[ -n "$name" && "$type" == "worker" ]] || continue
  wait_for_talos_api "$name" "$ip"
done < <(jq -r '
    to_entries
    | sort_by(.key)
    | .[]
    | [.key, .value.type, .value.ip]
    | @tsv
  ' <<<"$nodes_json")

tmp="$(mktemp)"
jq \
  --arg status "bootstrapped" \
  --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson planned_controlplane_ips "$planned_controlplane_ips_json" \
  --argjson planned_worker_ips "$planned_worker_ips_json" \
  --argjson discovered_controlplane_ips "$planned_controlplane_ips_json" \
  --argjson discovered_worker_ips "$planned_worker_ips_json" \
  --argjson controlplane_vm_ids "$controlplane_vm_ids_json" \
  --argjson worker_vm_ids "$worker_vm_ids_json" \
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
    | .bootstrap_mode = "static-nocloud"
    | del(.talos_config_dir)
    | del(.talosconfig_path)
    | del(.kubeconfig_path)
    | del(.last_error)
  ' "$cluster_file" > "$tmp"
mv "$tmp" "$cluster_file"

log "Cluster provisioning finished"
