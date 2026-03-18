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
allocation_file=""

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

  if [[ -n "${allocation_file:-}" && -f "$allocation_file" ]]; then
    rm -f "$allocation_file"
  fi

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

    if [[ "$tags" =~ (^|;)${CLUSTER_VM_TAG}($|;) ]]; then
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

is_valid_ipv4() {
  local value="$1"
  local part=""
  local -a parts=()

  IFS='.' read -r -a parts <<<"$value"
  if [[ "${#parts[@]}" -ne 4 ]]; then
    return 1
  fi

  for part in "${parts[@]}"; do
    if ! [[ "$part" =~ ^[0-9]+$ ]]; then
      return 1
    fi
    if (( part < 0 || part > 255 )); then
      return 1
    fi
  done

  return 0
}

trim_value() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "$value"
}

ip_to_int() {
  local a b c d
  IFS='.' read -r a b c d <<<"$1"
  echo "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

int_to_ip() {
  local value="$1"
  echo "$(( (value >> 24) & 255 )).$(( (value >> 16) & 255 )).$(( (value >> 8) & 255 )).$(( value & 255 ))"
}

guess_free_vmid_block() {
  local block_size="$1"
  local cluster_vms=""
  local used_vmids=""
  local -A used_map=()
  local candidate=100
  local offset=0
  local vmid=""

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

  while IFS= read -r vmid; do
    [[ -n "$vmid" ]] || continue
    used_map["$vmid"]=1
  done <<<"$used_vmids"

  while [[ "$candidate" -le 999999 ]]; do
    offset=0
    while [[ "$offset" -lt "$block_size" ]]; do
      if [[ -n "${used_map[$((candidate + offset))]:-}" ]]; then
        break
      fi
      offset=$((offset + 1))
    done

    if [[ "$offset" -eq "$block_size" ]]; then
      echo "$candidate"
      return 0
    fi

    candidate=$((candidate + 1))
  done

  return 1
}

guess_free_ip_block() {
  local host_ip="$1"
  local block_size="$2"
  local first=""
  local second=""
  local third=""
  local fourth=""
  local candidate_octet=50
  local offset=0
  local candidate_ip=""

  if [[ -z "${host_ip:-}" ]]; then
    echo "192.168.1.50"
    return 0
  fi

  IFS='.' read -r first second third fourth <<<"$host_ip"
  if [[ -z "$first" || -z "$second" || -z "$third" || -z "$fourth" ]]; then
    echo "192.168.1.50"
    return 0
  fi
  if ! [[ "$first" =~ ^[0-9]+$ && "$second" =~ ^[0-9]+$ && "$third" =~ ^[0-9]+$ && "$fourth" =~ ^[0-9]+$ ]]; then
    echo "192.168.1.50"
    return 0
  fi

  while [[ "$candidate_octet" -le 254 ]]; do
    if (( candidate_octet + block_size - 1 > 254 )); then
      break
    fi

    offset=0
    while [[ "$offset" -lt "$block_size" ]]; do
      candidate_ip="${first}.${second}.${third}.$((candidate_octet + offset))"
      if [[ "$candidate_ip" == "$host_ip" ]]; then
        break
      fi
      if ping -c 1 -W 1 "$candidate_ip" >/dev/null 2>&1; then
        break
      fi
      offset=$((offset + 1))
    done

    if [[ "$offset" -eq "$block_size" ]]; then
      echo "${first}.${second}.${third}.${candidate_octet}"
      return 0
    fi

    candidate_octet=$((candidate_octet + 1))
  done

  echo "${first}.${second}.${third}.50"
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
  local cluster_block_vmid
  local cluster_block_ip
  local total_vmids
  local total_ips

  detected_host=$(hostname -I | awk '{print $1}')
  detected_prefix=$(ip -o -f inet addr show scope global | awk 'NR==1 {split($4, a, "/"); print a[2]}')
  detected_gateway=$(ip route | awk '/^default/ {print $3; exit}')
  detected_dns_ip=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)
  guessed_bridge=$(guess_bridge_interface || true)
  guessed_ssh_key=$(guess_ssh_public_key || true)

  set_cluster_naming_defaults
  CLUSTER_NAME="${CLUSTER_SLUG}"
  CLUSTER_CONTROLPLANE_COUNT="1"
  CLUSTER_WORKER_COUNT="2"
  total_vmids=$((1 + CLUSTER_CONTROLPLANE_COUNT + CLUSTER_WORKER_COUNT))
  total_ips=$((2 + CLUSTER_CONTROLPLANE_COUNT + CLUSTER_WORKER_COUNT))
  cluster_block_vmid=$(guess_free_vmid_block "$total_vmids" || true)
  cluster_block_ip=$(guess_free_ip_block "${detected_host:-}" "$total_ips" || true)

  MGT_ID="${cluster_block_vmid:-$(guess_next_vmid)}"
  MGT_RAM="4096"
  MGT_CORES="2"
  MGT_CPU_TYPE="host"
  MGT_DISK="40"
  BRIDGE_IF="${guessed_bridge:-vmbr0}"
  CLOUD_INIT_PASSWORD=""
  CLOUD_INIT_IP="${cluster_block_ip:-192.168.1.50}"
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
    input_box "Management VM" "Management VM RAM (MB) for manager services" "$MGT_RAM" MGT_RAM
    input_box "Management VM" "Management VM CPU cores for manager services" "$MGT_CORES" MGT_CORES
    input_box "Management VM" "Management VM CPU type (use host or x86-64-v2-AES for latest talosctl)" "$MGT_CPU_TYPE" MGT_CPU_TYPE
    input_box "Management VM" "Management VM disk size (GB) for OS + images" "$MGT_DISK" MGT_DISK
    input_box "Management VM" "Bridge interface (bridge used for VM network interface)" "$BRIDGE_IF" BRIDGE_IF
  fi

  if review_cloud_init_settings; then
    input_box "Cloud-Init" "SSH public key (used for initial SSH access)" "$SSH_KEY" SSH_KEY
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
  if whiptail --yesno "Management VM settings\n\nName: $MGT_NAME\nRAM: ${MGT_RAM}MB\nCPU cores: $MGT_CORES\nCPU type: $MGT_CPU_TYPE\nDisk: ${MGT_DISK}GB\nBridge: $BRIDGE_IF\n\nThe allocation grid sets VMID, IP and future cluster ranges.\n\nEdit this group?" 22 78 --title "Management VM"; then
    return 0
  fi
  return 1
}

review_cloud_init_settings() {
  local ssh_key_detected="no"
  if [[ -n "${SSH_KEY:-}" ]]; then
    ssh_key_detected="yes"
  fi

  if whiptail --yesno "Cloud-Init settings\n\nUser: $CLOUD_INIT_USER\nSSH key detected: ${ssh_key_detected}\n\nThe allocation grid fills the management VM network fields.\n\nEdit this group?" 18 78 --title "Cloud-Init"; then
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

build_cluster_allocation_rows() {
  local -n _rows_roles="$1"
  local -n _rows_vmids="$2"
  local -n _rows_names="$3"
  local -n _rows_ips="$4"
  local -n _rows_subnets="$5"
  local -n _rows_gateways="$6"
  local -n _rows_dns="$7"
  local base_vmid="$8"
  local base_ip="$9"
  local subnet="${10}"
  local gateway="${11}"
  local dns="${12}"
  local cp_count="${13}"
  local worker_count="${14}"
  local index=0
  local next_vmid="$base_vmid"
  local next_ip_int
  local next_ip=""
  local role=""

  next_ip_int=$(ip_to_int "$base_ip")

  _rows_roles=()
  _rows_vmids=()
  _rows_names=()
  _rows_ips=()
  _rows_subnets=()
  _rows_gateways=()
  _rows_dns=()

  _rows_roles+=("management")
  _rows_vmids+=("$next_vmid")
  _rows_names+=("${MGT_NAME}")
  _rows_ips+=("$base_ip")
  _rows_subnets+=("$subnet")
  _rows_gateways+=("$gateway")
  _rows_dns+=("$dns")

  next_ip_int=$((next_ip_int + 1))
  next_ip=$(int_to_ip "$next_ip_int")
  _rows_roles+=("vip")
  _rows_vmids+=("")
  _rows_names+=("twinbox-vip")
  _rows_ips+=("$next_ip")
  _rows_subnets+=("$subnet")
  _rows_gateways+=("$gateway")
  _rows_dns+=("$dns")

  next_vmid=$((next_vmid + 1))
  next_ip_int=$((next_ip_int + 1))

  for ((index = 1; index <= cp_count; index++)); do
    role="twinbox-cp-${index}"
    _rows_roles+=("controlplane-${index}")
    next_ip=$(int_to_ip "$next_ip_int")
    _rows_vmids+=("$next_vmid")
    _rows_names+=("$role")
    _rows_ips+=("$next_ip")
    _rows_subnets+=("$subnet")
    _rows_gateways+=("$gateway")
    _rows_dns+=("$dns")
    next_vmid=$((next_vmid + 1))
    next_ip_int=$((next_ip_int + 1))
  done

  for ((index = 1; index <= worker_count; index++)); do
    role="twinbox-worker-${index}"
    _rows_roles+=("worker-${index}")
    next_ip=$(int_to_ip "$next_ip_int")
    _rows_vmids+=("$next_vmid")
    _rows_names+=("$role")
    _rows_ips+=("$next_ip")
    _rows_subnets+=("$subnet")
    _rows_gateways+=("$gateway")
    _rows_dns+=("$dns")
    next_vmid=$((next_vmid + 1))
    next_ip_int=$((next_ip_int + 1))
  done
}

render_cluster_allocation_table() {
  local -n _rows_roles="$1"
  local -n _rows_vmids="$2"
  local -n _rows_names="$3"
  local -n _rows_ips="$4"
  local -n _rows_subnets="$5"
  local -n _rows_gateways="$6"
  local -n _rows_dns="$7"
  local output=""
  local i=""

  output+="role | vmid | name | ip | subnet | gateway | dns\n"
  output+="----- | ---- | ---- | -- | ------ | ------- | ---\n"

  for i in "${!_rows_names[@]}"; do
    output+="${_rows_roles[$i]} | ${_rows_vmids[$i]:--} | ${_rows_names[$i]} | ${_rows_ips[$i]} | ${_rows_subnets[$i]} | ${_rows_gateways[$i]} | ${_rows_dns[$i]}\n"
  done

  printf '%b' "$output"
}

edit_cluster_allocation_table() {
  local title="$1"
  local rows_file=""
  local -n _rows_roles="$2"
  local -n _rows_vmids="$3"
  local -n _rows_names="$4"
  local -n _rows_ips="$5"
  local -n _rows_subnets="$6"
  local -n _rows_gateways="$7"
  local -n _rows_dns="$8"
  local row_count="${#_rows_names[@]}"
  local form_height=$((row_count + 2))
  local form_width=120
  local prompt="Edit the proposed allocation grid.\n\nColumns: vmid, name, ip, subnet, gateway, dns\nLeave a vmid blank for rows that are not actual VMs."
  local form_output=""
  local -a form_args=()
  local i=0
  local base_y=1
  local row_y=0
  local spec_y=0
  local spec_x=0

  form_args=(--form "$prompt" "$((form_height + 8))" "$form_width" "$form_height")
  for ((i = 0; i < row_count; i++)); do
    row_y=$((base_y + i))
    spec_y="$row_y"
    spec_x=1
    form_args+=("VMID" "$spec_y" "$spec_x" "${_rows_vmids[$i]:--}" "$spec_y" 7 8 8)
    form_args+=("NAME" "$spec_y" 18 "${_rows_names[$i]}" "$spec_y" 24 18 32)
    form_args+=("IP" "$spec_y" 46 "${_rows_ips[$i]}" "$spec_y" 49 16 16)
    form_args+=("SUBNET" "$spec_y" 66 "${_rows_subnets[$i]}" "$spec_y" 73 16 16)
    form_args+=("GATEWAY" "$spec_y" 86 "${_rows_gateways[$i]}" "$spec_y" 94 16 16)
    form_args+=("DNS" "$spec_y" 107 "${_rows_dns[$i]}" "$spec_y" 111 16 16)
  done

  form_output=$(whiptail "${form_args[@]}" 3>&1 1>&2 2>&3) || return 1

  allocation_file=$(mktemp)
  printf '%s\n' "$form_output" > "$allocation_file"

  mapfile -t form_lines < "$allocation_file"
  if [[ "${#form_lines[@]}" -lt $((row_count * 6)) ]]; then
    msg_error "Allocation grid returned incomplete data"
    return 1
  fi

  for ((i = 0; i < row_count; i++)); do
    _rows_vmids[$i]=$(trim_value "${form_lines[$((i * 6 + 0))]}")
    _rows_names[$i]=$(trim_value "${form_lines[$((i * 6 + 1))]}")
    _rows_ips[$i]=$(trim_value "${form_lines[$((i * 6 + 2))]}")
    _rows_subnets[$i]=$(trim_value "${form_lines[$((i * 6 + 3))]}")
    _rows_gateways[$i]=$(trim_value "${form_lines[$((i * 6 + 4))]}")
    _rows_dns[$i]=$(trim_value "${form_lines[$((i * 6 + 5))]}")
  done
}

collect_cluster_allocation() {
  local base_vmid="$1"
  local base_ip="$2"
  local subnet="$3"
  local gateway="$4"
  local dns="$5"
  local cp_count="$6"
  local worker_count="$7"
  local -n _rows_vmids="$8"
  local -n _rows_names="$9"
  local -n _rows_ips="${10}"
  local -n _rows_subnets="${11}"
  local -n _rows_gateways="${12}"
  local -n _rows_dns="${13}"
  local -n _rows_roles="${14}"

  build_cluster_allocation_rows _rows_roles _rows_vmids _rows_names _rows_ips _rows_subnets _rows_gateways _rows_dns \
    "$base_vmid" "$base_ip" "$subnet" "$gateway" "$dns" "$cp_count" "$worker_count"

  msg_box "Cluster Allocation" "Review the proposed allocation grid.\n\nIt reserves a contiguous VMID/IP block for the management VM, VIP and future Talos nodes.\n\nYou can edit any field before continuing."

  if ! edit_cluster_allocation_table "Cluster Allocation" _rows_roles _rows_vmids _rows_names _rows_ips _rows_subnets _rows_gateways _rows_dns; then
    exit 1
  fi

  if [[ -z "${_rows_vmids[0]:-}" || ! "${_rows_vmids[0]}" =~ ^[0-9]+$ ]]; then
    msg_error "Management VMID must be a number"
    exit 1
  fi
  if [[ -z "${_rows_names[0]:-}" ]]; then
    msg_error "Management VM name must not be empty"
    exit 1
  fi
  if [[ -z "${_rows_ips[0]:-}" ]]; then
    msg_error "Management VM IP must not be empty"
    exit 1
  fi
  if ! netmask_to_cidr "${_rows_subnets[0]}" >/dev/null 2>&1; then
    msg_error "Invalid management VM netmask: ${_rows_subnets[0]}"
    exit 1
  fi
  if ! is_valid_ipv4 "${_rows_ips[0]}"; then
    msg_error "Invalid management VM IP: ${_rows_ips[0]}"
    exit 1
  fi
  if ! is_valid_ipv4 "${_rows_gateways[0]}"; then
    msg_error "Invalid gateway IP: ${_rows_gateways[0]}"
    exit 1
  fi
  if ! is_valid_ipv4 "${_rows_dns[0]}"; then
    msg_error "Invalid DNS server IP: ${_rows_dns[0]}"
    exit 1
  fi
  if ! is_valid_ipv4 "${_rows_ips[1]}"; then
    msg_error "Invalid VIP IP: ${_rows_ips[1]}"
    exit 1
  fi

  for ((i = 2; i < ${#_rows_names[@]}; i++)); do
    if [[ -z "${_rows_vmids[$i]:-}" || ! "${_rows_vmids[$i]}" =~ ^[0-9]+$ ]]; then
      msg_error "VMID for row ${i} must be a number"
      exit 1
    fi
    if ! is_valid_ipv4 "${_rows_ips[$i]}"; then
      msg_error "Invalid IP for row ${i}: ${_rows_ips[$i]}"
      exit 1
    fi
    if ! netmask_to_cidr "${_rows_subnets[$i]}" >/dev/null 2>&1; then
      msg_error "Invalid subnet for row ${i}: ${_rows_subnets[$i]}"
      exit 1
    fi
    if ! is_valid_ipv4 "${_rows_gateways[$i]}"; then
      msg_error "Invalid gateway for row ${i}: ${_rows_gateways[$i]}"
      exit 1
    fi
    if ! is_valid_ipv4 "${_rows_dns[$i]}"; then
      msg_error "Invalid DNS server for row ${i}: ${_rows_dns[$i]}"
      exit 1
    fi
  done

  _rows_vmids[1]=""
}

start_wizard() {
  local cluster_vmids=()
  local cluster_names=()
  local cluster_ips=()
  local cluster_subnets=()
  local cluster_gateways=()
  local cluster_dns=()
  local cluster_roles=()
  header_info
  choose_cluster_slug
  apply_educated_defaults
  handle_existing_cluster_conflict

  header_info
  msg_box "Twinbox Setup" "This wizard creates only the Management VM for cluster '${CLUSTER_SLUG}'.\n\nIt starts with a smart allocation grid for the management VM, VIP and future Talos nodes, then groups the remaining settings into:\n- Management VM sizing\n- Cloud-Init access\n- Manager API/runtime settings\n\nYou can review each group and edit only what you need."

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

  collect_cluster_allocation "${MGT_ID}" "${CLOUD_INIT_IP}" "${CLOUD_INIT_NETMASK}" "${CLOUD_INIT_GATEWAY}" "${CLOUD_INIT_DNS_IP}" "${CLUSTER_CONTROLPLANE_COUNT}" "${CLUSTER_WORKER_COUNT}" cluster_vmids cluster_names cluster_ips cluster_subnets cluster_gateways cluster_dns cluster_roles

  MGT_ID="${cluster_vmids[0]}"
  MGT_NAME="${cluster_names[0]}"
  CLOUD_INIT_IP="${cluster_ips[0]}"
  CLOUD_INIT_NETMASK="${cluster_subnets[0]}"
  CLOUD_INIT_GATEWAY="${cluster_gateways[0]}"
  CLOUD_INIT_DNS_IP="${cluster_dns[0]}"
  VIP_IP="${cluster_ips[1]}"
  CLUSTER_START_VMID="${cluster_vmids[2]}"
  CLUSTER_START_IP="${cluster_ips[2]}"
  CLOUD_INIT_CIDR=$(netmask_to_cidr "$CLOUD_INIT_NETMASK") || {
    msg_error "Invalid netmask: ${CLOUD_INIT_NETMASK}"
    exit 1
  }

  password_box "Cloud-Init" "Twinbox login password" CLOUD_INIT_PASSWORD

  msg_box "Security Notice" "Phase 1 is LAN-only and stores Proxmox credentials in ${TWINBOX_TARGET_DIR}/.env on the management VM.\n\nUse a dedicated Proxmox automation account and rotate credentials regularly."

  if whiptail --yesno "Proceed with installation?\n\nCluster: ${CLUSTER_SLUG}\nVM Name: $MGT_NAME\nVM ID: $MGT_ID\nCPU type: $MGT_CPU_TYPE\nBridge: $BRIDGE_IF\nManagement IP: $CLOUD_INIT_IP\nVIP: $VIP_IP\nFuture Talos start VMID: $CLUSTER_START_VMID\nFuture Talos start IP: $CLUSTER_START_IP\nCloud-Init user: $CLOUD_INIT_USER\nDNS: ${CLOUD_INIT_DNS_IP} (${CLOUD_INIT_DNS_DOMAIN})\nRepo: ${GITHUB_REPO}\nTarget dir: ${TWINBOX_TARGET_DIR}\nAuto-start manager stack: yes" 24 78; then
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
      CLUSTER_NAME=${CLUSTER_NAME}
      CLUSTER_CONTROLPLANE_COUNT=${CLUSTER_CONTROLPLANE_COUNT}
      CLUSTER_WORKER_COUNT=${CLUSTER_WORKER_COUNT}
      MANAGEMENT_VM_ID=${MGT_ID}
      MANAGEMENT_VM_IP=${CLOUD_INIT_IP}
      VIP_IP=${VIP_IP}
      CLUSTER_START_VMID=${CLUSTER_START_VMID}
      CLUSTER_START_IP=${CLUSTER_START_IP}
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
  - bash -lc 'sudo -u ${CLOUD_INIT_USER} -H bash -lc "if [ ! -d ${TWINBOX_TARGET_DIR}/.git ]; then git clone https://github.com/${GITHUB_REPO}.git ${TWINBOX_TARGET_DIR}; fi"'
  - install -m 0600 -o ${CLOUD_INIT_USER} -g ${CLOUD_INIT_USER} /tmp/twinbox-${CLUSTER_SLUG}.env.template ${TWINBOX_TARGET_DIR}/.env
  - chown -R ${CLOUD_INIT_USER}:${CLOUD_INIT_USER} ${TWINBOX_TARGET_DIR}
  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && chmod +x scripts/install-management-tools.sh && ./scripts/install-management-tools.sh --env-file ${TWINBOX_TARGET_DIR}/.env'
  - bash -lc 'sudo -u ${CLOUD_INIT_USER} -H bash -lc "cd ${TWINBOX_TARGET_DIR} && docker compose pull && docker compose up -d"'
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
    if curl --silent --output /dev/null --connect-timeout 2 --max-time 3 "$web_url" >/dev/null 2>&1; then
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
  if [[ "$web_interface_ready" -eq 1 ]]; then
    echo "Open a web browser now: http://${management_ip}:3000"
    echo "You can leave this screen."
  elif [[ -n "${management_ip:-}" ]]; then
    echo "Web interface on port 3000 is not reachable yet."
    echo "When it is ready, open: http://${management_ip}:3000"
    echo "You can leave this screen."
  else
    echo "Management VM IP is not available yet."
    echo "When it is known, open: http://<management-vm-ip>:3000"
    echo "You can leave this screen."
  fi
  echo "Login user: ${CLOUD_INIT_USER}"
  echo "Login password: ${CLOUD_INIT_PASSWORD}"
  echo "Proxmox API user: ${PROXMOX_USER}"
  echo "Proxmox API password: ${PROXMOX_PASSWORD}"
  echo "Cluster VIP: ${VIP_IP}"
  echo "Cluster start VMID: ${CLUSTER_START_VMID}"
  echo "Cluster start IP: ${CLUSTER_START_IP}"
  echo "If needed, edit ${TWINBOX_TARGET_DIR}/.env and run: cd ${TWINBOX_TARGET_DIR} && docker compose up -d"
  echo
}

main() {
  trap cleanup_after_run EXIT
  check_root
  check_deps
  start_wizard
}

main "$@"
