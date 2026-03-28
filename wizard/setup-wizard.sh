#!/bin/bash

# Twinbox - Proxmox Console Setup Wizard for the Twinbox Management Environment
# Creates only the Twinbox Management Environment and auto-starts the manager stack.

set -euo pipefail

GITHUB_REPO="harrywesterman/twinbox"
BACKTITLE="Twinbox"

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
EXISTING_VM_NODES=()
EXISTING_VM_TAGS=()
EXISTING_SNIPPETS=()
EXISTING_USER_PRESENT=0
EXISTING_ROLE_PRESENT=0
allocation_file=""
completion_state_file=""
WIZARD_ACTION="create"
CURRENT_PROGRESS_PHASE="Preparing"
WIZARD_LOG_FILE=""
DETECTED_CLUSTER_SLUGS=()
LIVE_LOG_MODE=0
FINAL_COMPLETION_MESSAGE=""
MANAGEMENT_WEB_URL=""
DISCOVERED_MANAGEMENT_IP=""

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
  log_event "$message"
  if [[ "${LIVE_LOG_MODE:-0}" -eq 1 ]]; then
    printf '\n[%s] %s\n' "$phase" "$message"
    return 0
  fi
  dialog --backtitle "$BACKTITLE" --title "Twinbox" --infobox "Phase: ${phase}\n\n${message}" 10 78
}

msg_info() { progress_update "$CURRENT_PROGRESS_PHASE" "$1"; }
msg_ok() { progress_update "$CURRENT_PROGRESS_PHASE" "$1"; }
msg_error() {
  log_event "ERROR: $1"
  dialog --backtitle "$BACKTITLE" --title "Twinbox" --msgbox "$1" 12 78
}
status_update() { progress_update "$CURRENT_PROGRESS_PHASE" "$1"; }

run_qm_command() {
  local step="$1"
  shift

  local output=""
  local extra_hint=""

  if output=$("$@" 2>&1); then
    return 0
  fi

  if printf '%s\n' "$output" | grep -qi "cloudinit"; then
    extra_hint=" Cloud-init hint: Proxmox could not create the cloud-init volume for VMID ${MGT_ID}."
  fi

  if printf '%s\n' "$output" | grep -Eqi "lvcreate|logical volume|local-lvm|no space left|not enough free space"; then
    extra_hint="${extra_hint} Storage hint: check local-lvm free space or remove leftover disks for VMID ${MGT_ID}."
  fi

  printf 'Failed to %s for VMID %s: %s%s\n' "$step" "$MGT_ID" "$output" "$extra_hint" >&2
  return 1
}

yesno_box() {
  local title="$1"
  local text="$2"
  local height="${3:-12}"
  local width="${4:-78}"

  dialog --backtitle "$BACKTITLE" --title "$title" --yesno "$text" "$height" "$width"
}

cleanup_after_run() {
  local exit_code=$?

  if [[ -n "${allocation_file:-}" && -f "$allocation_file" ]]; then
    rm -f "$allocation_file"
  fi

  if [[ -n "${completion_state_file:-}" && -f "$completion_state_file" ]]; then
    rm -f "$completion_state_file"
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
    printf 'Preparing setup...\n' >&2
    apt-get update -qq
    apt-get install -y whiptail dialog curl openssl >/dev/null 2>&1
  fi
  WIZARD_LOG_FILE=$(mktemp "/tmp/twinbox-wizard.XXXXXX.log")
  completion_state_file=$(mktemp "/tmp/twinbox-completion.XXXXXX")
}

input_box() {
  local title="$1"
  local text="$2"
  local default_value="$3"
  local var_name="$4"

  local value
  value=$(dialog --backtitle "$BACKTITLE" --title "$title" --inputbox "$text" 10 78 "$default_value" 3>&1 1>&2 2>&3) || {
    return 1
  }
  eval "$var_name=\"$value\""
}

password_box() {
  local title="$1"
  local text="$2"
  local var_name="$3"

  local value
  value=$(dialog --backtitle "$BACKTITLE" --title "$title" --insecure --passwordbox "$text" 10 78 3>&1 1>&2 2>&3) || {
    return 1
  }
  eval "$var_name=\"$value\""
}

password_box_confirm() {
  local title="$1"
  local text="$2\n\nMust be at least 8 characters long, containing 1 uppercase, 1 lowercase, and 1 special character."
  local var_name="$3"
  local first=""
  local second=""

  while true; do
    password_box "$title" "$text" first || return 1
    password_box "$title" "Confirm cluster login password" second || return 1

    if [[ -z "${first// }" ]]; then
      msg_box "$title" "Password is required."
      continue
    fi

    if [[ ${#first} -lt 8 ]]; then
      msg_box "$title" "Password must be at least 8 characters long."
      continue
    fi
    if [[ ! "$first" =~ [A-Z] ]]; then
      msg_box "$title" "Password must contain at least one uppercase letter."
      continue
    fi
    if [[ ! "$first" =~ [a-z] ]]; then
      msg_box "$title" "Password must contain at least one lowercase letter."
      continue
    fi
    if [[ ! "$first" =~ [^a-zA-Z0-9] ]]; then
      msg_box "$title" "Password must contain at least one special character."
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
  dialog --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 12 78
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
    selected=$(dialog --backtitle "$BACKTITLE" --title "Twinbox" --menu "Choose a cluster name." 16 78 5 \
      "prd" "Use Production (prd)" \
      "dev" "Use Development (dev)" \
      "tst" "Use Test (tst)" \
      "custom" "Enter a custom name" \
      3>&1 1>&2 2>&3) || return 1

    if [[ "$selected" == "custom" ]]; then
      custom_name=$(dialog --backtitle "$BACKTITLE" --title "Twinbox" --inputbox "Cluster name (max 3 lowercase letters)" 10 78 "prd" 3>&1 1>&2 2>&3) || return 1
      sanitized=$(sanitize_cluster_slug "$custom_name")
    else
      sanitized=$(sanitize_cluster_slug "$selected")
    fi

    if [[ -n "$sanitized" ]]; then
      if [[ ! "$sanitized" =~ ^[a-z]{1,3}$ ]]; then
        msg_box "Twinbox" "Cluster name must be 1-3 lowercase letters only."
        continue
      fi
      CLUSTER_SLUG="$sanitized"
      return 0
    fi

    msg_box "Twinbox" "Cluster name is required."
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

cluster_vm_inventory() {
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null
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
  local cluster_vms=""

  DETECTED_CLUSTER_SLUGS=()

  if cluster_vms=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null); then
    while read -r tags; do
      [[ -n "$tags" ]] || continue
      IFS=';' read -r -a tag_parts <<<"$tags"
      for tag in "${tag_parts[@]}"; do
        if [[ "$tag" == cluster-* ]]; then
          add_detected_cluster_slug "${tag#cluster-}"
        fi
      done
    done < <(printf '%s\n' "$cluster_vms" | grep -Eo '"tags"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"tags"[[:space:]]*:[[:space:]]*"([^"]+)"/\1/')
  else
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
  fi

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



cluster_management_menu() {
  local slug="$1"
  local action=""

  action=$(dialog --backtitle "$BACKTITLE" --title "Manage Cluster: $slug" \
    --menu "What would you like to do with cluster '$slug'?" \
    15 78 5 \
    "remove" "Remove this cluster and all its resources" \
    "back" "Return to main menu" \
    3>&1 1>&2 2>&3) || return 2 # 2 means go back to main menu

  if [[ "$action" == "remove" ]]; then
    WIZARD_ACTION="remove"
    CLUSTER_SLUG="$slug"
    return 0
  fi
  return 2
}

main_menu() {
  local selected=""
  local -a menu_args=()
  local slug=""

  detect_cluster_slugs

  menu_args+=("create" "[+] Create a new Twinbox Cluster")
  
  for slug in "${DETECTED_CLUSTER_SLUGS[@]}"; do
    menu_args+=("manage:$slug" "[-] Manage Cluster: $slug")
  done

  selected=$(dialog --backtitle "$BACKTITLE" --title "Twinbox Management" \
    --menu "Welcome to the Twinbox Setup Wizard.\n\nDetected Clusters: ${#DETECTED_CLUSTER_SLUGS[@]}\n\nChoose an action or a cluster to manage." \
    20 78 10 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 1

  if [[ "$selected" == "create" ]]; then
    WIZARD_ACTION="create"
    return 0
  elif [[ "$selected" == manage:* ]]; then
    CLUSTER_SLUG="${selected#manage:}"
    cluster_management_menu "$CLUSTER_SLUG"
    return $?
  fi
}

set_cluster_naming_defaults() {
  CLUSTER_VM_PREFIX="twinbox-${CLUSTER_SLUG}-"
  CLUSTER_VM_TAG="cluster-${CLUSTER_SLUG}"
  TWINBOX_TARGET_DIR="/opt/twinbox"
  MGT_NAME="${CLUSTER_VM_PREFIX}mgt"
  CLOUD_INIT_USER="twinbox"
  PROXMOX_USER="twinbox-${CLUSTER_SLUG}@pve"
  PROXMOX_ROLE="TwinboxVMProvisioner-${CLUSTER_SLUG}"
  PROXMOX_NODE="${PROXMOX_NODE:-$(hostname)}"
}

detect_existing_cluster_resources() {
  local vmid=""
  local node=""
  local name=""
  local tags=""
  local snippet=""
  local cluster_vms=""
  declare -A seen_vm_names=()
  declare -A seen_vmids=()

  EXISTING_VM_IDS=()
  EXISTING_VM_NAMES=()
  EXISTING_VM_NODES=()
  EXISTING_VM_TAGS=()
  EXISTING_SNIPPETS=()
  EXISTING_USER_PRESENT=0
  EXISTING_ROLE_PRESENT=0

  progress_update "Checking cluster" "Checking cluster resources"
  if ! cluster_vms=$(cluster_vm_inventory); then
    msg_error "Unable to query Proxmox cluster inventory."
    return 1
  fi

  while IFS=$'\t' read -r vmid node name tags; do
    [[ -n "$vmid" && -n "$node" && -n "$name" ]] || continue

    if [[ -n "${seen_vm_names[$name]:-}" && "${seen_vm_names[$name]}" != "$node" ]]; then
      log_event "WARNING: cluster VM ${name} appears on multiple Proxmox nodes (${seen_vm_names[$name]} and ${node})"
    fi
    if [[ -n "${seen_vmids[$vmid]:-}" && "${seen_vmids[$vmid]}" != "$node" ]]; then
      log_event "WARNING: VMID ${vmid} appears on multiple Proxmox nodes (${seen_vmids[$vmid]} and ${node})"
    fi

    seen_vm_names["$name"]="$node"
    seen_vmids["$vmid"]="$node"
    EXISTING_VM_IDS+=("$vmid")
    EXISTING_VM_NODES+=("$node")
    EXISTING_VM_NAMES+=("$name")
    EXISTING_VM_TAGS+=("$tags")
  done < <(printf '%s\n' "$cluster_vms" | jq -r --arg cluster_tag "$CLUSTER_VM_TAG" --arg cluster_prefix "$CLUSTER_VM_PREFIX" '
    (.data // .)[]
    | select((.name // "" | startswith($cluster_prefix)) or (.tags // "" | split(";") | any(. == $cluster_tag)))
    | [.vmid, .node, .name, (.tags // "")] | @tsv
  ')

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
  local idx=""
  summary+="Cluster: ${CLUSTER_SLUG}"$'\n'
  summary+="VMs: ${#EXISTING_VM_IDS[@]}"$'\n'
  if [[ "${#EXISTING_VM_IDS[@]}" -gt 0 ]]; then
    summary+="VM inventory:"$'\n'
    for idx in "${!EXISTING_VM_IDS[@]}"; do
      summary+="- ${EXISTING_VM_NAMES[$idx]} (vmid ${EXISTING_VM_IDS[$idx]}, node ${EXISTING_VM_NODES[$idx]}"
      if [[ -n "${EXISTING_VM_TAGS[$idx]:-}" ]]; then
        summary+=", tags ${EXISTING_VM_TAGS[$idx]}"
      fi
      summary+=")"$'\n'
    done
  fi
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
  local vm_node=""
  local vm_tags=""
  local snippet=""
  local acl_path=""

  progress_update "Removing cluster" "Removing cluster resources"

  for idx in "${!EXISTING_VM_IDS[@]}"; do
    vmid="${EXISTING_VM_IDS[$idx]}"
    vm_name="${EXISTING_VM_NAMES[$idx]}"
    vm_node="${EXISTING_VM_NODES[$idx]}"
    vm_tags="${EXISTING_VM_TAGS[$idx]}"
    log_event "Destroying VM ${vmid} (${vm_name}) on ${vm_node}"
    if [[ -n "$vm_tags" ]]; then
      log_event "VM ${vm_name} tags: ${vm_tags}"
    fi
    pvesh create "/nodes/${vm_node}/qemu/${vmid}/status/stop" >/dev/null 2>&1 || true
    pvesh delete "/nodes/${vm_node}/qemu/${vmid}" --purge 1 >/dev/null 2>&1 || true
  done

  for snippet in "${EXISTING_SNIPPETS[@]}"; do
    log_event "Removing snippet ${snippet}"
    rm -f "$snippet" || true
  done

  for acl_path in /vms /storage /nodes "/nodes/${PROXMOX_NODE}" /sdn; do
    pveum aclmod "$acl_path" -user "$PROXMOX_USER" -delete 1 >/dev/null 2>&1 || true
  done

  if [[ "${EXISTING_USER_PRESENT}" -eq 1 ]]; then
    log_event "Removing Proxmox API user ${PROXMOX_USER}"
    if pveum user delete "$PROXMOX_USER" >/dev/null 2>&1; then
      log_event "Removed Proxmox API user ${PROXMOX_USER}"
    else
      log_event "WARNING: Failed to remove Proxmox API user ${PROXMOX_USER}"
    fi
  fi

  if [[ "${EXISTING_ROLE_PRESENT}" -eq 1 ]]; then
    log_event "Removing Proxmox role ${PROXMOX_ROLE}"
    if pveum role delete "$PROXMOX_ROLE" >/dev/null 2>&1; then
      log_event "Removed Proxmox role ${PROXMOX_ROLE}"
    else
      log_event "WARNING: Failed to remove Proxmox role ${PROXMOX_ROLE}"
    fi
  fi

  if [[ "${#EXISTING_SNIPPETS[@]}" -gt 0 ]]; then
    log_event "Removed ${#EXISTING_SNIPPETS[@]} snippet(s)"
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
    return 1
  fi

  confirm_slug=$(dialog --backtitle "$BACKTITLE" --title "Twinbox" --inputbox "Type the cluster name to remove it:\n\n${CLUSTER_SLUG}" 12 78 3>&1 1>&2 2>&3) || {
    return 1
  }

  if [[ "$confirm_slug" != "$CLUSTER_SLUG" ]]; then
    msg_error "Cluster name did not match."
    return 1
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
  local next_vmid
  local management_ip

  detected_host=$(hostname -I | awk '{print $1}')
  detected_prefix=$(ip -o -f inet addr show scope global | awk 'NR==1 {split($4, a, "/"); print a[2]}')
  detected_gateway=$(ip route | awk '/^default/ {print $3; exit}')
  detected_dns_ip=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)
  guessed_bridge=$(guess_bridge_interface || true)
  guessed_ssh_key=$(guess_ssh_public_key || true)

  set_cluster_naming_defaults
  next_vmid=$(guess_next_vmid)
  management_ip="$(guess_free_management_ip "${detected_host:-}" || true)"

  MGT_ID="${next_vmid:-100}"
  MGT_RAM="4096"
  MGT_CORES="2"
  MGT_CPU_TYPE="host"
  MGT_DISK="40"
  BRIDGE_IF="${guessed_bridge:-vmbr0}"
  CLOUD_INIT_PASSWORD=""
  CLOUD_INIT_IP="${management_ip:-192.168.1.50}"
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
  PROXMOX_FILE_DATASTORE="local"
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

    gauge_emit 55 "Checking network and free addresses"
    next_vmid=$(guess_next_vmid)

    gauge_emit 75 "Checking network and free addresses"
    management_ip=$(guess_free_management_ip "${detected_host:-}" || true)

    gauge_emit 95 "Checking network and free addresses"

    cat >"$defaults_file" <<EOF
detected_host=$(printf '%q' "${detected_host:-}")
detected_prefix=$(printf '%q' "${detected_prefix:-}")
detected_gateway=$(printf '%q' "${detected_gateway:-}")
detected_dns_ip=$(printf '%q' "${detected_dns_ip:-}")
guessed_bridge=$(printf '%q' "${guessed_bridge:-}")
guessed_ssh_key=$(printf '%q' "${guessed_ssh_key:-}")
next_vmid=$(printf '%q' "${next_vmid:-}")
management_ip=$(printf '%q' "${management_ip:-}")
EOF

    gauge_emit 100 "Checking network and free addresses"
  ) | dialog --backtitle "$BACKTITLE" --title "Twinbox" --gauge "Checking network and free addresses" 10 78 0

  progress_update "Preparing" "Checking network and free addresses"

  # shellcheck disable=SC1090
  source "$defaults_file"
  rm -f "$defaults_file"

  set_cluster_naming_defaults
  MGT_ID="${next_vmid:-100}"
  MGT_RAM="4096"
  MGT_CORES="2"
  MGT_CPU_TYPE="host"
  MGT_DISK="40"
  BRIDGE_IF="${guessed_bridge:-vmbr0}"
  CLOUD_INIT_PASSWORD=""
  CLOUD_INIT_IP="$(guess_free_management_ip "${detected_host:-}" || true)"
  CLOUD_INIT_IP="${CLOUD_INIT_IP:-${management_ip:-192.168.1.50}}"
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
  PROXMOX_FILE_DATASTORE="local"
  KUBECTL_VERSION="v1.30.0"
  HELM_VERSION="v3.15.4"
  TWINBOX_IMAGE_TAG="latest"
}

create_proxmox_api_user() {
  local proxmox_privs="VM.Audit,VM.Monitor,VM.Allocate,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Config.HWType,VM.Config.Cloudinit,VM.PowerMgmt,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,SDN.Use,Sys.Audit"
  local create_err=""
  local role_err=""
  local last_err=""
  local acl_path=""
  local file_datastore="${PROXMOX_FILE_DATASTORE:-local}"

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

  progress_update "Preparing" "Building the VM"
  if create_err=$(pveum user add "$PROXMOX_USER" --comment "Twinbox service account (${CLUSTER_SLUG})" 2>&1); then
    log_event "Created Proxmox API user ${PROXMOX_USER}"
  else
    if printf '%s' "$create_err" | grep -qi "already exists"; then
      log_event "Proxmox API user ${PROXMOX_USER} already exists"
    else
      msg_error "Failed to create Proxmox API user ${PROXMOX_USER}: ${create_err}"
      return 1
    fi
  fi

  log_event "Setting password for ${PROXMOX_USER}"
  if ! set_proxmox_password_with_retry "$PROXMOX_USER" "$PROXMOX_PASSWORD" 15 1; then
    msg_error "Failed to set password for Proxmox API user ${PROXMOX_USER}: ${last_err}"
    return 1
  fi

  log_event "Ensuring least-privilege role ${PROXMOX_ROLE}"
  if role_err=$(pveum role add "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1); then
    :
  else
    if printf '%s' "$role_err" | grep -qi "already exists"; then
      if ! role_err=$(pveum role modify "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1); then
        msg_error "Failed to update Proxmox role ${PROXMOX_ROLE}: ${role_err}"
        return 1
      fi
    else
      msg_error "Failed to create Proxmox role ${PROXMOX_ROLE}: ${role_err}"
      return 1
    fi
  fi

  log_event "Applying ACLs for ${PROXMOX_USER}"
  for acl_path in /vms "/storage/${PROXMOX_STORAGE_POOL}" "/storage/${file_datastore}" /nodes "/nodes/${PROXMOX_NODE}"; do
    if ! apply_acl_with_retry "$acl_path" "$PROXMOX_USER" "$PROXMOX_ROLE" 10 1; then
      msg_error "Failed to apply ACL ${acl_path} for ${PROXMOX_USER}: ${last_err}"
      return 1
    fi
  done
  if ! apply_acl_with_retry "/sdn" "$PROXMOX_USER" "$PROXMOX_ROLE" 10 1; then
    msg_error "Failed to apply ACL /sdn for ${PROXMOX_USER}: ${last_err}"
    return 1
  fi
}

collect_management_vm_settings() {
  local result=""
  result=$(dialog --backtitle "$BACKTITLE" --title "Management VM Settings" \
    --form "Adjust the settings for the management VM:" 18 78 6 \
    "Name:"           1 1 "$MGT_NAME"           1 20 30 0 \
    "IP Address:"     2 1 "$CLOUD_INIT_IP"      2 20 30 0 \
    "Netmask:"        3 1 "$CLOUD_INIT_NETMASK" 3 20 30 0 \
    "DNS Server:"     4 1 "$CLOUD_INIT_DNS_IP"  4 20 30 0 \
    "Disk Size (GB):" 5 1 "$MGT_DISK"           5 20 10 0 \
    "Memory (MB):"    6 1 "$MGT_RAM"            6 20 10 0 \
    3>&1 1>&2 2>&3) || return 1

  MGT_NAME=$(echo "$result" | sed -n '1p')
  CLOUD_INIT_IP=$(echo "$result" | sed -n '2p')
  CLOUD_INIT_NETMASK=$(echo "$result" | sed -n '3p')
  CLOUD_INIT_DNS_IP=$(echo "$result" | sed -n '4p')
  MGT_DISK=$(echo "$result" | sed -n '5p')
  MGT_RAM=$(echo "$result" | sed -n '6p')

  if [[ -z "${MGT_NAME:-}" ]]; then
    msg_error "VM name must not be empty"
    return 1
  fi
  if ! is_valid_ipv4 "${CLOUD_INIT_IP:-}"; then
    msg_error "Invalid VM IP: ${CLOUD_INIT_IP}"
    return 1
  fi
  if ! netmask_to_cidr "${CLOUD_INIT_NETMASK}" >/dev/null 2>&1; then
    msg_error "Invalid VM netmask: ${CLOUD_INIT_NETMASK}"
    return 1
  fi
  if ! is_valid_ipv4 "${CLOUD_INIT_DNS_IP:-}"; then
    msg_error "Invalid DNS server IP: ${CLOUD_INIT_DNS_IP}"
    return 1
  fi
  if [[ ! "${MGT_DISK}" =~ ^[0-9]+$ ]]; then
    msg_error "VM disk size must be a number"
    return 1
  fi
  if [[ ! "${MGT_RAM}" =~ ^[0-9]+$ ]]; then
    msg_error "VM memory must be a number"
    return 1
  fi
}

remove_cluster_flow() {
  set_cluster_naming_defaults
  detect_existing_cluster_resources

  if ! cluster_resources_exist; then
    msg_box "Twinbox" "No resources were found for '${CLUSTER_SLUG}'."
    return 1
  fi

  if ! yesno_box "Twinbox" "$(render_existing_cluster_inventory)\n\nRemove this cluster?" 16 78; then
    return 1
  fi

  local confirm_slug=""
  confirm_slug=$(dialog --backtitle "$BACKTITLE" --title "Twinbox" --inputbox "Type the cluster name to remove it:\n\n${CLUSTER_SLUG}" 12 78 3>&1 1>&2 2>&3) || return 1

  if [[ "$confirm_slug" != "$CLUSTER_SLUG" ]]; then
    msg_error "Cluster name did not match."
    return 1
  fi

  cleanup_existing_cluster_resources
  msg_box "Twinbox" "Cluster removed."
}

start_wizard() {
  local step=1
  local total_steps=6

  WIZARD_ACTION="create"
  
  while [ "$step" -gt 0 ] && [ "$step" -le "$total_steps" ]; do
    case $step in
      1)
        # Choose Cluster Slug
        if ! choose_cluster_slug; then
          return 1
        fi
        step=2
        ;;
      2)
        # Apply Defaults and Handle Conflicts
        run_apply_educated_defaults_with_gauge
        if ! handle_existing_cluster_conflict; then
          step=1
          continue
        fi
        step=3
        ;;
      3)
        # SSH Key
        if [[ -z "${SSH_KEY:-}" ]]; then
          if ! input_box "Twinbox" "SSH public key" "$SSH_KEY" SSH_KEY; then
            step=1
            continue
          fi
        fi
        if [[ -z "${SSH_KEY// }" ]]; then
          msg_error "SSH public key is required for initial access"
          continue
        fi
        step=4
        ;;
      4)
        # VM Settings
        if ! collect_management_vm_settings; then
          step=3
          continue
        fi
        step=5
        ;;
      5)
        # CIDR calculation and Password
        CLOUD_INIT_CIDR=$(netmask_to_cidr "$CLOUD_INIT_NETMASK") || {
          msg_error "Invalid netmask: ${CLOUD_INIT_NETMASK}"
          step=4
          continue
        }
        if ! password_box_confirm "Twinbox" "Cluster login password" CLOUD_INIT_PASSWORD; then
          step=4
          continue
        fi
        step=6
        ;;
      6)
        # Installation
        if run_installation_flow; then
          print_next_steps
          return 0
        else
          return 1
        fi
        ;;
    esac
  done
}

create_management_vm() {
  local ubuntu_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  local img_name="noble-server-cloudimg-amd64.img"
  local img_path="/var/lib/vz/template/cache/${img_name}"
  local CLOUD_INIT_PASSWORD_HASH=""

  CLOUD_INIT_PASSWORD_HASH=$(openssl passwd -6 "$CLOUD_INIT_PASSWORD")

  mkdir -p /var/lib/vz/template/cache /var/lib/vz/snippets

  progress_update "Preparing" "Building the VM"
  if [[ ! -f "$img_path" ]]; then
    log_event "Downloading Ubuntu 24.04 cloud image"
    curl -fsSL -o "$img_path" "$ubuntu_url"
    log_event "Ubuntu image downloaded"
  else
    log_event "Ubuntu image already present"
  fi

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
  - path: /tmp/twinbox.env.template
    permissions: '0600'
    owner: root:root
    content: |
      TWINBOX_CLUSTER_SLUG=${CLUSTER_SLUG}
      TWINBOX_SECRET_BACKEND=vaultwarden
      MANAGEMENT_VM_IP=${CLOUD_INIT_IP}
      VAULTWARDEN_IMAGE_TAG=1.35.4
      VAULTWARDEN_BIND_ADDRESS=0.0.0.0
      VAULTWARDEN_LOCAL_PORT=8222
      VAULTWARDEN_PUBLIC_URL=http://${CLOUD_INIT_IP}:8222
      VAULTWARDEN_DOMAIN=http://${CLOUD_INIT_IP}:8222
      VAULTWARDEN_SERVER_URL=http://${CLOUD_INIT_IP}:8222
      VAULTWARDEN_VAULT_EMAIL=twinbox@local
      VAULTWARDEN_PASSWORD_FILE=/opt/twinbox/bootstrap/vaultwarden-password
      VAULTWARDEN_CLIENTID_FILE=/opt/twinbox/bootstrap/vaultwarden-client-id
      VAULTWARDEN_CLIENTSECRET_FILE=/opt/twinbox/bootstrap/vaultwarden-client-secret
      VAULTWARDEN_READY_FILE=/opt/twinbox/bootstrap/vaultwarden-ready
      VAULTWARDEN_SIGNUPS_ALLOWED=true
      VAULTWARDEN_BOOTSTRAP_APPDATA_DIR=/opt/twinbox/bootstrap/bw-host
      BITWARDENCLI_APPDATA_DIR=/opt/twinbox/bootstrap/bw-runtime
      VAULTWARDEN_ITEM_PREFIX=twinbox
      TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets
      TWINBOX_SECRET_CACHE_TTL_SEC=60
      PROXMOX_HOST=${PROXMOX_HOST}
      PROXMOX_PORT=${PROXMOX_PORT}
      PROXMOX_USER=${PROXMOX_USER}
      PROXMOX_PASSWORD=${PROXMOX_PASSWORD}
      PROXMOX_NODE=${PROXMOX_NODE}
      PROXMOX_STORAGE_POOL=${PROXMOX_STORAGE_POOL}
      PROXMOX_FILE_DATASTORE=${PROXMOX_FILE_DATASTORE}
      KUBECTL_VERSION=${KUBECTL_VERSION}
      HELM_VERSION=${HELM_VERSION}
      TWINBOX_IMAGE_TAG=${TWINBOX_IMAGE_TAG}
      TWINBOX_HOST_REPO_ROOT=${TWINBOX_TARGET_DIR}
      MANAGEMENT_VM_ID=${MGT_ID}
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
  - rm -rf ${TWINBOX_TARGET_DIR}
  - install -d -m 0755 ${TWINBOX_TARGET_DIR}
  - chown ${CLOUD_INIT_USER}:${CLOUD_INIT_USER} ${TWINBOX_TARGET_DIR}
  - bash -lc 'sudo -u ${CLOUD_INIT_USER} -H bash -lc "git clone https://github.com/${GITHUB_REPO}.git ${TWINBOX_TARGET_DIR}"'
  - install -d -m 0700 -o ${CLOUD_INIT_USER} -g ${CLOUD_INIT_USER} ${TWINBOX_TARGET_DIR}/bootstrap
  - bash -lc 'openssl rand -hex 24 > ${TWINBOX_TARGET_DIR}/bootstrap/vaultwarden-password'
  - chown ${CLOUD_INIT_USER}:${CLOUD_INIT_USER} ${TWINBOX_TARGET_DIR}/bootstrap/vaultwarden-password
  - chmod 0600 ${TWINBOX_TARGET_DIR}/bootstrap/vaultwarden-password
  - install -m 0600 -o ${CLOUD_INIT_USER} -g ${CLOUD_INIT_USER} /tmp/twinbox.env.template ${TWINBOX_TARGET_DIR}/.env
  - chown -R ${CLOUD_INIT_USER}:${CLOUD_INIT_USER} ${TWINBOX_TARGET_DIR}
  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && sudo ./scripts/install-management-tools.sh --env-file .env'
  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && docker compose up -d vaultwarden'
  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && chmod +x scripts/bootstrap-vaultwarden.sh && ./scripts/bootstrap-vaultwarden.sh'
  - bash -lc 'sudo -u ${CLOUD_INIT_USER} -H bash -lc "cd ${TWINBOX_TARGET_DIR} && docker compose pull && docker compose up -d"'
CLOUDINIT
  chmod 600 "$snippet_file"

  progress_update "Starting VM" "Starting the VM"
  run_qm_command "create VM" qm create "$MGT_ID" --name "$MGT_NAME" --memory "$MGT_RAM" --cores "$MGT_CORES" --cpu "$MGT_CPU_TYPE" --net0 "virtio,bridge=${BRIDGE_IF}" \
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
  log_event "Starting the management VM"
  qm start "$MGT_ID" >/dev/null

  progress_update "Starting VM" "VM started"
}

discover_management_vm_ip() {
  local output=""
  local ip=""
  local polls=1

  DISCOVERED_MANAGEMENT_IP=""
  progress_update "Waiting for VM" "Waiting for an IP address"
  while true; do
    output=$(qm guest cmd "$MGT_ID" network-get-interfaces 2>/dev/null || true)
    ip=$(
      printf '%s\n' "$output" \
      | grep -Eo '"ip-address"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
      | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"/\1/' \
      | grep -Ev '^(127\.|169\.254\.)' \
      | head -n1 || true
    )

    if [[ -n "$ip" ]]; then
      DISCOVERED_MANAGEMENT_IP="$ip"
      log_event "VM received an IP address"
      return 0
    fi

    if (( polls == 3 )); then
      log_event "Waiting for the VM to request an address."
    elif (( polls == 9 )); then
      log_event "The VM is still booting. This can take a minute or two."
    fi

    sleep 5
    polls=$((polls + 1))
  done
}

wait_for_management_vm_ping() {
  local management_ip="$1"
  local polls=1

  progress_update "Waiting for VM" "Waiting for the VM to come up"
  log_event "The VM is starting on the network."

  while true; do
    if ping -c 1 -W 1 "$management_ip" >/dev/null 2>&1; then
      log_event "The VM is responding on the network"
      return 0
    fi

    if (( polls == 3 )); then
      log_event "Still waiting for the VM to respond to network checks."
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

  progress_update "Waiting for VM" "Waiting for the web UI"
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
  discover_management_vm_ip
  management_ip="${DISCOVERED_MANAGEMENT_IP:-}"
  management_ip="${management_ip:-$CLOUD_INIT_IP}"
  wait_for_web_interface "$management_ip"
  MANAGEMENT_WEB_URL="http://${management_ip}:3000"
  printf '%s\n' "$MANAGEMENT_WEB_URL" >"$completion_state_file"
  log_event "Twinbox URL: ${MANAGEMENT_WEB_URL}"
  FINAL_COMPLETION_MESSAGE="Twinbox URL: ${MANAGEMENT_WEB_URL}"
}

run_installation_flow() {
  local install_exit=0

  set +e
  {
    LIVE_LOG_MODE=1
    log_event "Building the VM."
    create_proxmox_api_user
    create_management_vm
    prepare_completion_message
  } 2>&1 | dialog \
    --backtitle "$BACKTITLE" \
    --title "Twinbox" \
    --programbox "Building the VM." 20 78
  install_exit=${PIPESTATUS[0]}
  LIVE_LOG_MODE=0
  set -e

  if [[ "$install_exit" -ne 0 ]]; then
    exit "$install_exit"
  fi

  MANAGEMENT_WEB_URL=$(tr -d '\r' <"$completion_state_file")
  FINAL_COMPLETION_MESSAGE="Twinbox URL: ${MANAGEMENT_WEB_URL}"
}

print_next_steps() {
  local message="${FINAL_COMPLETION_MESSAGE}"

  msg_box "Twinbox" "${message}\n\nOpen this in your browser:\n\n${MANAGEMENT_WEB_URL}\n\nPress OK to return to the main menu."
}

main() {
  trap cleanup_after_run EXIT
  check_root
  check_deps

  while true; do
    WIZARD_ACTION=""
    if main_menu; then
      if [[ "$WIZARD_ACTION" == "create" ]]; then
        start_wizard || true
      elif [[ "$WIZARD_ACTION" == "remove" ]]; then
        remove_cluster_flow || true
      fi
    else
      # Exit script if Cancel on main menu
      clear
      exit 0
    fi
  done
}

main "$@"
