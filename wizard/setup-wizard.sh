#!/usr/bin/env bash
set -euo pipefail

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CPU=2
DEFAULT_RAM=4
DEFAULT_DISK=32
UBUNTU_VER="22.04"
UBUNTU_REL="jammy"
CLOUD_IMG="http://cloud-images.ubuntu.com/${UBUNTU_REL}/current/ubuntu-${UBUNTU_VER}-live-server-amd64.img"
STORAGE="local-lvm"
BRIDGE="vmbr0"
REPO="https://github.com/your-org/twinbox.git"

# Logging
log()   { echo -e "\033[1;33m[INFO]\033[0m $*" >&2; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*" >&2; }
err()   { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }

# Check Proxmox
check_proxmox() {
    [[ -d /etc/pve ]] || { err "Not a Proxmox host."; exit 1; }
    command -v qm >/dev/null || { err "qm not found."; exit 1; }
    command -v pvesh >/dev/null || { err "pvesh not found."; exit 1; }
    ok "Proxmox detected"
}

# Prompt functions
prompt() {
    local msg="$1" default="$2" varname="$3"
    read -p "$msg [$default]: " val
    eval "$varname=\"\${val:-$default}\""
}

prompt_cluster() {
    local def="twinbox-$(hostname)"
    while true; do
        read -p "Cluster name? [$def]: " name
        CLUSTER="${name:-$def}"
        [[ "$CLUSTER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && break
        err "Alphanumeric only, start with letter/number"
    done
}

prompt_resources() {
    prompt "Management VM CPU" "$DEFAULT_CPU" CPU_CORES
    while true; do
        prompt "Management VM RAM (GB)" "$DEFAULT_RAM" RAM_GB
        [[ "$RAM_GB" =~ ^[0-9]+$ && $RAM_GB -ge 2 ]] && break
        err "Minimum 2GB"
    done
    RAM_MB=$((RAM_GB * 1024))
    while true; do
        prompt "Management VM disk (GB)" "$DEFAULT_DISK" DISK_GB
        [[ "$DISK_GB" =~ ^[0-9]+$ && $DISK_GB -ge 20 ]] && break
        err "Minimum 20GB"
    done
}

select_node() {
    log "Detecting nodes..."
    mapfile -t NODES < <(pvesh get /nodes -quiet 2>/dev/null || qm list 2>/dev/null | awk 'NR>1 {print $4}' | sort -u)

    [[ ${#NODES[@]} -ge 1 ]] || { err "No nodes found"; exit 1; }

    if [[ ${#NODES[@]} -eq 1 ]]; then
        SELECTED="${NODES[0]}"
        return
    fi

    echo "Nodes:"
    for i in "${!NODES[@]}"; do echo "  $((i+1)). ${NODES[i]}"; done
    while true; do
        read -p "Select (1-${#NODES[@]}) [auto]: " sel
        if [[ -z "$sel" ]]; then
            SELECTED="${NODES[0]}"  # Simple: pick first
            break
        elif [[ "$sel" =~ ^[0-9]+$ && $sel -ge 1 && $sel -le ${#NODES[@]} ]]; then
            SELECTED="${NODES[$((sel-1))]}"
            break
        fi
        err "Invalid"
    done
    ok "Node: $SELECTED"
}

check_resources() {
    local need_ram=$((RAM_GB * 1024 * 1024 * 1024))
    local need_disk=$((DISK_GB * 1024 * 1024 * 1024))

    local json
    json=$(pvesh get /nodes/$SELECTED/status 2>/dev/null || echo "{}")
    local free_ram=$(echo "$json" | jq -r '.memory.free // 0' 2>/dev/null || echo 0)
    local free_disk=$(echo "$json" | jq -r '.disk_free // 0' 2>/dev/null || echo 0)

    (( free_ram < need_ram )) && { warn "Low RAM: $((free_ram/1024/1024/1024))GB free"; read -p "Continue? (y/n): " c; [[ "$c" == "y" ]] || exit 1; } || ok "RAM OK"
    (( free_disk < need_disk )) && { warn "Low disk: $((free_disk/1024/1024/1024))GB free"; read -p "Continue? (y/n): " c; [[ "$c" == "y" ]] || exit 1; } || ok "Disk OK"
}

gen_pass() { openssl rand -base64 32 | tr -d '/+=' | head -c 32; }

create_pve_user() {
    local pass
    pass=$(gen_pass)
    if pvesh create /access/users -userid twinbox@pve -password "$pass" &>/dev/null; then
        ok "Created twinbox@pve"
        echo "$pass" >"/tmp/twinbox-pass-$CLUSTER.txt"
    else
        pvesh set /access/users/twinbox@pve -password "$pass" 2>/dev/null && ok "Updated twinbox@pve" || warn "User setup skipped"
    fi
}

create_pool() {
    local pool="twinbox-$CLUSTER"
    pvesh create /pools -poolid "$pool" &>/dev/null || warn "Pool exists"
    pvesh set "/pools/$pool/acl" -path / -group user:twinbox@pve -roles "VM.Create,VM.Modify,VM.PowerMgmt,Pool.List,SDN.Use" &>/dev/null \
        || pveum aclmod -group user:twinbox@pve -role "PVEAdmin" -path "/pools/$pool" 2>/dev/null \
        || warn "Permission error"
    ok "Pool + ACL: $pool"
}

gen_token() {
    local json
    json=$(pvesh create /access/tokens -userid twinbox@pve -privsep 0 -expire Never -output-format json 2>/dev/null || echo "{}")
    local name=$(echo "$json" | jq -r '.data.value // empty' 2>/dev/null)
    local secret=$(echo "$json" | jq -r '.data.secret // empty' 2>/dev/null)
    if [[ -n "$name" && -n "$secret" ]]; then
        ok "Token: $name"
        cat > "/tmp/twinbox-creds-$CLUSTER.env" <<EOF
API_TOKEN_NAME=$name
API_TOKEN_SECRET=$secret
API_URL=https://$SELECTED:8006/api2/json
EOF
    else
        warn "Token generation failed"
    fi
}

get_ubuntu_iso() {
    local iso_dir="/var/lib/vz/template/iso"
    local iso_name="ubuntu-${UBUNTU_VER}-live-server-amd64.img"
    local iso_path="$iso_dir/$iso_name"

    mkdir -p "$iso_dir"
    if [[ -f "$iso_path" ]]; then
        ok "Ubuntu image exists"
        ISO="$iso_path"
        return
    fi

    log "Downloading Ubuntu $UBUNTU_VER..."
    curl -sL -o "$iso_path" "$CLOUD_IMG" && ok "Downloaded" || { err "Download failed"; exit 1; }
    ISO="$iso_path"
}

create_cloudinit() {
    local out="/tmp/cloud-init-$CLUSTER.yml"
    local tmpl="$SCRIPT_DIR/cloud-init.yml"

    if [[ -f "$tmpl" ]]; then
        cp "$tmpl" "$out"
    else
        cat > "$out" <<'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages: [docker.io, docker-compose, jq, yq, curl, git]
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
      api_url: "https://localhost:8006/api2/json"
      user: "twinbox@pve"
      token: ""
      verify_ssl: false
EOF
    fi

    # Inject secrets
    local db_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32 2>/dev/null || echo "CHANGE_$(date +%s)")
    local sec_key=$(openssl rand -base64 32 2>/dev/null || echo "CHANGE_$(date +%s)")
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$db_pass/; s/SECRET_KEY=.*/SECRET_KEY=$sec_key/" "$out" 2>/dev/null || true

    ok "Cloud-init: $out"
    echo "$out"
}

create_vm() {
    local vmid
    vmid=$(qm list 2>/dev/null | awk 'NR>1 {if($1>m) m=$1} END {print (m?m+1:100)}')
    local name="twinbox-mgmt-$CLUSTER"

    qm create "$vmid" \
        --name "$name" \
        --memory "$RAM_MB" \
        --cores "$CPU_CORES" \
        --net0 "virtio,bridge=$BRIDGE" \
        --scsihw "virtio-scsi" \
        --scsi0 "$STORAGE:${DISK_GB},ssd=1" \
        --cdrom "$ISO" \
        --boot "order=scsi0" \
        --ostype "l26" \
        --bios seabios

    ok "VM $vmid created"

    local ci_file
    ci_file=$(create_cloudinit)
    qm set "$vmid" \
        --cicustom "user=local:0,cloud-init.yml,$ci_file" \
        --ipconfig0 "ip=dhcp" \
        2>/dev/null || warn "Cloud-init config may need manual setup"

    echo "$vmid"
}

wait_ip() {
    local vmid="$1" wait=300 interval=5
    log "Waiting for IP..."
    while (( wait > 0 )); do
        if qm status "$vmid" 2>/dev/null | grep -q running; then
            local ip
            ip=$(qm guest cmd "$vmid" "hostname -I" 2>/dev/null | tr -d '[:space:]')
            [[ -n "$ip" ]] && { ok "IP: $ip"; echo "$ip"; return 0; }
        fi
        sleep "$interval"
        wait=$((wait-interval))
        printf " \r%3ds remaining" "$wait"
    done
    echo ""
    read -p "Enter IP manually: " manual_ip
    echo "$manual_ip"
}

main() {
    clear
    echo "=== Twinbox Setup Wizard ==="
    check_proxmox
    prompt_cluster
    prompt_resources
    select_node
    check_resources

    read -p "\nCreate VM on $SELECTED with ${CPU_CORES}CPU/${RAM_GB}GB/${DISK_GB}GB? (y/n): " c
    [[ "$c" == "y" ]] || { log "Cancelled"; exit 0; }

    log "\nStarting setup..."
    create_pve_user
    create_pool
    gen_token
    get_ubuntu_iso

    echo ""
    local vmid
    vmid=$(create_vm)
    echo ""

    qm start "$vmid"
    ok "VM started"

    local vm_ip
    vm_ip=$(wait_ip "$vmid")

    echo ""
    echo "=== Setup Complete ==="
    echo "VM ID: $vmid"
    echo "VM Name: twinbox-mgmt-$CLUSTER"
    echo "VM IP: ${vm_ip:-<unknown>}"
    echo ""
    echo "Next:"
    echo "1. SSH: ssh ubuntu@$vm_ip"
    echo "2. Clone: git clone $REPO /opt/twinbox"
    echo "3. Copy: /tmp/twinbox-creds-$CLUSTER.env to /opt/twinbox/.env"
    echo "4. Web UI: http://$vm_ip:8080"
    echo ""
    log "Creds saved in /tmp/twinbox-*.txt and /tmp/twinbox-creds-*.env"
}

main "$@"
