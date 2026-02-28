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

check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $$) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root"
    exit 1
  fi
}

check_deps() {
  msg_info "Checking dependencies"
  if ! command -v whiptail >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y whiptail curl >/dev/null 2>&1
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

start_wizard() {
  local detected_host
  detected_host=$(hostname -I | awk '{print $1}')

  header_info
  msg_box "Twinbox Setup" "This wizard creates only the Management VM.\n\nThe VM installs Docker CE from the official Docker repo, clones ${GITHUB_REPO}, and starts manager-web automatically."

  input_box "Management VM" "Management VM name" "twinbox-mgt" MGT_NAME
  input_box "Management VM" "Management VM ID" "100" MGT_ID
  input_box "Management VM" "Management VM RAM (MB)" "4096" MGT_RAM
  input_box "Management VM" "Management VM CPU cores" "2" MGT_CORES
  input_box "Management VM" "Management VM disk size (GB)" "40" MGT_DISK
  input_box "Management VM" "Bridge interface" "vmbr0" BRIDGE_IF
  input_box "Management VM" "SSH public key" "" SSH_KEY

  input_box "Manager .env" "Proxmox API host" "${detected_host:-192.168.1.10}" PROXMOX_HOST
  input_box "Manager .env" "Proxmox API port" "8006" PROXMOX_PORT
  input_box "Manager .env" "Proxmox API user" "root@pam" PROXMOX_USER
  password_box "Manager .env" "Proxmox API password" PROXMOX_PASSWORD
  input_box "Manager .env" "Proxmox node" "$(hostname)" PROXMOX_NODE
  input_box "Manager .env" "Proxmox storage pool" "local-lvm" PROXMOX_STORAGE_POOL
  input_box "Manager .env" "Proxmox ISO storage" "local" PROXMOX_ISO_STORAGE
  input_box "Manager .env" "Talos ISO file" "talos-v1.7.4.iso" TALOS_ISO_FILE
  input_box "Manager .env" "Image tag" "latest" TWINBOX_IMAGE_TAG

  if whiptail --yesno "Proceed with installation?\n\nVM Name: $MGT_NAME\nVM ID: $MGT_ID\nBridge: $BRIDGE_IF\nRepo: ${GITHUB_REPO}\nAuto-start manager stack: yes" 16 78; then
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

  local snippet_file="/var/lib/vz/snippets/mgt-${MGT_ID}-user-data.yaml"

  cat > "$snippet_file" <<CLOUDINIT
#cloud-config
hostname: ${MGT_NAME}
manage_etc_hosts: true
users:
  - default
  - name: ubuntu
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
write_files:
  - path: /home/ubuntu/twinbox.env.template
    permissions: '0600'
    owner: ubuntu:ubuntu
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
  - chown ubuntu:ubuntu /opt/twinbox
  - bash -lc 'if [ ! -d /opt/twinbox/.git ]; then git clone https://github.com/${GITHUB_REPO}.git /opt/twinbox; fi'
  - bash -lc 'cp /home/ubuntu/twinbox.env.template /opt/twinbox/.env'
  - bash -lc 'cd /opt/twinbox && docker compose pull'
  - bash -lc 'cd /opt/twinbox && docker compose up -d'
CLOUDINIT

  qm create "$MGT_ID" --name "$MGT_NAME" --memory "$MGT_RAM" --cores "$MGT_CORES" --net0 "virtio,bridge=${BRIDGE_IF}" \
    --scsihw virtio-scsi-pci --ide2 local-lvm:cloudinit --serial0 socket --vga serial0 --ostype l26 >/dev/null
  qm importdisk "$MGT_ID" "$img_path" local-lvm >/dev/null
  qm set "$MGT_ID" --scsi0 "local-lvm:vm-${MGT_ID}-disk-0" >/dev/null
  qm set "$MGT_ID" --cicustom "user=local:snippets/$(basename "$snippet_file")" >/dev/null
  qm set "$MGT_ID" --boot order=scsi0 >/dev/null
  qm resize "$MGT_ID" scsi0 "${MGT_DISK}G" >/dev/null
  qm start "$MGT_ID" >/dev/null

  msg_ok "Management VM created"
}

print_next_steps() {
  echo
  echo -e "${GN}Installation complete${CL}"
  echo
  echo "Next steps:"
  echo "1. Wait for cloud-init on the management VM to finish."
  echo "2. Open: http://<management-vm-ip>:3000"
  echo "3. Verify API health: http://<management-vm-ip>:8080/api/health"
  echo "4. If needed, edit /opt/twinbox/.env and run: cd /opt/twinbox && docker compose up -d"
  echo
}

main() {
  check_root
  check_deps
  start_wizard
}

main "$@"
