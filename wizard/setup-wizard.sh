#!/bin/bash

# Twinbox - Proxmox Console Setup Wizard
# Creates only the Ubuntu Management VM and auto-starts the manager stack.

set -euo pipefail

GITHUB_REPO="harrywesterman/twinbox"

RD="\033[01;31m"
YW="\033[33m"
GN="\033[1;92m"
CL="\033[m"
BFR="\r\033[K"
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

snippet_file=""
vm_created=0
CLUSTER_SLUG=""
CLUSTER_VM_PREFIX=""
CLUSTER_VM_TAG=""
TWINBOX_TARGET_DIR=""
EXISTING_VM_IDS=()
EXISTING_VM_NAMES=()
EXISTING_SNIPPETS=()
EXISTING_USER_PRESENT=0
EXISTING_ROLE_PRESENT=0

header_info() {
  clear
  cat << "BANNER"
  _______       _       _
 |__   __|     (_)     | |
    | |_      ___ _ __ | |__   _____  __
    | \ \ /\ / / | '_ \| '_ \ / _ \ \/ /
    | |\ V  V /| | | | | |_) | (_) >  <
    |_| \_/\_/ |_|_| |_|_.__/ \___/_/\_\

    Proxmox Management VM Bootstrap Wizard
BANNER
}

msg_info() { echo -ne " ${HOLD} ${YW}$1..."; }
msg_ok() { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }
status_update() { echo -e " ${HOLD} ${YW}[$(date '+%H:%M:%S')] $1${CL}" >&2; }

cleanup_after_run() {
  local exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    return
  fi

  if [[ -n "${snippet_file:-}" && -f "$snippet_file" ]]; then
    rm -f "$snippet_file"
  fi

  if [[ "${vm_created:-0}" -eq 1 ]]; then
    qm stop "$MGT_ID" --skiplock 1 >/dev/null 2>&1 || true
    qm destroy "$MGT_ID" --purge 1 >/dev/null 2>&1 || true
  fi
}

check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $$) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root"
    exit 1
  fi
}

check_deps() {
  msg_info "Checking dependencies"
  if ! command -v whiptail >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y whiptail curl openssl >/dev/null 2>&1
  fi
  msg_ok "Dependencies checked"
}

input_box() {
  local title="$1"
  local text="$2"
  local default_value="$3"
  local var_name="$4"

  local value
  value=$(whiptail --inputbox "$text" 10 78 "$default_value" --title "$title" 3>&1 1>&2 2>&3) || {
    echo "Cancelled"
    exit 1
  }
  eval "$var_name=\"$value\""
}

password_box() {
  local title="$1"
  local text="$2"
  local var_name="$3"

  local value
  value=$(whiptail --passwordbox "$text" 10 78 --title "$title" 3>&1 1>&2 2>&3) || {
    echo "Cancelled"
    exit 1
  }
  eval "$var_name=\"$value\""
}

msg_box() {
  whiptail --msgbox "$2" 12 78 --title "$1"
}

sanitize_cluster_slug() {
  local raw="$1"
  local slug=""

  slug=$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')

  echo "$slug"
}

choose_cluster_slug() {
  local selected=""
  local custom_name=""
  local sanitized=""

  while true; do
    selected=$(whiptail --menu "Choose a cluster name. Suggested presets:\n\n- ontwikkel\n- test\n- productie" 18 78 6 \
      "ontwikkel" "Development cluster" \
      "test" "Testing cluster" \
      "productie" "Production cluster" \
      "aangepast" "Custom cluster name" \
      3>&1 1>&2 2>&3) || {
      echo "Cancelled"
      exit 0
    }

    if [[ "$selected" == "aangepast" ]]; then
      custom_name=$(whiptail --inputbox "Custom cluster name" 10 78 "" --title "Cluster Name" 3>&1 1>&2 2>&3) || {
        echo "Cancelled"
        exit 0
      }
      sanitized=$(sanitize_cluster_slug "$custom_name")
    else
      sanitized=$(sanitize_cluster_slug "$selected")
    fi

    if [[ -n "$sanitized" ]]; then
      CLUSTER_SLUG="$sanitized"
      return 0
    fi

    msg_box "Invalid cluster name" "Cluster names can only contain letters, numbers and dashes after normalization.\n\nTry again."
  done
}

set_cluster_naming_defaults() {
  CLUSTER_VM_PREFIX="twinbox-${CLUSTER_SLUG}-"
  CLUSTER_VM_TAG="cluster-${CLUSTER_SLUG}"
  TWINBOX_TARGET_DIR="/opt/twinbox-${CLUSTER_SLUG}"
  MGT_NAME="${CLUSTER_VM_PREFIX}mgt"
  CLOUD_INIT_USER="twinbox-${CLUSTER_SLUG}"
  PROXMOX_USER="twinbox-${CLUSTER_SLUG}@pve"
  PROXMOX_ROLE="TwinboxVMProvisioner-${CLUSTER_SLUG}"
}

detect_existing_cluster_resources() {
  local vmid=""
  local config=""
  local name=""
  local tags=""
  local snippet=""

  EXISTING_VM_IDS=()
  EXISTING_VM_NAMES=()
  EXISTING_SNIPPETS=()
  EXISTING_USER_PRESENT=0
  EXISTING_ROLE_PRESENT=0

  while read -r vmid; do
    [[ -n "$vmid" ]] || continue
    config=$(qm config "$vmid" 2>/dev/null || true)
    [[ -n "$config" ]] || continue

    name=$(printf '%s\n' "$config" | awk -F': ' '/^name:/ {print $2; exit}')
    tags=$(printf '%s\n' "$config" | awk -F': ' '/^tags:/ {print $2; exit}')
    [[ -n "$name" && -n "$tags" ]] || continue

    if [[ "$name" == "${CLUSTER_VM_PREFIX}"* ]] && [[ "$tags" =~ (^|;)${CLUSTER_VM_TAG}($|;) ]]; then
      EXISTING_VM_IDS+=("$vmid")
      EXISTING_VM_NAMES+=("$name")
    fi
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')

  if pveum user list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$PROXMOX_USER"; then
    EXISTING_USER_PRESENT=1
  fi

  if pveum role list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$PROXMOX_ROLE"; then
    EXISTING_ROLE_PRESENT=1
  fi

  while read -r snippet; do
    [[ -n "$snippet" ]] || continue
    EXISTING_SNIPPETS+=("$snippet")
  done < <(find /var/lib/vz/snippets -maxdepth 1 -type f -name "twinbox-${CLUSTER_SLUG}-*.yaml" 2>/dev/null | sort)
}

cluster_resources_exist() {
  if [[ "${#EXISTING_VM_IDS[@]}" -gt 0 || "${#EXISTING_SNIPPETS[@]}" -gt 0 || "${EXISTING_USER_PRESENT}" -eq 1 || "${EXISTING_ROLE_PRESENT}" -eq 1 ]]; then
    return 0
  fi
  return 1
}

render_existing_cluster_inventory() {
  local summary=""
  local idx=0

  summary+="Detected resources for cluster '${CLUSTER_SLUG}':"$'\n'$'\n'
  summary+="VMs:"$'\n'
  if [[ "${#EXISTING_VM_IDS[@]}" -gt 0 ]]; then
    for idx in "${!EXISTING_VM_IDS[@]}"; do
      summary+="  - VMID ${EXISTING_VM_IDS[$idx]} (${EXISTING_VM_NAMES[$idx]})"$'\n'
    done
  else
    summary+="  - none"$'\n'
  fi

  summary+=$'\n'"Snippets:"$'\n'
  if [[ "${#EXISTING_SNIPPETS[@]}" -gt 0 ]]; then
    for snippet in "${EXISTING_SNIPPETS[@]}"; do
      summary+="  - ${snippet}"$'\n'
    done
  else
    summary+="  - none"$'\n'
  fi

  summary+=$'\n'"Proxmox API user:"$'\n'
  if [[ "${EXISTING_USER_PRESENT}" -eq 1 ]]; then
    summary+="  - ${PROXMOX_USER}"$'\n'
  else
    summary+="  - none"$'\n'
  fi

  summary+=$'\n'"Proxmox role:"$'\n'
  if [[ "${EXISTING_ROLE_PRESENT}" -eq 1 ]]; then
    summary+="  - ${PROXMOX_ROLE}"$'\n'
  else
    summary+="  - none"$'\n'
  fi

  printf '%s' "$summary"
}

cleanup_existing_cluster_resources() {
  local idx=0
  local vmid=""
  local vm_name=""
  local snippet=""
  local acl_path=""

  status_update "Removing resources for existing cluster ${CLUSTER_SLUG}"

  for idx in "${!EXISTING_VM_IDS[@]}"; do
    vmid="${EXISTING_VM_IDS[$idx]}"
    vm_name="${EXISTING_VM_NAMES[$idx]}"
    status_update "Destroying VM ${vmid} (${vm_name})"
    qm stop "$vmid" --skiplock 1 >/dev/null 2>&1 || true
    qm destroy "$vmid" --purge 1 >/dev/null 2>&1 || true
  done

  for snippet in "${EXISTING_SNIPPETS[@]}"; do
    status_update "Removing snippet ${snippet}"
    rm -f "$snippet" || true
  done

  for acl_path in /vms /storage "/nodes/${PROXMOX_NODE}" /sdn; do
    pveum aclmod "$acl_path" -user "$PROXMOX_USER" -delete 1 >/dev/null 2>&1 || true
  done

  if [[ "${EXISTING_USER_PRESENT}" -eq 1 ]]; then
    status_update "Removing Proxmox API user ${PROXMOX_USER}"
    pveum user delete "$PROXMOX_USER" >/dev/null 2>&1 || true
  fi

  if [[ "${EXISTING_ROLE_PRESENT}" -eq 1 ]]; then
    status_update "Removing Proxmox role ${PROXMOX_ROLE}"
    pveum role delete "$PROXMOX_ROLE" >/dev/null 2>&1 || true
  fi

  msg_ok "Existing cluster resources removed"
}

handle_existing_cluster_conflict() {
  local inventory=""
  local confirm_slug=""

  detect_existing_cluster_resources
  if ! cluster_resources_exist; then
    return 0
  fi

  inventory=$(render_existing_cluster_inventory)

  if ! whiptail --yesno "A cluster with slug '${CLUSTER_SLUG}' already exists.\n\n${inventory}\nThis action permanently deletes the listed resources.\n\nDo you want to continue?" 32 100 --title "Cluster already exists"; then
    echo "Cancelled"
    exit 0
  fi

  confirm_slug=$(whiptail --inputbox "Type the cluster slug to confirm deletion:\n\n${CLUSTER_SLUG}" 12 78 --title "Confirm cluster deletion" 3>&1 1>&2 2>&3) || {
    echo "Cancelled"
    exit 0
  }

  if [[ "$confirm_slug" != "$CLUSTER_SLUG" ]]; then
    msg_error "Cluster slug did not match. Aborting cleanup."
    exit 1
  fi

  cleanup_existing_cluster_resources

  if whiptail --yesno "Cleanup completed for cluster '${CLUSTER_SLUG}'.\n\nDo you want to recreate it now?" 12 78 --title "Recreate cluster"; then
    return 0
  fi

  echo "Cancelled"
  exit 0
}

guess_ssh_public_key() {
  local key=""

  for candidate in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys; do
    if [[ -f "$candidate" ]]; then
      key=$(head -n1 "$candidate")
      if [[ -n "$key" ]]; then
        echo "$key"
        return 0
      fi
    fi
  done

  return 1
}

guess_bridge_interface() {
  if command -v brctl >/dev/null 2>&1; then
    if brctl show vmbr0 >/dev/null 2>&1; then
      echo "vmbr0"
      return 0
    fi
  fi

  ip -o link show | awk -F': ' '/vmbr/ {print $2; exit}'
}

guess_next_vmid() {
  local cluster_vms=""
  local used_vmids=""
  local candidate=100

  cluster_vms=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || true)
  if [[ -n "$cluster_vms" ]]; then
    used_vmids=$(printf '%s\n' "$cluster_vms" \
      | grep -Eo '"vmid"[[:space:]]*:[[:space:]]*[0-9]+' \
      | grep -Eo '[0-9]+' \
      | sort -n \
      | uniq)
  else
    used_vmids=$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | uniq || true)
  fi

  while printf '%s\n' "$used_vmids" | grep -qx "$candidate"; do
    candidate=$((candidate + 1))
  done

  echo "$candidate"
}

guess_free_management_ip() {
  local host_ip="$1"
  local first="" second="" third="" fourth=""
  local candidate_octet=50
  local candidate=""

  if [[ -z "${host_ip:-}" ]]; then
    return 1
  fi

  IFS='.' read -r first second third fourth <<<"$host_ip"
  if [[ -z "$first" || -z "$second" || -z "$third" || -z "$fourth" ]]; then
    return 1
  fi
  if ! [[ "$first" =~ ^[0-9]+$ && "$second" =~ ^[0-9]+$ && "$third" =~ ^[0-9]+$ && "$fourth" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  for ((candidate_octet = 50; candidate_octet <= 254; candidate_octet++)); do
    candidate="${first}.${second}.${third}.${candidate_octet}"
    if [[ "$candidate" == "$host_ip" ]]; then
      continue
    fi
    if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
      continue
    fi
    echo "$candidate"
    return 0
  done

  return 1
}

cidr_to_netmask() {
  local cidr="$1"
  local i octet mask=""

  for ((i = 0; i < 4; i++)); do
    if ((cidr >= 8)); then
      octet=255
      cidr=$((cidr - 8))
    elif ((cidr == 0)); then
      octet=0
    else
      octet=$((256 - 2 ** (8 - cidr)))
      cidr=0
    fi

    mask+="$octet"
    if [[ "$i" -lt 3 ]]; then
      mask+="."
    fi
  done

  echo "$mask"
}

netmask_to_cidr() {
  local netmask="$1"
  local cidr=0
  local octets=()
  local octet=""
  local seen_partial_or_zero=0

  IFS='.' read -r -a octets <<<"$netmask"
  if [[ "${#octets[@]}" -ne 4 ]]; then
    return 1
  fi

  for octet in "${octets[@]}"; do
    if [[ "$octet" -eq 255 ]]; then
      if [[ "$seen_partial_or_zero" -eq 1 ]]; then
        return 1
      fi
      cidr=$((cidr + 8))
      continue
    fi

    case "$octet" in
      254|252|248|240|224|192|128)
        if [[ "$seen_partial_or_zero" -eq 1 ]]; then
          return 1
        fi
        case "$octet" in
          254) cidr=$((cidr + 7)) ;;
          252) cidr=$((cidr + 6)) ;;
          248) cidr=$((cidr + 5)) ;;
          240) cidr=$((cidr + 4)) ;;
          224) cidr=$((cidr + 3)) ;;
          192) cidr=$((cidr + 2)) ;;
          128) cidr=$((cidr + 1)) ;;
        esac
        seen_partial_or_zero=1
        ;;
      0)
        seen_partial_or_zero=1
        ;;
      *)
        return 1
        ;;
    esac
  done

  echo "$cidr"
}

generate_cloud_init_password() {
  local generated=""

  while [[ ${#generated} -lt 20 ]]; do
    generated=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20)
  done

  echo "$generated"
}

apply_educated_defaults() {
  local detected_host
  local detected_prefix
  local detected_gateway
  local free_management_ip

  detected_host=$(hostname -I | awk '{print $1}')
  detected_prefix=$(ip -o -f inet addr show scope global | awk 'NR==1 {split($4, a, "/"); print a[2]}')
  detected_gateway=$(ip route | awk '/^default/ {print $3; exit}')
  detected_dns_ip=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)
  free_management_ip=$(guess_free_management_ip "${detected_host:-}" || true)
  guessed_bridge=$(guess_bridge_interface || true)
  guessed_ssh_key=$(guess_ssh_public_key || true)

  set_cluster_naming_defaults
  MGT_ID=$(guess_next_vmid)
  MGT_RAM="4096"
  MGT_CORES="2"
  MGT_CPU_TYPE="host"
  MGT_DISK="40"
  BRIDGE_IF="${guessed_bridge:-vmbr0}"
  CLOUD_INIT_PASSWORD=""
  CLOUD_INIT_IP="${free_management_ip:-192.168.1.50}"
  CLOUD_INIT_NETMASK="$(cidr_to_netmask "${detected_prefix:-24}")"
  CLOUD_INIT_GATEWAY="${detected_gateway:-192.168.1.1}"
  CLOUD_INIT_DNS_DOMAIN="localdomain"
  CLOUD_INIT_DNS_IP="${detected_dns_ip:-1.1.1.1}"
  SSH_KEY="${guessed_ssh_key:-}"

  PROXMOX_HOST="${detected_host:-192.168.1.10}"
  PROXMOX_PORT="8006"
  PROXMOX_PASSWORD=$(generate_cloud_init_password)
  PROXMOX_NODE="$(hostname)"
  PROXMOX_STORAGE_POOL="local-lvm"
  PROXMOX_ISO_STORAGE="local"
  TALOS_ISO_FILE="talos-v1.7.4.iso"
  TALOSCTL_VERSION="v1.7.4"
  KUBECTL_VERSION="v1.30.0"
  HELM_VERSION="v3.15.4"
  TWINBOX_IMAGE_TAG="latest"
}

create_proxmox_api_user() {
  local proxmox_privs="VM.Allocate,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Config.HWType,VM.PowerMgmt,Datastore.AllocateSpace,Datastore.Audit,SDN.Use"
  local create_err=""
  local role_err=""
  local last_err=""
  local acl_path=""

  set_proxmox_password_with_retry() {
    local user="$1"
    local password="$2"
    local retries="${3:-10}"
    local delay="${4:-1}"
    local attempt=0
    while [[ "$attempt" -lt "$retries" ]]; do
      if last_err=$(printf '%s\n%s\n' "$password" "$password" | pveum passwd "$user" 2>&1); then
        last_err=""
        return 0
      fi
      attempt=$((attempt + 1))
      sleep "$delay"
    done
    return 1
  }

  apply_acl_with_retry() {
    local path="$1"
    local user="$2"
    local role="$3"
    local retries="${4:-10}"
    local delay="${5:-1}"
    local attempt=0
    while [[ "$attempt" -lt "$retries" ]]; do
      if last_err=$(pveum aclmod "$path" -user "$user" -role "$role" 2>&1); then
        last_err=""
        return 0
      fi
      attempt=$((attempt + 1))
      sleep "$delay"
    done
    return 1
  }

  status_update "Ensuring Proxmox API user ${PROXMOX_USER} exists"
  if create_err=$(pveum user add "$PROXMOX_USER" --comment "Twinbox service account (${CLUSTER_SLUG})" 2>&1); then
    status_update "Created Proxmox API user ${PROXMOX_USER}"
  else
    if printf '%s' "$create_err" | grep -qi "already exists"; then
      status_update "Proxmox API user ${PROXMOX_USER} already exists"
    else
      msg_error "Failed to create Proxmox API user ${PROXMOX_USER}: ${create_err}"
      exit 1
    fi
  fi

  status_update "Setting password for ${PROXMOX_USER}"
  if ! set_proxmox_password_with_retry "$PROXMOX_USER" "$PROXMOX_PASSWORD" 15 1; then
    msg_error "Failed to set password for Proxmox API user ${PROXMOX_USER}: ${last_err}"
    exit 1
  fi

  status_update "Ensuring least-privilege role ${PROXMOX_ROLE}"
  if role_err=$(pveum role add "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1); then
    :
  else
    if printf '%s' "$role_err" | grep -qi "already exists"; then
      if ! role_err=$(pveum role modify "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1); then
        msg_error "Failed to update Proxmox role ${PROXMOX_ROLE}: ${role_err}"
        exit 1
      fi
    else
      msg_error "Failed to create Proxmox role ${PROXMOX_ROLE}: ${role_err}"
      exit 1
    fi
  fi

  status_update "Applying ACLs for ${PROXMOX_USER}"
  for acl_path in /vms /storage "/nodes/${PROXMOX_NODE}"; do
    if ! apply_acl_with_retry "$acl_path" "$PROXMOX_USER" "$PROXMOX_ROLE" 10 1; then
      msg_error "Failed to apply ACL ${acl_path} for ${PROXMOX_USER}: ${last_err}"
      exit 1
    fi
  done
  if ! apply_acl_with_retry "/sdn" "$PROXMOX_USER" "$PROXMOX_ROLE" 10 1; then
    msg_error "Failed to apply ACL /sdn for ${PROXMOX_USER}: ${last_err}"
    exit 1
  fi
}

collect_manual_overrides() {
  if review_management_settings; then
    input_box "Management VM" "Management VM name (name shown in Proxmox UI)" "$MGT_NAME" MGT_NAME
    input_box "Management VM" "Management VM ID (unique VMID in Proxmox)" "$MGT_ID" MGT_ID
    input_box "Management VM" "Management VM RAM (MB) for manager services" "$MGT_RAM" MGT_RAM
    input_box "Management VM" "Management VM CPU cores for manager services" "$MGT_CORES" MGT_CORES
    input_box "Management VM" "Management VM CPU type (use host or x86-64-v2-AES for latest talosctl)" "$MGT_CPU_TYPE" MGT_CPU_TYPE
    input_box "Management VM" "Management VM disk size (GB) for OS + images" "$MGT_DISK" MGT_DISK
    input_box "Management VM" "Bridge interface (bridge used for VM network interface)" "$BRIDGE_IF" BRIDGE_IF
  fi

  if review_cloud_init_settings; then
    input_box "Cloud-Init" "SSH public key (used for initial SSH access)" "$SSH_KEY" SSH_KEY
    input_box "Cloud-Init" "DNS search domain (search domain used in /etc/resolv.conf)" "$CLOUD_INIT_DNS_DOMAIN" CLOUD_INIT_DNS_DOMAIN
    input_box "Cloud-Init" "DNS server IP (resolver IP for management VM)" "$CLOUD_INIT_DNS_IP" CLOUD_INIT_DNS_IP
    input_box "Cloud-Init" "Static IPv4 address (management VM)" "$CLOUD_INIT_IP" CLOUD_INIT_IP
    input_box "Cloud-Init" "Netmask (for example 255.255.255.0)" "$CLOUD_INIT_NETMASK" CLOUD_INIT_NETMASK
    input_box "Cloud-Init" "Default route (gateway)" "$CLOUD_INIT_GATEWAY" CLOUD_INIT_GATEWAY
  fi

  if review_manager_env_settings; then
    input_box "Manager .env" "Proxmox API host (used by worker to call Proxmox API)" "$PROXMOX_HOST" PROXMOX_HOST
    input_box "Manager .env" "Proxmox API port (usually 8006)" "$PROXMOX_PORT" PROXMOX_PORT
    input_box "Manager .env" "Proxmox API user (service account user@realm)" "$PROXMOX_USER" PROXMOX_USER
    input_box "Manager .env" "Proxmox node (target node for VM creation)" "$PROXMOX_NODE" PROXMOX_NODE
    input_box "Manager .env" "Proxmox storage pool (disk target for Talos VMs)" "$PROXMOX_STORAGE_POOL" PROXMOX_STORAGE_POOL
    input_box "Manager .env" "Proxmox ISO storage (where Talos ISO is stored)" "$PROXMOX_ISO_STORAGE" PROXMOX_ISO_STORAGE
    input_box "Manager .env" "Talos ISO file (filename in ISO storage)" "$TALOS_ISO_FILE" TALOS_ISO_FILE
    input_box "Manager .env" "Talosctl version (tooling on management host and worker)" "$TALOSCTL_VERSION" TALOSCTL_VERSION
    input_box "Manager .env" "kubectl version (tooling on management host and worker)" "$KUBECTL_VERSION" KUBECTL_VERSION
    input_box "Manager .env" "Helm version (tooling on management host and worker)" "$HELM_VERSION" HELM_VERSION
    input_box "Manager .env" "Image tag (Twinbox container image tag)" "$TWINBOX_IMAGE_TAG" TWINBOX_IMAGE_TAG
  fi
}

review_management_settings() {
  if whiptail --yesno "Management VM settings\n\nName: $MGT_NAME\nVMID: $MGT_ID\nRAM: ${MGT_RAM}MB\nCPU cores: $MGT_CORES\nCPU type: $MGT_CPU_TYPE\nDisk: ${MGT_DISK}GB\nBridge: $BRIDGE_IF\n\nEdit this group?" 20 78 --title "Management VM"; then
    return 0
  fi
  return 1
}

review_cloud_init_settings() {
  local ssh_key_detected="no"
  if [[ -n "${SSH_KEY:-}" ]]; then
    ssh_key_detected="yes"
  fi

  if whiptail --yesno "Cloud-Init settings\n\nUser: $CLOUD_INIT_USER\nDNS domain: $CLOUD_INIT_DNS_DOMAIN\nDNS server: $CLOUD_INIT_DNS_IP\nStatic IP: $CLOUD_INIT_IP\nNetmask: $CLOUD_INIT_NETMASK\nGateway: $CLOUD_INIT_GATEWAY\nSSH key detected: ${ssh_key_detected}\n\nEdit this group?" 22 78 --title "Cloud-Init"; then
    return 0
  fi
  return 1
}

review_manager_env_settings() {
  if whiptail --yesno "Manager API settings\n\nHost: $PROXMOX_HOST\nPort: $PROXMOX_PORT\nUser: $PROXMOX_USER\nNode: $PROXMOX_NODE\nStorage: $PROXMOX_STORAGE_POOL\nISO storage: $PROXMOX_ISO_STORAGE\nTalos ISO: $TALOS_ISO_FILE\nTalosctl: $TALOSCTL_VERSION\nkubectl: $KUBECTL_VERSION\nHelm: $HELM_VERSION\nImage tag: $TWINBOX_IMAGE_TAG\nTarget dir: $TWINBOX_TARGET_DIR\n\nEdit this group?" 25 78 --title "Manager .env"; then
    return 0
  fi
  return 1
}

start_wizard() {
  header_info
  choose_cluster_slug
  apply_educated_defaults
  handle_existing_cluster_conflict

  header_info
  msg_box "Twinbox Setup" "This wizard creates only the Management VM for cluster '${CLUSTER_SLUG}'.\n\nIt defaults to educated guesses and groups advanced values into 3 sections:\n- Management VM sizing/network\n- Cloud-Init access/network\n- Manager API/runtime settings\n\nYou can review each group and edit only what you need."

  if whiptail --yesno "Use recommended settings with educated guesses?" 10 78; then
    :
  else
    collect_manual_overrides
  fi

  if [[ -z "${SSH_KEY:-}" ]]; then
    input_box "Cloud-Init" "SSH public key" "" SSH_KEY
  fi
  if [[ -z "${SSH_KEY// }" ]]; then
    msg_error "SSH public key is required for initial access"
    exit 1
  fi

  password_box "Cloud-Init" "Twinbox login password" CLOUD_INIT_PASSWORD
  input_box "Cloud-Init" "Static IPv4 address (management VM)" "$CLOUD_INIT_IP" CLOUD_INIT_IP
  input_box "Cloud-Init" "Netmask (for example 255.255.255.0)" "$CLOUD_INIT_NETMASK" CLOUD_INIT_NETMASK
  input_box "Cloud-Init" "Default route (gateway)" "$CLOUD_INIT_GATEWAY" CLOUD_INIT_GATEWAY

  CLOUD_INIT_CIDR=$(netmask_to_cidr "$CLOUD_INIT_NETMASK") || {
    msg_error "Invalid netmask: ${CLOUD_INIT_NETMASK}"
    exit 1
  }

  msg_box "Security Notice" "Phase 1 is LAN-only and stores Proxmox credentials in ${TWINBOX_TARGET_DIR}/.env on the management VM.\n\nUse a dedicated Proxmox automation account and rotate credentials regularly."

  if whiptail --yesno "Proceed with installation?\n\nCluster: ${CLUSTER_SLUG}\nVM Name: $MGT_NAME\nVM ID: $MGT_ID\nCPU type: $MGT_CPU_TYPE\nBridge: $BRIDGE_IF\nCloud-Init user: $CLOUD_INIT_USER\nDNS: ${CLOUD_INIT_DNS_IP} (${CLOUD_INIT_DNS_DOMAIN})\nRepo: ${GITHUB_REPO}\nTarget dir: ${TWINBOX_TARGET_DIR}\nAuto-start manager stack: yes" 21 78; then
    create_proxmox_api_user
    create_management_vm
    print_next_steps
  else
    echo "Cancelled"
    exit 0
  fi
}

create_management_vm() {
  local ubuntu_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  local img_name="noble-server-cloudimg-amd64.img"
  local img_path="/var/lib/vz/template/cache/${img_name}"
  local CLOUD_INIT_PASSWORD_HASH=""

  CLOUD_INIT_PASSWORD_HASH=$(openssl passwd -6 "$CLOUD_INIT_PASSWORD")

  mkdir -p /var/lib/vz/template/cache /var/lib/vz/snippets

  status_update "Checking Ubuntu cloud image cache"
  if [[ ! -f "$img_path" ]]; then
    msg_info "Downloading Ubuntu 24.04 cloud image"
    curl -fsSL -o "$img_path" "$ubuntu_url"
    msg_ok "Ubuntu image downloaded"
  else
    msg_ok "Ubuntu image already present"
  fi

  ensure_talos_iso_available

  status_update "Preparing cloud-init configuration snippet"

  snippet_file="/var/lib/vz/snippets/twinbox-${CLUSTER_SLUG}-mgt-${MGT_ID}-user-data.yaml"

  cat > "$snippet_file" <<CLOUDINIT
#cloud-config
hostname: ${MGT_NAME}
manage_etc_hosts: true
ssh_pwauth: true
users:
  - name: ${CLOUD_INIT_USER}
    lock_passwd: false
    passwd: ${CLOUD_INIT_PASSWORD_HASH}
    groups: sudo,docker
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - ${SSH_KEY}
package_update: true
packages:
  - curl
  - git
  - ca-certificates
  - gnupg
  - qemu-guest-agent
write_files:
  - path: /tmp/twinbox-${CLUSTER_SLUG}.env.template
    permissions: '0600'
    owner: root:root
    content: |
      TWINBOX_CLUSTER_SLUG=${CLUSTER_SLUG}
      PROXMOX_HOST=${PROXMOX_HOST}
      PROXMOX_PORT=${PROXMOX_PORT}
      PROXMOX_USER=${PROXMOX_USER}
      PROXMOX_PASSWORD=${PROXMOX_PASSWORD}
      PROXMOX_NODE=${PROXMOX_NODE}
      PROXMOX_STORAGE_POOL=${PROXMOX_STORAGE_POOL}
      PROXMOX_ISO_STORAGE=${PROXMOX_ISO_STORAGE}
      TALOS_ISO_FILE=${TALOS_ISO_FILE}
      TALOSCTL_VERSION=${TALOSCTL_VERSION}
      KUBECTL_VERSION=${KUBECTL_VERSION}
      HELM_VERSION=${HELM_VERSION}
      TWINBOX_IMAGE_TAG=${TWINBOX_IMAGE_TAG}
runcmd:
  - install -m 0755 -d /etc/apt/keyrings
  - systemctl enable --now qemu-guest-agent
  - bash -lc 'apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true'
  - bash -lc 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc'
  - chmod a+r /etc/apt/keyrings/docker.asc
  - bash -lc 'echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list'
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - bash -lc 'docker --version'
  - bash -lc 'docker compose version'
  - install -d -m 0755 ${TWINBOX_TARGET_DIR}
  - chown ${CLOUD_INIT_USER}:${CLOUD_INIT_USER} ${TWINBOX_TARGET_DIR}
  - bash -lc 'if [ ! -d ${TWINBOX_TARGET_DIR}/.git ]; then git clone https://github.com/${GITHUB_REPO}.git ${TWINBOX_TARGET_DIR}; fi'
  - bash -lc 'cp /tmp/twinbox-${CLUSTER_SLUG}.env.template ${TWINBOX_TARGET_DIR}/.env'
  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && chmod +x scripts/install-management-tools.sh && ./scripts/install-management-tools.sh --env-file ${TWINBOX_TARGET_DIR}/.env'
  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && docker compose pull'
  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && docker compose up -d'
CLOUDINIT
  chmod 600 "$snippet_file"

  status_update "Creating VM shell in Proxmox"
  qm create "$MGT_ID" --name "$MGT_NAME" --memory "$MGT_RAM" --cores "$MGT_CORES" --cpu "$MGT_CPU_TYPE" --net0 "virtio,bridge=${BRIDGE_IF}" \
    --tags "twinbox;management;docker;bootstrap;${CLUSTER_VM_TAG}" \
    --scsihw virtio-scsi-pci --ide2 local-lvm:cloudinit --serial0 socket --vga serial0 --ostype l26 >/dev/null
  vm_created=1
  status_update "Importing base disk into VM storage"
  qm importdisk "$MGT_ID" "$img_path" local-lvm >/dev/null
  status_update "Applying cloud-init and boot configuration"
  qm set "$MGT_ID" --scsi0 "local-lvm:vm-${MGT_ID}-disk-0" >/dev/null
  qm set "$MGT_ID" --ciuser "$CLOUD_INIT_USER" >/dev/null
  qm set "$MGT_ID" --cipassword "$CLOUD_INIT_PASSWORD" >/dev/null
  qm set "$MGT_ID" --searchdomain "$CLOUD_INIT_DNS_DOMAIN" >/dev/null
  qm set "$MGT_ID" --nameserver "$CLOUD_INIT_DNS_IP" >/dev/null
  qm set "$MGT_ID" --ipconfig0 "ip=${CLOUD_INIT_IP}/${CLOUD_INIT_CIDR},gw=${CLOUD_INIT_GATEWAY}" >/dev/null
  qm set "$MGT_ID" --agent enabled=1 >/dev/null
  qm set "$MGT_ID" --cicustom "user=local:snippets/$(basename "$snippet_file")" >/dev/null
  qm set "$MGT_ID" --boot order=scsi0 >/dev/null
  qm resize "$MGT_ID" scsi0 "${MGT_DISK}G" >/dev/null
  status_update "Starting management VM"
  qm start "$MGT_ID" >/dev/null

  msg_ok "Management VM created"
}

ensure_talos_iso_available() {
  local talos_version=""
  local talos_url=""
  local iso_list=""
  local tmp_iso=""
  local storage_path=""
  local iso_target_dir=""

  status_update "Checking Talos ISO in storage ${PROXMOX_ISO_STORAGE}"
  iso_list=$(pvesm list "$PROXMOX_ISO_STORAGE" --content iso 2>/dev/null || true)
  if printf '%s\n' "$iso_list" | grep -Fq "iso/${TALOS_ISO_FILE}"; then
    msg_ok "Talos ISO already present (${TALOS_ISO_FILE})"
    return 0
  fi

  talos_version="${TALOS_ISO_FILE%.iso}"
  talos_version="${talos_version#talos-v}"
  talos_version="${talos_version#v}"
  if [[ -z "$talos_version" || "$talos_version" == "$TALOS_ISO_FILE" ]]; then
    msg_error "Could not derive Talos version from ${TALOS_ISO_FILE}"
    msg_error "Use format talos-vX.Y.Z.iso or pre-upload ISO to ${PROXMOX_ISO_STORAGE}"
    exit 1
  fi

  talos_url="https://github.com/siderolabs/talos/releases/download/v${talos_version}/metal-amd64.iso"
  msg_info "Downloading Talos ISO ${TALOS_ISO_FILE}"

  # pvesm download is not available on some Proxmox versions.
  if pvesm help 2>/dev/null | grep -q "pvesm download"; then
    if ! pvesm download "$PROXMOX_ISO_STORAGE" "$TALOS_ISO_FILE" "$talos_url" >/dev/null; then
      msg_error "Failed to download Talos ISO from ${talos_url}"
      exit 1
    fi
  else
    tmp_iso=$(mktemp "/tmp/${TALOS_ISO_FILE}.XXXXXX")
    if ! curl -fsSL "$talos_url" -o "$tmp_iso"; then
      rm -f "$tmp_iso"
      msg_error "Failed to download Talos ISO from ${talos_url}"
      exit 1
    fi

    storage_path=$(
      awk -v storage="$PROXMOX_ISO_STORAGE" '
        /^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*[a-zA-Z0-9_-]+[[:space:]]*$/ {
          in_storage = 0
          split($0, parts, ":")
          name = parts[2]
          sub(/^[[:space:]]+/, "", name)
          if (name == storage) {
            in_storage = 1
          }
          next
        }
        in_storage && $1 == "path" {
          print $2
          exit
        }
      ' /etc/pve/storage.cfg
    )
    iso_target_dir="${storage_path%/}/template/iso"

    if [[ -z "$storage_path" || "$storage_path" == "$PROXMOX_ISO_STORAGE" ]]; then
      rm -f "$tmp_iso"
      msg_error "Storage ${PROXMOX_ISO_STORAGE} has no filesystem path in /etc/pve/storage.cfg"
      msg_error "Upload ${TALOS_ISO_FILE} manually, then rerun the wizard"
      exit 1
    fi

    mkdir -p "$iso_target_dir"
    if ! install -m 0644 "$tmp_iso" "${iso_target_dir}/${TALOS_ISO_FILE}"; then
      rm -f "$tmp_iso"
      msg_error "Failed to place Talos ISO into ${iso_target_dir}"
      exit 1
    fi
    rm -f "$tmp_iso"
  fi

  iso_list=$(pvesm list "$PROXMOX_ISO_STORAGE" --content iso 2>/dev/null || true)
  if ! printf '%s\n' "$iso_list" | grep -Fq "iso/${TALOS_ISO_FILE}"; then
    msg_error "Talos ISO upload verification failed for ${PROXMOX_ISO_STORAGE}"
    exit 1
  fi
  msg_ok "Talos ISO downloaded (${TALOS_ISO_FILE})"
}

discover_management_vm_ip() {
  local attempts=24
  local output=""
  local ip=""
  local polls=1

  status_update "Waiting for guest agent to report management VM IP"
  while [[ "$attempts" -gt 0 ]]; do
    output=$(qm guest cmd "$MGT_ID" network-get-interfaces 2>/dev/null || true)
    ip=$(
      printf '%s\n' "$output" \
      | grep -Eo '"ip-address"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
      | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"/\1/' \
      | grep -Ev '^(127\.|169\.254\.)' \
      | head -n1
    )

    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi

    if (( polls % 3 == 0 )); then
      status_update "Still waiting for VM IP (retry ${polls}/24)"
    fi

    sleep 5
    attempts=$((attempts - 1))
    polls=$((polls + 1))
  done

  status_update "Guest agent did not report an IP within timeout"
  return 1
}

wait_for_web_interface() {
  local management_ip="$1"
  local attempts=72
  local polls=1
  local web_url="http://${management_ip}:3000"

  status_update "Waiting for web interface on ${web_url}"
  while [[ "$attempts" -gt 0 ]]; do
    if curl -sS --output /dev/null --connect-timeout 2 --max-time 3 "$web_url"; then
      status_update "Web interface is reachable on port 3000"
      return 0
    fi

    if (( polls % 6 == 0 )); then
      status_update "Web interface still starting (retry ${polls}/72)"
    fi

    sleep 5
    attempts=$((attempts - 1))
    polls=$((polls + 1))
  done

  status_update "Web interface did not become reachable within timeout"
  return 1
}

print_next_steps() {
  local management_ip=""
  local web_interface_ready=0
  management_ip=$(discover_management_vm_ip || true)

  if [[ -n "${management_ip:-}" ]] && wait_for_web_interface "$management_ip"; then
    web_interface_ready=1
  fi

  echo
  echo -e "${GN}Installation complete${CL}"
  echo
  echo "Next steps:"
  if [[ "$web_interface_ready" -eq 1 ]]; then
    echo "1. Web interface is up on port 3000."
    echo "2. Open: http://${management_ip}:3000"
    echo "3. Verify API health: http://${management_ip}:8080/api/health"
  elif [[ -n "${management_ip:-}" ]]; then
    echo "1. Web interface on port 3000 is not reachable yet."
    echo "2. Keep waiting for cloud-init/startup, then check: http://${management_ip}:3000"
    echo "3. Verify API health when ready: http://${management_ip}:8080/api/health"
  else
    echo "1. Wait for cloud-init on the management VM to finish."
    echo "2. Open: http://<management-vm-ip>:3000"
    echo "3. Verify API health: http://<management-vm-ip>:8080/api/health"
  fi
  echo "Login user: ${CLOUD_INIT_USER}"
  echo "Login password: ${CLOUD_INIT_PASSWORD}"
  echo "Proxmox API user: ${PROXMOX_USER}"
  echo "Proxmox API password: ${PROXMOX_PASSWORD}"
  echo "4. If needed, edit ${TWINBOX_TARGET_DIR}/.env and run: cd ${TWINBOX_TARGET_DIR} && docker compose up -d"
  echo
}

main() {
  trap cleanup_after_run EXIT
  check_root
  check_deps
  start_wizard
}

main "$@"
