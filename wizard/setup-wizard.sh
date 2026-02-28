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

  IFS='.' read -r -a octets <<<"$netmask"
  if [[ "${#octets[@]}" -ne 4 ]]; then
    return 1
  fi

  for octet in "${octets[@]}"; do
    case "$octet" in
      255) cidr=$((cidr + 8)) ;;
      254) cidr=$((cidr + 7)) ;;
      252) cidr=$((cidr + 6)) ;;
      248) cidr=$((cidr + 5)) ;;
      240) cidr=$((cidr + 4)) ;;
      224) cidr=$((cidr + 3)) ;;
      192) cidr=$((cidr + 2)) ;;
      128) cidr=$((cidr + 1)) ;;
      0) cidr=$cidr ;;
      *) return 1 ;;
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

  detected_host=$(hostname -I | awk '{print $1}')
  detected_prefix=$(ip -o -f inet addr show scope global | awk 'NR==1 {split($4, a, "/"); print a[2]}')
  detected_gateway=$(ip route | awk '/^default/ {print $3; exit}')
  detected_dns_ip=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)
  guessed_bridge=$(guess_bridge_interface || true)
  guessed_ssh_key=$(guess_ssh_public_key || true)

  MGT_NAME="twinbox-mgt"
  MGT_ID=$(guess_next_vmid)
  MGT_RAM="4096"
  MGT_CORES="2"
  MGT_DISK="40"
  BRIDGE_IF="${guessed_bridge:-vmbr0}"
  CLOUD_INIT_USER="twinbox"
  CLOUD_INIT_PASSWORD=""
  CLOUD_INIT_IP="${detected_host:-192.168.1.50}"
  CLOUD_INIT_NETMASK="$(cidr_to_netmask "${detected_prefix:-24}")"
  CLOUD_INIT_GATEWAY="${detected_gateway:-192.168.1.1}"
  CLOUD_INIT_DNS_DOMAIN="localdomain"
  CLOUD_INIT_DNS_IP="${detected_dns_ip:-1.1.1.1}"
  SSH_KEY="${guessed_ssh_key:-}"

  PROXMOX_HOST="${detected_host:-192.168.1.10}"
  PROXMOX_PORT="8006"
  PROXMOX_USER="root@pam"
  PROXMOX_PASSWORD=$(generate_cloud_init_password)
  PROXMOX_NODE="$(hostname)"
  PROXMOX_STORAGE_POOL="local-lvm"
  PROXMOX_ISO_STORAGE="local"
  TALOS_ISO_FILE="talos-v1.7.4.iso"
  TWINBOX_IMAGE_TAG="latest"
}

collect_manual_overrides() {
  if review_management_settings; then
    input_box "Management VM" "Management VM name (name shown in Proxmox UI)" "$MGT_NAME" MGT_NAME
    input_box "Management VM" "Management VM ID (unique VMID in Proxmox)" "$MGT_ID" MGT_ID
    input_box "Management VM" "Management VM RAM (MB) for manager services" "$MGT_RAM" MGT_RAM
    input_box "Management VM" "Management VM CPU cores for manager services" "$MGT_CORES" MGT_CORES
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
    input_box "Manager .env" "Image tag (Twinbox container image tag)" "$TWINBOX_IMAGE_TAG" TWINBOX_IMAGE_TAG
  fi
}

review_management_settings() {
  if whiptail --yesno "Management VM settings\n\nName: $MGT_NAME\nVMID: $MGT_ID\nRAM: ${MGT_RAM}MB\nCPU cores: $MGT_CORES\nDisk: ${MGT_DISK}GB\nBridge: $BRIDGE_IF\n\nEdit this group?" 18 78 --title "Management VM"; then
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
  if whiptail --yesno "Manager API settings\n\nHost: $PROXMOX_HOST\nPort: $PROXMOX_PORT\nUser: $PROXMOX_USER\nNode: $PROXMOX_NODE\nStorage: $PROXMOX_STORAGE_POOL\nISO storage: $PROXMOX_ISO_STORAGE\nTalos ISO: $TALOS_ISO_FILE\nImage tag: $TWINBOX_IMAGE_TAG\n\nEdit this group?" 22 78 --title "Manager .env"; then
    return 0
  fi
  return 1
}

start_wizard() {
  apply_educated_defaults

  header_info
  msg_box "Twinbox Setup" "This wizard creates only the Management VM.\n\nIt defaults to educated guesses and groups advanced values into 3 sections:\n- Management VM sizing/network\n- Cloud-Init access/network\n- Manager API/runtime settings\n\nYou can review each group and edit only what you need."

  if whiptail --yesno "Use recommended settings with educated guesses?" 10 78; then
    :
  else
    collect_manual_overrides
  fi

  if [[ -z "${SSH_KEY:-}" ]]; then
    input_box "Cloud-Init" "SSH public key" "" SSH_KEY
  fi

  password_box "Cloud-Init" "Twinbox login password" CLOUD_INIT_PASSWORD
  input_box "Cloud-Init" "Static IPv4 address (management VM)" "$CLOUD_INIT_IP" CLOUD_INIT_IP
  input_box "Cloud-Init" "Netmask (for example 255.255.255.0)" "$CLOUD_INIT_NETMASK" CLOUD_INIT_NETMASK
  input_box "Cloud-Init" "Default route (gateway)" "$CLOUD_INIT_GATEWAY" CLOUD_INIT_GATEWAY

  CLOUD_INIT_CIDR=$(netmask_to_cidr "$CLOUD_INIT_NETMASK") || {
    msg_error "Invalid netmask: ${CLOUD_INIT_NETMASK}"
    exit 1
  }

  msg_box "Security Notice" "Phase 1 is LAN-only and stores Proxmox credentials in /opt/twinbox/.env on the management VM.\n\nUse a dedicated Proxmox automation account and rotate credentials regularly."

  if whiptail --yesno "Proceed with installation?\n\nVM Name: $MGT_NAME\nVM ID: $MGT_ID\nBridge: $BRIDGE_IF\nCloud-Init user: $CLOUD_INIT_USER\nDNS: ${CLOUD_INIT_DNS_IP} (${CLOUD_INIT_DNS_DOMAIN})\nRepo: ${GITHUB_REPO}\nAuto-start manager stack: yes" 18 78; then
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

  mkdir -p /var/lib/vz/template/cache /var/lib/vz/snippets

  if [[ ! -f "$img_path" ]]; then
    msg_info "Downloading Ubuntu 24.04 cloud image"
    curl -fsSL -o "$img_path" "$ubuntu_url"
    msg_ok "Ubuntu image downloaded"
  else
    msg_ok "Ubuntu image already present"
  fi

  msg_info "Creating management VM (ID: $MGT_ID)"

  snippet_file="/var/lib/vz/snippets/mgt-${MGT_ID}-user-data.yaml"

  cat > "$snippet_file" <<CLOUDINIT
#cloud-config
hostname: ${MGT_NAME}
manage_etc_hosts: true
users:
  - name: ${CLOUD_INIT_USER}
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
  - path: /home/${CLOUD_INIT_USER}/twinbox.env.template
    permissions: '0600'
    owner: ${CLOUD_INIT_USER}:${CLOUD_INIT_USER}
    content: |
      PROXMOX_HOST=${PROXMOX_HOST}
      PROXMOX_PORT=${PROXMOX_PORT}
      PROXMOX_USER=${PROXMOX_USER}
      PROXMOX_PASSWORD=${PROXMOX_PASSWORD}
      PROXMOX_NODE=${PROXMOX_NODE}
      PROXMOX_STORAGE_POOL=${PROXMOX_STORAGE_POOL}
      PROXMOX_ISO_STORAGE=${PROXMOX_ISO_STORAGE}
      TALOS_ISO_FILE=${TALOS_ISO_FILE}
      TWINBOX_IMAGE_TAG=${TWINBOX_IMAGE_TAG}
runcmd:
  - install -m 0755 -d /etc/apt/keyrings
  - bash -lc 'apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true'
  - bash -lc 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc'
  - chmod a+r /etc/apt/keyrings/docker.asc
  - bash -lc 'echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list'
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - bash -lc 'docker --version'
  - bash -lc 'docker compose version'
  - install -d -m 0755 /opt/twinbox
  - chown ${CLOUD_INIT_USER}:${CLOUD_INIT_USER} /opt/twinbox
  - bash -lc 'if [ ! -d /opt/twinbox/.git ]; then git clone https://github.com/${GITHUB_REPO}.git /opt/twinbox; fi'
  - bash -lc 'cp /home/${CLOUD_INIT_USER}/twinbox.env.template /opt/twinbox/.env'
  - bash -lc 'cd /opt/twinbox && docker compose pull'
  - bash -lc 'cd /opt/twinbox && docker compose up -d'
CLOUDINIT
  chmod 600 "$snippet_file"

  qm create "$MGT_ID" --name "$MGT_NAME" --memory "$MGT_RAM" --cores "$MGT_CORES" --net0 "virtio,bridge=${BRIDGE_IF}" \
    --tags "twinbox;management;docker;bootstrap" \
    --scsihw virtio-scsi-pci --ide2 local-lvm:cloudinit --serial0 socket --vga serial0 --ostype l26 >/dev/null
  vm_created=1
  qm importdisk "$MGT_ID" "$img_path" local-lvm >/dev/null
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
  qm start "$MGT_ID" >/dev/null

  msg_ok "Management VM created"
}

discover_management_vm_ip() {
  local attempts=24
  local output=""
  local ip=""

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

    sleep 5
    attempts=$((attempts - 1))
  done

  return 1
}

print_next_steps() {
  local management_ip=""
  management_ip=$(discover_management_vm_ip || true)

  echo
  echo -e "${GN}Installation complete${CL}"
  echo
  echo "Next steps:"
  if [[ -n "${management_ip:-}" ]]; then
    echo "1. Wait for cloud-init on the management VM to finish."
    echo "2. Open: http://${management_ip}:3000"
    echo "3. Verify API health: http://${management_ip}:8080/api/health"
  else
    echo "1. Wait for cloud-init on the management VM to finish."
    echo "2. Open: http://<management-vm-ip>:3000"
  echo "3. Verify API health: http://<management-vm-ip>:8080/api/health"
  fi
  echo "Login user: ${CLOUD_INIT_USER}"
  echo "Login password: ${CLOUD_INIT_PASSWORD}"
  echo "Proxmox API user: ${PROXMOX_USER}"
  echo "Proxmox API password: ${PROXMOX_PASSWORD}"
  echo "4. If needed, edit /opt/twinbox/.env and run: cd /opt/twinbox && docker compose up -d"
  echo
}

main() {
  trap cleanup_after_run EXIT
  check_root
  check_deps
  start_wizard
}

main "$@"
