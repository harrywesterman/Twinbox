#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBUNTU_VER="22.04"
CLOUD_IMG="http://cloud-images.ubuntu.com/releases/${UBUNTU_VER}/release/ubuntu-${UBUNTU_VER}-live-server-amd64.img"
CPU_CORES=2; RAM_MB=4096; DISK_GB=32; BRIDGE="vmbr0"; STORAGE="local-lvm"
CLUSTER=""; SELECTED=""
log() { echo -e "${YELLOW}[*] $*${NC}"; }
ok() { echo -e "${GREEN}[✓] $*${NC}"; }
err() { echo -e "${RED}[✗] $*${NC}" >&2; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }

check_proxmox() {
    [[ -d /etc/pve ]] || { err "This script must run on a Proxmox VE host"; exit 1; }
    command -v qm &>/dev/null || { err "qm command not found. Is Proxmox installed?"; exit 1; }
    ok "Proxmox environment verified"
}

prompt_cluster() {
    while true; do
        read -p "Cluster name (alphanumeric, no spaces): " CLUSTER
        [[ "$CLUSTER" =~ ^[a-zA-Z0-9-]+$ ]] && break || warn "Invalid cluster name."
    done
    nodes=($(pvesh get /nodes -output-format json 2>/dev/null | jq -r '.[] | select(.status=="online") | .id' 2>/dev/null || echo ""))
    if [[ ${#nodes[@]} -eq 0 ]]; then
        warn "No online nodes found. Using 'localhost'"; SELECTED="localhost"
    elif [[ ${#nodes[@]} -eq 1 ]]; then
        SELECTED="${nodes[0]}"; ok "Using node: $SELECTED"
    else
        echo "Available nodes:"; for i in "${!nodes[@]}"; do echo "  $((i+1)). ${nodes[i]}"; done
        read -p "Select node (1-${#nodes[@]}, default 1): " sel; [[ -z "$sel" ]] && sel=1
        SELECTED="${nodes[$((sel-1))]}"
    fi
}

prompt_resources() {
    read -p "Management VM CPU cores? (default $CPU_CORES): " inp; CPU_CORES=${inp:-$CPU_CORES}
    read -p "Management VM RAM (GB)? (default $((RAM_MB/1024))): " inp; [[ -n "$inp" ]] && RAM_MB=$((inp * 1024))
    read -p "Management VM disk (GB)? (default $DISK_GB): " inp; [[ -n "$inp" ]] && DISK_GB=$inp
    read -p "Network bridge? (default $BRIDGE): " inp; BRIDGE=${inp:-$BRIDGE}
}

create_twinbox_user() {
    log "Creating Proxmox user and permissions..."
    if ! pvesh get /access/users/twinbox@pve &>/dev/null; then
        local pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 16)
        pvesh create /access/users -userid twinbox@pve -password "$pass" 2>/dev/null || true
        ok "Created user: twinbox@pve"
    fi
    local pool="twinbox-${CLUSTER}"
    if ! pvesh get /pools/$pool &>/dev/null; then
        pvesh create /pools -poolid "$pool" 2>/dev/null || true
        ok "Created resource pool: $pool"
    fi
    pvesh set /pools/$pool/acl -path / --group user:twinbox@pve -roles "VM.Create,VM.Modify,VM.PowerMgmt,Pool.List" 2>/dev/null || true
    ok "Set ACLs on pool $pool"
}

gen_token() {
    log "Generating API token..."
    local json=$(pvesh create /access/tokens -userid twinbox@pve -privsep 0 -expire Never -output-format json 2>/dev/null || echo "{}")
    local name=$(echo "$json" | jq -r '.data.value // empty' 2>/dev/null)
    local secret=$(echo "$json" | jq -r '.data.secret // empty' 2>/dev/null)
    if [[ -n "$name" && -n "$secret" ]]; then
        ok "Token generated"
        cat > "/tmp/twinbox-creds-$CLUSTER.env" <<EOF
API_TOKEN_NAME=$name
API_TOKEN_SECRET=$secret
API_URL=https://$SELECTED:8006/api2/json
EOF
    else
        err "Token generation failed"; exit 1;
    fi
}

get_ubuntu_iso() {
    local iso_dir="/var/lib/vz/template/iso"
    local iso_name="ubuntu-${UBUNTU_VER}-live-server-amd64.img"
    local iso_path="$iso_dir/$iso_name"
    mkdir -p "$iso_dir"
    if [[ -f "$iso_path" ]]; then
        ok "Ubuntu image exists: $iso_path"; ISO="$iso_path"; return
    fi
    log "Downloading Ubuntu $UBUNTU_VER..."
    curl -sL -o "$iso_path" "$CLOUD_IMG" && ok "Downloaded" || { err "Download failed"; exit 1; }
    ISO="$iso_path"
}

create_cloudinit() {
    local out="/tmp/cloud-init-$CLUSTER.yml"
    local creds_file="/tmp/twinbox-creds-$CLUSTER.env"
    [[ -f "$creds_file" ]] || { err "Credentials file not found. Run gen_token first."; exit 1; }
    source "$creds_file"

    local tmpl="$SCRIPT_DIR/cloud-init.yml"
    if [[ -f "$tmpl" ]]; then
        cp "$tmpl" "$out"
    else
        cat > "$out" <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages: [docker.io, docker-compose, jq, yq, curl, git, python3-pip, python3-yaml]
runcmd:
  - [groupadd, -g, 999, twinbox]
  - [useradd, -u, 999, -g, twinbox, -m, -s, /bin/bash, twinbox]
  - [usermod, -aG, docker, twinbox]
  - [mkdir, -p, /opt/twinbox]
  - [chown, -R, twinbox:twinbox, /opt/twinbox]
write_files:
  - path: /opt/twinbox/config/proxmox-creds.yaml
    permissions: '0600'
    owner: twinbox:twinbox
    content: |
      api_url: "${API_URL}"
      user: "twinbox@pve"
      token: "${API_TOKEN_SECRET}"
      verify_ssl: false
  - path: /opt/twinbox/config/cluster-name
    permissions: '0644'
    owner: twinbox:twinbox
    content: |
      CLUSTER_NAME=${CLUSTER}
EOF
    fi

    local db_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32 2>/dev/null || echo "CHANGE_$(date +%s)")
    local sec_key=$(openssl rand -base64 32 2>/dev/null || echo "CHANGE_$(date +%s)")
    cat >> "$out" <<EOF

write_files:
  - path: /opt/twinbox/.env
    permissions: '0600'
    owner: twinbox:twinbox
    content: |
      DATABASE_URL=postgresql://twinbox:${db_pass}@localhost:5432/twinbox
      REDIS_URL=redis://localhost:6379/0
      SECRET_KEY=${sec_key}
      PROXMOX_CREDENTIALS_PATH=/opt/twinbox/config/proxmox-creds.yaml
      CLUSTER_NAME=${CLUSTER}
EOF
    ok "Cloud-init generated: $out"
    echo "$out"
}

create_vm() {
    local vmid=$(qm list 2>/dev/null | awk 'NR>1 {if($1>m) m=$1} END {print (m?m+1:100)}')
    local name="twinbox-mgmt-${CLUSTER}"
    log "Creating VM $vmid: $name"
    qm create "$vmid" --name "$name" --memory "$RAM_MB" --cores "$CPU_CORES" \
        --net0 "virtio,bridge=$BRIDGE" --scsihw "virtio-scsi" \
        --scsi0 "$STORAGE:${DISK_GB},ssd=1" --cdrom "$ISO" \
        --boot "order=scsi0" --ostype "l26" --bios seabios 2>/dev/null \
        || { err "Failed to create VM"; exit 1; }
    ok "VM $vmid created"

    local ci_file=$(create_cloudinit)
    qm set "$vmid" --cicustom "user=local:0,cloud-init.yml,$ci_file" \
        --ipconfig0 "ip=dhcp" 2>/dev/null || warn "Cloud-init config may need manual setup"
    echo "$vmid"
}

wait_ip() {
    local vmid="$1" wait=300 interval=5
    log "Waiting for VM IP address..."
    while (( wait > 0 )); do
        if qm status "$vmid" 2>/dev/null | grep -q running; then
            local ip=$(qm guest cmd "$vmid" "hostname -I" 2>/dev/null | tr -d '[:space:]')
            [[ -n "$ip" ]] && { ok "IP: $ip"; echo "$ip"; return 0; }
        fi
        sleep "$interval"; wait=$((wait-interval))
        printf " \r%3ds remaining" "$wait"
    done
    echo ""; read -p "Enter IP manually: " manual_ip; echo "$manual_ip"
}

main() {
    clear; echo "=== Twinbox Setup Wizard ==="
    check_proxmox; prompt_cluster; prompt_resources
    log "Configuration:"; echo "  Cluster: $CLUSTER"; echo "  Node: $SELECTED"
    echo "  VM: ${CPU_CORES} CPU, ${RAM_MB}MB RAM, ${DISK_GB}GB disk"; echo "  Bridge: $BRIDGE"
    create_twinbox_user; gen_token; get_ubuntu_iso
    local vmid=$(create_vm); qm start "$vmid"
    local ip=$(wait_ip "$vmid")
    cat <<EOF

==========================================
 Twinbox Setup Complete!
==========================================

Management VM ready!

  VM ID: $vmid
  Name: twinbox-mgmt-$CLUSTER
  IP: $ip

1. Wait 1-2 minutes for cloud-init to finish
2. Open browser to: http://$ip:8080
3. You'll see the Twinbox web interface

To access the VM:
  ssh ubuntu@$ip

The cluster will be ready to deploy from the web UI.

==========================================
EOF
}
main "$@"
