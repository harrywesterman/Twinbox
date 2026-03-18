#!/bin/bash

# Twinbox - Proxmox Console Setup Wizard
# Creates only the Ubuntu Management VM and auto-starts the manager stack.

set -euo pipefail

GITHUB_REPO="harrywesterman/twinbox"
BACKTITLE="Twinbox Cluster Wizard"

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
WIZARD_ACTION="create"
CURRENT_PROGRESS_PHASE="Preparing cluster"
WIZARD_LOG_FILE=""
DETECTED_CLUSTER_SLUGS=()
LIVE_LOG_MODE=0
FINAL_COMPLETION_MESSAGE=""
MANAGEMENT_WEB_URL=""

gauge_emit() {
  local percent="$1"
  local message="$2"

  printf 'XXX\n%s\n%s\nXXX\n' "$percent" "$message"
}

log_event() {
  local message="$1"

  if [[ -n "${WIZARD_LOG_FILE:-}" ]]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$message" >>"$WIZARD_LOG_FILE"
  fi

  if [[ "${LIVE_LOG_MODE:-0}" -eq 1 ]]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$message"
  fi
}

progress_update() {
  local phase="$1"
  local message="$2"

  CURRENT_PROGRESS_PHASE="$phase"
  log_event "${phase}: ${message}"
  if [[ "${LIVE_LOG_MODE:-0}" -eq 1 ]]; then
    printf '\n[%s] %s\n' "$phase" "$message"
    return 0
  fi
  whiptail --backtitle "$BACKTITLE" --title "Twinbox" --infobox "Phase: ${phase}\n\n${message}" 10 78
}

msg_info() { progress_update "$CURRENT_PROGRESS_PHASE" "$1"; }
msg_ok() { progress_update "$CURRENT_PROGRESS_PHASE" "$1"; }
msg_error() {
  log_event "ERROR: $1"
  whiptail --backtitle "$BACKTITLE" --title "Twinbox" --msgbox "$1" 12 78
}
status_update() { progress_update "$CURRENT_PROGRESS_PHASE" "$1"; }

yesno_box() {
  local title="$1"
  local text="$2"
  local height="${3:-12}"
  local width="${4:-78}"

  whiptail --backtitle "$BACKTITLE" --title "$title" --yesno "$text" "$height" "$width"
}

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
    printf 'Please run this script as root\n' >&2
    exit 1
  fi
}

check_deps() {
  if ! command -v whiptail >/dev/null 2>&1 || ! command -v dialog >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    printf 'Preparing Twinbox wizard...\n' >&2
    apt-get update -qq
    apt-get install -y whiptail dialog curl openssl >/dev/null 2>&1
  fi
  WIZARD_LOG_FILE=$(mktemp "/tmp/twinbox-wizard.XXXXXX.log")
}

input_box() {
  local title="$1"
  local text="$2"
  local default_value="$3"
  local var_name="$4"

  local value
  value=$(whiptail --backtitle "$BACKTITLE" --title "$title" --inputbox "$text" 10 78 "$default_value" 3>&1 1>&2 2>&3) || {
    exit 1
  }
  eval "$var_name=\"$value\""
}

password_box() {
  local title="$1"
  local text="$2"
  local var_name="$3"

  local value
  value=$(whiptail --backtitle "$BACKTITLE" --title "$title" --passwordbox "$text" 10 78 3>&1 1>&2 2>&3) || {
    exit 1
  }
  eval "$var_name=\"$value\""
}

password_box_confirm() {
  local title="$1"
  local text="$2"
  local var_name="$3"
  local first=""
  local second=""

  while true; do
    password_box "$title" "$text" first
    password_box "$title" "Confirm cluster login password" second

    if [[ -z "${first// }" ]]; then
      msg_box "$title" "Password is required."
      continue
    fi

    if [[ "$first" != "$second" ]]; then
      msg_box "$title" "Passwords do not match."
      continue
    fi

    eval "$var_name=\"$first\""
    return 0
  done
}

msg_box() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 12 78
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
    selected=$(whiptail --backtitle "$BACKTITLE" --title "Twinbox" --menu "Choose a cluster name." 16 78 5 \
      "development" "Use Development" \
      "test" "Use Test" \
      "production" "Use Production" \
      "custom" "Enter a custom name" \
      3>&1 1>&2 2>&3) || {
      exit 0
    }

    if [[ "$selected" == "custom" ]]; then
      custom_name=$(whiptail --backtitle "$BACKTITLE" --title "Twinbox" --inputbox "Cluster name" 10 78 "" 3>&1 1>&2 2>&3) || {
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

    msg_box "Twinbox" "Use letters, numbers, and dashes only."
  done
}

add_detected_cluster_slug() {
  local slug="$1"
  local existing=""

  [[ -n "$slug" ]] || return 0

  for existing in "${DETECTED_CLUSTER_SLUGS[@]}"; do
    if [[ "$existing" == "$slug" ]]; then
      return 0
    fi
  done

  DETECTED_CLUSTER_SLUGS+=("$slug")
}

detect_cluster_slugs() {
  local vmid=""
  local config=""
  local tags=""
  local tag=""
  local snippet=""
  local user=""
  local role=""
  local slug=""

  DETECTED_CLUSTER_SLUGS=()

  while read -r vmid; do
    [[ -n "$vmid" ]] || continue
    config=$(qm config "$vmid" 2>/dev/null || true)
    tags=$(printf '%s\n' "$config" | awk -F': ' '/^tags:/ {print $2; exit}')
    [[ -n "$tags" ]] || continue
    IFS=';' read -r -a tag_parts <<<"$tags"
    for tag in "${tag_parts[@]}"; do
      if [[ "$tag" == cluster-* ]]; then
        add_detected_cluster_slug "${tag#cluster-}"
      fi
    done
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')

  while read -r snippet; do
    [[ -n "$snippet" ]] || continue
    slug=$(basename "$snippet")
    slug=$(printf '%s\n' "$slug" | sed -E 's/^twinbox-(.+)-mgt-[0-9]+-user-data\.yaml$/\1/')
    add_detected_cluster_slug "$slug"
  done < <(find /var/lib/vz/snippets -maxdepth 1 -type f -name "twinbox-*-*.yaml" 2>/dev/null | sort)

  while read -r user; do
    [[ "$user" == twinbox-*@pve ]] || continue
    slug="${user#twinbox-}"
    slug="${slug%@pve}"
    add_detected_cluster_slug "$slug"
  done < <(pveum user list 2>/dev/null | awk 'NR>1 {print $1}')

  while read -r role; do
    [[ "$role" == TwinboxVMProvisioner-* ]] || continue
    slug="${role#TwinboxVMProvisioner-}"
    add_detected_cluster_slug "$slug"
  done < <(pveum role list 2>/dev/null | awk 'NR>1 {print $1}')
}

render_cluster_overview() {
  local summary=""
  local slug=""

  if [[ "${#DETECTED_CLUSTER_SLUGS[@]}" -eq 0 ]]; then
    printf '%s' "No Twinbox clusters detected."
    return 0
  fi

  summary="Clusters on this host"$'\n'$'\n'
  for slug in "${DETECTED_CLUSTER_SLUGS[@]}"; do
    summary+="- ${slug}"$'\n'
  done

  printf '%s' "$summary"
}

choose_existing_cluster_for_removal() {
  local prompt=""
  local selected=""
  local -a menu_args=()
  local slug=""

  if [[ "${#DETECTED_CLUSTER_SLUGS[@]}" -eq 0 ]]; then
    msg_box "Twinbox" "No Twinbox clusters are available to remove."
    exit 0
  fi

  for slug in "${DETECTED_CLUSTER_SLUGS[@]}"; do
    menu_args+=("$slug" "Remove ${slug}")
  done

  prompt="$(render_cluster_overview)"$'\n'$'\n'"Choose a cluster to remove."
  selected=$(whiptail --backtitle "$BACKTITLE" --title "Twinbox" --menu "$prompt" 20 78 10 "${menu_args[@]}" 3>&1 1>&2 2>&3) || exit 0
  CLUSTER_SLUG="$selected"
}

choose_cluster_action() {
  local prompt=""
  local action=""

  detect_cluster_slugs
  prompt="Twinbox"$'\n'$'\n'"Kickstart a Twinbox cluster environment"$'\n'$'\n'"$(render_cluster_overview)"$'\n'$'\n'"Choose an action."

  if [[ "${#DETECTED_CLUSTER_SLUGS[@]}" -eq 0 ]]; then
    action=$(whiptail --backtitle "$BACKTITLE" --title "Twinbox" --menu "$prompt" 18 78 6 \
      "create" "Start a new cluster" \
      3>&1 1>&2 2>&3) || exit 0
  else
    action=$(whiptail --backtitle "$BACKTITLE" --title "Twinbox" --menu "$prompt" 20 78 8 \
      "create" "Start a new cluster" \
      "remove" "Remove a cluster" \
      3>&1 1>&2 2>&3) || exit 0
  fi

  WIZARD_ACTION="$action"
  if [[ "$WIZARD_ACTION" == "remove" ]]; then
    choose_existing_cluster_for_removal
  fi
}

set_cluster_naming_defaults() {
  CLUSTER_VM_PREFIX="twinbox-${CLUSTER_SLUG}-"
  CLUSTER_VM_TAG="cluster-${CLUSTER_SLUG}"
  TWINBOX_TARGET_DIR="/opt/twinbox-${CLUSTER_SLUG}"
  MGT_NAME="${CLUSTER_VM_PREFIX}mgt"
  CLOUD_INIT_USER="twinbox-${CLUSTER_SLUG}"
  PROXMOX_USER="twinbox-${CLUSTER_SLUG}@pve"
  PROXMOX_ROLE="TwinboxVMProvisioner-${CLUSTER_SLUG}"
  PROXMOX_NODE="${PROXMOX_NODE:-$(hostname)}"
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

  progress_update "Checking cluster" "Checking cluster resources"
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

  progress_update "Checking cluster" "Checking cluster access"
  if pveum user list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$PROXMOX_USER"; then
    EXISTING_USER_PRESENT=1
  fi

  if pveum role list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$PROXMOX_ROLE"; then
    EXISTING_ROLE_PRESENT=1
  fi

  progress_update "Checking cluster" "Checking cluster files"
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
  summary+="Cluster: ${CLUSTER_SLUG}"$'\n'
  summary+="VMs: ${#EXISTING_VM_IDS[@]}"$'\n'
  summary+="Snippets: ${#EXISTING_SNIPPETS[@]}"$'\n'
  summary+="API user: "
  if [[ "${EXISTING_USER_PRESENT}" -eq 1 ]]; then
    summary+="yes"$'\n'
  else
    summary+="no"$'\n'
  fi
  summary+="API role: "
  if [[ "${EXISTING_ROLE_PRESENT}" -eq 1 ]]; then
    summary+="yes"
  else
    summary+="no"
  fi

  printf '%s' "$summary"
}

cleanup_existing_cluster_resources() {
  local idx=0
  local vmid=""
  local vm_name=""
  local snippet=""
  local acl_path=""

  progress_update "Removing cluster" "Removing cluster resources"

  for idx in "${!EXISTING_VM_IDS[@]}"; do
    vmid="${EXISTING_VM_IDS[$idx]}"
    vm_name="${EXISTING_VM_NAMES[$idx]}"
    log_event "Destroying VM ${vmid} (${vm_name})"
    qm stop "$vmid" --skiplock 1 >/dev/null 2>&1 || true
    qm destroy "$vmid" --purge 1 >/dev/null 2>&1 || true
  done

  for snippet in "${EXISTING_SNIPPETS[@]}"; do
    log_event "Removing snippet ${snippet}"
    rm -f "$snippet" || true
  done

  for acl_path in /vms /storage "/nodes/${PROXMOX_NODE}" /sdn; do
    pveum aclmod "$acl_path" -user "$PROXMOX_USER" -delete 1 >/dev/null 2>&1 || true
  done

  if [[ "${EXISTING_USER_PRESENT}" -eq 1 ]]; then
    log_event "Removing Proxmox API user ${PROXMOX_USER}"
    pveum user delete "$PROXMOX_USER" >/dev/null 2>&1 || true
  fi

  if [[ "${EXISTING_ROLE_PRESENT}" -eq 1 ]]; then
    log_event "Removing Proxmox role ${PROXMOX_ROLE}"
    pveum role delete "$PROXMOX_ROLE" >/dev/null 2>&1 || true
  fi

  progress_update "Removing cluster" "Cluster removed"
}

handle_existing_cluster_conflict() {
  local inventory=""
  local confirm_slug=""

  detect_existing_cluster_resources
  if ! cluster_resources_exist; then
    return 0
  fi

  inventory=$(render_existing_cluster_inventory)

  if ! yesno_box "Twinbox" "A cluster named '${CLUSTER_SLUG}' already exists.\n\n${inventory}\n\nRemove it before starting again?" 18 78; then
    exit 0
  fi

  confirm_slug=$(whiptail --backtitle "$BACKTITLE" --title "Twinbox" --inputbox "Type the cluster name to remove it:\n\n${CLUSTER_SLUG}" 12 78 3>&1 1>&2 2>&3) || {
    exit 0
  }

  if [[ "$confirm_slug" != "$CLUSTER_SLUG" ]]; then
    msg_error "Cluster name did not match."
    exit 1
  fi

  cleanup_existing_cluster_resources
  return 0
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

run_apply_educated_defaults_with_gauge() {
  local defaults_file=""
  defaults_file=$(mktemp "/tmp/twinbox-defaults.XXXXXX")

  (
    gauge_emit 5 "Checking network and free addresses"

    detected_host=$(hostname -I | awk '{print $1}')
    gauge_emit 15 "Checking network and free addresses"

    detected_prefix=$(ip -o -f inet addr show scope global | awk 'NR==1 {split($4, a, "/"); print a[2]}')
    detected_gateway=$(ip route | awk '/^default/ {print $3; exit}')
    detected_dns_ip=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)
    guessed_bridge=$(guess_bridge_interface || true)
    guessed_ssh_key=$(guess_ssh_public_key || true)

    gauge_emit 35 "Checking network and free addresses"

    set_cluster_naming_defaults
    CLUSTER_NAME="${CLUSTER_SLUG}"
    CLUSTER_CONTROLPLANE_COUNT="1"
    CLUSTER_WORKER_COUNT="2"
    total_vmids=$((1 + CLUSTER_CONTROLPLANE_COUNT + CLUSTER_WORKER_COUNT))
    total_ips=$((2 + CLUSTER_CONTROLPLANE_COUNT + CLUSTER_WORKER_COUNT))

    gauge_emit 55 "Checking network and free addresses"
    cluster_block_vmid=$(guess_free_vmid_block "$total_vmids" || true)

    gauge_emit 75 "Checking network and free addresses"
    cluster_block_ip=$(guess_free_ip_block "${detected_host:-}" "$total_ips" || true)

    gauge_emit 95 "Checking network and free addresses"

    cat >"$defaults_file" <<EOF
detected_host=$(printf '%q' "${detected_host:-}")
detected_prefix=$(printf '%q' "${detected_prefix:-}")
detected_gateway=$(printf '%q' "${detected_gateway:-}")
detected_dns_ip=$(printf '%q' "${detected_dns_ip:-}")
guessed_bridge=$(printf '%q' "${guessed_bridge:-}")
guessed_ssh_key=$(printf '%q' "${guessed_ssh_key:-}")
cluster_block_vmid=$(printf '%q' "${cluster_block_vmid:-}")
cluster_block_ip=$(printf '%q' "${cluster_block_ip:-}")
EOF

    gauge_emit 100 "Checking network and free addresses"
  ) | whiptail --backtitle "$BACKTITLE" --title "Twinbox" --gauge "Checking network and free addresses" 10 78 0

  progress_update "Preparing cluster" "Checking network and free addresses"

  # shellcheck disable=SC1090
  source "$defaults_file"
  rm -f "$defaults_file"

  set_cluster_naming_defaults
  CLUSTER_NAME="${CLUSTER_SLUG}"
  CLUSTER_CONTROLPLANE_COUNT="1"
  CLUSTER_WORKER_COUNT="2"
  total_vmids=$((1 + CLUSTER_CONTROLPLANE_COUNT + CLUSTER_WORKER_COUNT))
  total_ips=$((2 + CLUSTER_CONTROLPLANE_COUNT + CLUSTER_WORKER_COUNT))
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

  progress_update "Preparing cluster" "Preparing cluster environment"
  if create_err=$(pveum user add "$PROXMOX_USER" --comment "Twinbox service account (${CLUSTER_SLUG})" 2>&1); then
    log_event "Created Proxmox API user ${PROXMOX_USER}"
  else
    if printf '%s' "$create_err" | grep -qi "already exists"; then
      log_event "Proxmox API user ${PROXMOX_USER} already exists"
    else
      msg_error "Failed to create Proxmox API user ${PROXMOX_USER}: ${create_err}"
      exit 1
    fi
  fi

  log_event "Setting password for ${PROXMOX_USER}"
  if ! set_proxmox_password_with_retry "$PROXMOX_USER" "$PROXMOX_PASSWORD" 15 1; then
    msg_error "Failed to set password for Proxmox API user ${PROXMOX_USER}: ${last_err}"
    exit 1
  fi

  log_event "Ensuring least-privilege role ${PROXMOX_ROLE}"
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

  log_event "Applying ACLs for ${PROXMOX_USER}"
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
  input_box "Twinbox" "Management VM name" "$MGT_NAME" MGT_NAME
  input_box "Twinbox" "Management VM RAM (MB)" "$MGT_RAM" MGT_RAM
  input_box "Twinbox" "Management VM CPU cores" "$MGT_CORES" MGT_CORES
  input_box "Twinbox" "Management VM CPU type" "$MGT_CPU_TYPE" MGT_CPU_TYPE
  input_box "Twinbox" "Management VM disk size (GB)" "$MGT_DISK" MGT_DISK
  input_box "Twinbox" "Bridge interface" "$BRIDGE_IF" BRIDGE_IF
  input_box "Twinbox" "SSH public key" "$SSH_KEY" SSH_KEY
  input_box "Twinbox" "Proxmox host" "$PROXMOX_HOST" PROXMOX_HOST
  input_box "Twinbox" "Proxmox port" "$PROXMOX_PORT" PROXMOX_PORT
  input_box "Twinbox" "Proxmox API user" "$PROXMOX_USER" PROXMOX_USER
  input_box "Twinbox" "Proxmox node" "$PROXMOX_NODE" PROXMOX_NODE
  input_box "Twinbox" "Storage pool" "$PROXMOX_STORAGE_POOL" PROXMOX_STORAGE_POOL
  input_box "Twinbox" "ISO storage" "$PROXMOX_ISO_STORAGE" PROXMOX_ISO_STORAGE
  input_box "Twinbox" "Talos ISO file" "$TALOS_ISO_FILE" TALOS_ISO_FILE
  input_box "Twinbox" "Talosctl version" "$TALOSCTL_VERSION" TALOSCTL_VERSION
  input_box "Twinbox" "kubectl version" "$KUBECTL_VERSION" KUBECTL_VERSION
  input_box "Twinbox" "Helm version" "$HELM_VERSION" HELM_VERSION
  input_box "Twinbox" "Image tag" "$TWINBOX_IMAGE_TAG" TWINBOX_IMAGE_TAG
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
  _rows_names+=("twinbox-${CLUSTER_SLUG}-vip")
  _rows_ips+=("$next_ip")
  _rows_subnets+=("$subnet")
  _rows_gateways+=("$gateway")
  _rows_dns+=("$dns")

  next_vmid=$((next_vmid + 1))
  next_ip_int=$((next_ip_int + 1))

  for ((index = 1; index <= cp_count; index++)); do
    role="twinbox-${CLUSTER_SLUG}-cp-${index}"
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
    role="twinbox-${CLUSTER_SLUG}-worker-${index}"
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

whiptail_supports_form() {
  whiptail --help 2>&1 | grep -Fq -- "--form"
}

dialog_supports_form() {
  command -v dialog >/dev/null 2>&1
}

edit_cluster_allocation_table_form() {
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
  local form_width=92
  local prompt="Edit the proposed allocation grid.\n\nColumns: vmid, name, ip"
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
    form_args+=("NAME" "$spec_y" 18 "${_rows_names[$i]}" "$spec_y" 24 26 34)
    form_args+=("IP" "$spec_y" 61 "${_rows_ips[$i]}" "$spec_y" 64 15 15)
  done

  form_output=$(whiptail "${form_args[@]}" 3>&1 1>&2 2>&3) || return 1

  allocation_file=$(mktemp)
  printf '%s\n' "$form_output" > "$allocation_file"

  mapfile -t form_lines < "$allocation_file"
  if [[ "${#form_lines[@]}" -lt $((row_count * 3)) ]]; then
    msg_error "Allocation grid returned incomplete data"
    return 1
  fi

  for ((i = 0; i < row_count; i++)); do
    _rows_vmids[$i]=$(trim_value "${form_lines[$((i * 3 + 0))]}")
    _rows_names[$i]=$(trim_value "${form_lines[$((i * 3 + 1))]}")
    _rows_ips[$i]=$(trim_value "${form_lines[$((i * 3 + 2))]}")
  done
}

edit_cluster_allocation_table_dialog_form() {
  local title="$1"
  local -n _rows_roles="$2"
  local -n _rows_vmids="$3"
  local -n _rows_names="$4"
  local -n _rows_ips="$5"
  local -n _rows_subnets="$6"
  local -n _rows_gateways="$7"
  local -n _rows_dns="$8"
  local row_count="${#_rows_names[@]}"
  local form_height=$((row_count + 2))
  local form_width=92
  local prompt="Edit the proposed allocation grid.\n\nColumns: vmid, name, ip"
  local form_output=""
  local i=0
  local row_y=0
  local -a form_args=()
  local -a form_lines=()

  form_args=(--stdout --backtitle "$BACKTITLE" --title "$title" --form "$prompt" "$((form_height + 8))" "$form_width" "$form_height")
  for ((i = 0; i < row_count; i++)); do
    row_y=$((1 + i))
    form_args+=("VMID" "$row_y" 1 "${_rows_vmids[$i]:--}" "$row_y" 7 8 8)
    form_args+=("NAME" "$row_y" 18 "${_rows_names[$i]}" "$row_y" 24 26 34)
    form_args+=("IP" "$row_y" 61 "${_rows_ips[$i]}" "$row_y" 64 15 15)
  done

  form_output=$(dialog "${form_args[@]}") || return 1
  mapfile -t form_lines <<<"$form_output"
  if [[ "${#form_lines[@]}" -lt $((row_count * 3)) ]]; then
    msg_error "Allocation grid returned incomplete data"
    return 1
  fi

  for ((i = 0; i < row_count; i++)); do
    _rows_vmids[$i]=$(trim_value "${form_lines[$((i * 3 + 0))]}")
    _rows_names[$i]=$(trim_value "${form_lines[$((i * 3 + 1))]}")
    _rows_ips[$i]=$(trim_value "${form_lines[$((i * 3 + 2))]}")
  done
}

edit_cluster_allocation_table_fallback() {
  local title="$1"
  local -n _rows_roles="$2"
  local -n _rows_vmids="$3"
  local -n _rows_names="$4"
  local -n _rows_ips="$5"
  local -n _rows_subnets="$6"
  local -n _rows_gateways="$7"
  local -n _rows_dns="$8"
  local row_count="${#_rows_names[@]}"
  local i=0
  local row_value=""
  local current_value=""
  local -a parts=()

  for ((i = 0; i < row_count; i++)); do
    current_value="${_rows_vmids[$i]:-}|${_rows_names[$i]}|${_rows_ips[$i]}"
    input_box "Cluster Allocation" "Row ${i} (${_rows_roles[$i]})\nvmid|name|ip" "$current_value" row_value
    IFS='|' read -r -a parts <<< "$row_value"
    if [[ "${#parts[@]}" -ne 3 ]]; then
      msg_error "Allocation row ${i} must contain exactly 3 pipe-separated values"
      return 1
    fi
    _rows_vmids[$i]=$(trim_value "${parts[0]}")
    _rows_names[$i]=$(trim_value "${parts[1]}")
    _rows_ips[$i]=$(trim_value "${parts[2]}")
  done
}

edit_cluster_network_settings() {
  local -n _rows_subnets="$1"
  local -n _rows_gateways="$2"
  local -n _rows_dns="$3"
  local subnet_value="${_rows_subnets[0]}"
  local gateway_value="${_rows_gateways[0]}"
  local dns_value="${_rows_dns[0]}"
  local i=0

  input_box "Cluster Network" "Subnet mask" "$subnet_value" subnet_value
  input_box "Cluster Network" "Gateway" "$gateway_value" gateway_value
  input_box "Cluster Network" "DNS" "$dns_value" dns_value

  for ((i = 0; i < ${#_rows_subnets[@]}; i++)); do
    _rows_subnets[$i]="$subnet_value"
    _rows_gateways[$i]="$gateway_value"
    _rows_dns[$i]="$dns_value"
  done
}

edit_cluster_allocation_table() {
  local title="$1"
  local -n _rows_roles="$2"
  local -n _rows_vmids="$3"
  local -n _rows_names="$4"
  local -n _rows_ips="$5"
  local -n _rows_subnets="$6"
  local -n _rows_gateways="$7"
  local -n _rows_dns="$8"

  if whiptail_supports_form; then
    edit_cluster_allocation_table_form "$title" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  elif dialog_supports_form; then
    edit_cluster_allocation_table_dialog_form "$title" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  else
    edit_cluster_allocation_table_fallback "$title" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  fi
}

collect_cluster_allocation() {
  local base_vmid="$1"
  local base_ip="$2"
  local subnet="$3"
  local gateway="$4"
  local dns="$5"
  local cp_count="$6"
  local worker_count="$7"
  local rows_vmids_name="$8"
  local rows_names_name="$9"
  local rows_ips_name="${10}"
  local rows_subnets_name="${11}"
  local rows_gateways_name="${12}"
  local rows_dns_name="${13}"
  local rows_roles_name="${14}"
  local -n _rows_vmids="$rows_vmids_name"
  local -n _rows_names="$rows_names_name"
  local -n _rows_ips="$rows_ips_name"
  local -n _rows_subnets="$rows_subnets_name"
  local -n _rows_gateways="$rows_gateways_name"
  local -n _rows_dns="$rows_dns_name"
  local -n _rows_roles="$rows_roles_name"

  build_cluster_allocation_rows "$rows_roles_name" "$rows_vmids_name" "$rows_names_name" "$rows_ips_name" "$rows_subnets_name" "$rows_gateways_name" "$rows_dns_name" \
    "$base_vmid" "$base_ip" "$subnet" "$gateway" "$dns" "$cp_count" "$worker_count"

  if ! edit_cluster_allocation_table "Cluster Allocation" "$rows_roles_name" "$rows_vmids_name" "$rows_names_name" "$rows_ips_name" "$rows_subnets_name" "$rows_gateways_name" "$rows_dns_name"; then
    exit 1
  fi

  edit_cluster_network_settings "$rows_subnets_name" "$rows_gateways_name" "$rows_dns_name"

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

remove_cluster_flow() {
  set_cluster_naming_defaults
  detect_existing_cluster_resources

  if ! cluster_resources_exist; then
    msg_box "Twinbox" "No resources were found for ${CLUSTER_SLUG}."
    exit 0
  fi

  if ! yesno_box "Twinbox" "$(render_existing_cluster_inventory)\n\nRemove this cluster?" 16 78; then
    exit 0
  fi

  local confirm_slug=""
  confirm_slug=$(whiptail --backtitle "$BACKTITLE" --title "Twinbox" --inputbox "Type the cluster name to remove it:\n\n${CLUSTER_SLUG}" 12 78 3>&1 1>&2 2>&3) || exit 0

  if [[ "$confirm_slug" != "$CLUSTER_SLUG" ]]; then
    msg_error "Cluster name did not match."
    exit 1
  fi

  cleanup_existing_cluster_resources
  msg_box "Twinbox" "Cluster removed.\n\nThis script will now close."
}

start_wizard() {
  local cluster_vmids=()
  local cluster_names=()
  local cluster_ips=()
  local cluster_subnets=()
  local cluster_gateways=()
  local cluster_dns=()
  local cluster_roles=()
  choose_cluster_action

  if [[ "$WIZARD_ACTION" == "remove" ]]; then
    remove_cluster_flow
    return 0
  fi

  choose_cluster_slug
  run_apply_educated_defaults_with_gauge
  handle_existing_cluster_conflict

  if [[ -z "${SSH_KEY:-}" ]]; then
    input_box "Twinbox" "SSH public key" "" SSH_KEY
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

  password_box_confirm "Twinbox" "Cluster login password" CLOUD_INIT_PASSWORD

  run_installation_flow
  print_next_steps
}

create_management_vm() {
  local ubuntu_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  local img_name="noble-server-cloudimg-amd64.img"
  local img_path="/var/lib/vz/template/cache/${img_name}"
  local CLOUD_INIT_PASSWORD_HASH=""

  CLOUD_INIT_PASSWORD_HASH=$(openssl passwd -6 "$CLOUD_INIT_PASSWORD")

  mkdir -p /var/lib/vz/template/cache /var/lib/vz/snippets

  progress_update "Preparing cluster" "Preparing cluster environment"
  if [[ ! -f "$img_path" ]]; then
    log_event "Downloading Ubuntu 24.04 cloud image"
    curl -fsSL -o "$img_path" "$ubuntu_url"
    log_event "Ubuntu image downloaded"
  else
    log_event "Ubuntu image already present"
  fi

  ensure_talos_iso_available

  log_event "Preparing cloud-init configuration snippet"

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

  progress_update "Starting environment" "Starting management environment"
  qm create "$MGT_ID" --name "$MGT_NAME" --memory "$MGT_RAM" --cores "$MGT_CORES" --cpu "$MGT_CPU_TYPE" --net0 "virtio,bridge=${BRIDGE_IF}" \
    --tags "twinbox;management;docker;bootstrap;${CLUSTER_VM_TAG}" \
    --scsihw virtio-scsi-pci --ide2 local-lvm:cloudinit --serial0 socket --vga serial0 --ostype l26 >/dev/null
  vm_created=1
  log_event "Importing base disk into VM storage"
  qm importdisk "$MGT_ID" "$img_path" local-lvm >/dev/null
  log_event "Applying cloud-init and boot configuration"
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
  log_event "Starting management VM"
  qm start "$MGT_ID" >/dev/null

  progress_update "Starting environment" "Management environment started"
}

ensure_talos_iso_available() {
  local talos_version=""
  local talos_url=""
  local iso_list=""
  local tmp_iso=""
  local storage_path=""
  local iso_target_dir=""

  progress_update "Preparing cluster" "Checking installation media"
  iso_list=$(pvesm list "$PROXMOX_ISO_STORAGE" --content iso 2>/dev/null || true)
  if printf '%s\n' "$iso_list" | grep -Fq "iso/${TALOS_ISO_FILE}"; then
    log_event "Talos ISO already present (${TALOS_ISO_FILE})"
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
  log_event "Downloading Talos ISO ${TALOS_ISO_FILE}"

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
  log_event "Talos ISO downloaded (${TALOS_ISO_FILE})"
}

discover_management_vm_ip() {
  local output=""
  local ip=""
  local polls=1

  progress_update "Waiting for Twinbox" "Waiting for Twinbox"
  while true; do
    output=$(qm guest cmd "$MGT_ID" network-get-interfaces 2>/dev/null || true)
    ip=$(
      printf '%s\n' "$output" \
      | grep -Eo '"ip-address"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
      | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"/\1/' \
      | grep -Ev '^(127\.|169\.254\.)' \
      | head -n1
    )

    if [[ -n "$ip" ]]; then
      log_event "Management VM received an IP address"
      echo "$ip"
      return 0
    fi

    if (( polls == 3 )); then
      log_event "Waiting for the management VM to request an address."
    elif (( polls == 9 )); then
      log_event "The management VM is still booting. This can take a minute or two."
    fi

    sleep 5
    polls=$((polls + 1))
  done
}

wait_for_management_vm_ping() {
  local management_ip="$1"
  local polls=1

  progress_update "Waiting for Twinbox" "Waiting for Twinbox"
  log_event "Management VM is starting on the network."

  while true; do
    if ping -c 1 -W 1 "$management_ip" >/dev/null 2>&1; then
      log_event "Management VM is responding on the network"
      return 0
    fi

    if (( polls == 3 )); then
      log_event "Still waiting for the management VM to respond to network checks."
    elif (( polls == 9 )); then
      log_event "The operating system is still starting. This may take another minute."
    fi

    sleep 5
    polls=$((polls + 1))
  done
}

wait_for_web_interface() {
  local management_ip="$1"
  local polls=1
  local web_url="http://${management_ip}:3000"
  local elapsed_seconds=0
  local http_code=""
  local wait_stage=0

  progress_update "Waiting for Twinbox" "Waiting for Twinbox"
  log_event "Twinbox services are starting. This usually takes a few minutes on the first run."
  while true; do
    http_code=$(curl --silent --head --output /dev/null --write-out "%{http_code}" --connect-timeout 2 --max-time 10 "$web_url" || true)
    if [[ "${http_code}" != "000" ]]; then
      log_event "Web interface is reachable on port 3000"
      return 0
    fi

    elapsed_seconds=$(((polls - 1) * 5))

    if (( elapsed_seconds >= 30 && wait_stage == 0 )); then
      log_event "Twinbox is starting. Usually ready in 2-5 minutes."
      wait_stage=1
    elif (( elapsed_seconds >= 120 && wait_stage == 1 )); then
      log_event "Still starting. Usually another 1-3 minutes."
      wait_stage=2
    elif (( elapsed_seconds >= 300 && wait_stage == 2 )); then
      log_event "Still starting. Downloads may take a few more minutes."
      wait_stage=3
    elif (( elapsed_seconds >= 600 && wait_stage == 3 )); then
      log_event "Still starting. This host is taking longer than usual."
      wait_stage=4
    fi

    sleep 5
    polls=$((polls + 1))
  done
}

prepare_completion_message() {
  local management_ip=""
  management_ip=$(discover_management_vm_ip)
  wait_for_web_interface "$management_ip"
  MANAGEMENT_WEB_URL="http://${management_ip}:3000"
  FINAL_COMPLETION_MESSAGE="Twinbox URL: ${MANAGEMENT_WEB_URL}"
}

run_installation_flow() {
  local install_exit=0

  set +e
  {
    LIVE_LOG_MODE=1
    log_event "Twinbox is building the cluster environment."
    create_proxmox_api_user
    create_management_vm
    prepare_completion_message
  } 2>&1 | dialog \
    --backtitle "$BACKTITLE" \
    --title "Twinbox" \
    --programbox "Twinbox is building the cluster environment." 20 78
  install_exit=${PIPESTATUS[0]}
  LIVE_LOG_MODE=0
  set -e

  if [[ "$install_exit" -ne 0 ]]; then
    exit "$install_exit"
  fi
}

print_next_steps() {
  local message="${FINAL_COMPLETION_MESSAGE}"

  clear
  msg_box "Twinbox" "${message}\n\nOpen this in your browser:\n\n${MANAGEMENT_WEB_URL}\n\nThis script will now close."
}

main() {
  trap cleanup_after_run EXIT
  check_root
  check_deps
  start_wizard
}

main "$@"
