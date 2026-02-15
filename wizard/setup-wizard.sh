#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
UBUNTU_VER="noble"
CLOUD_IMG="https://cloud-images.ubuntu.com/${UBUNTU_VER}/current/${UBUNTU_VER}-server-cloudimg-amd64.img"
CPU_CORES=2; RAM_MB=4096; DISK_GB=32; BRIDGE="vmbr0"; STORAGE="local-lvm"
CLUSTER=""; SELECTED=""

log() { echo -e "${YELLOW}[*] $*${NC}" >&2; }
ok() { echo -e "${GREEN}[✓] $*${NC}" >&2; }
err() { echo -e "${RED}[✗] $*${NC}" >&2; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }

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

    # Always use the local node (the node where this script is running)
    SELECTED=$(hostname -s 2>/dev/null || echo "localhost")
    ok "Using local node: $SELECTED"
}

# Resources are using defaults; no prompts needed

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
    if [[ -f "/tmp/twinbox-creds-$CLUSTER.env" ]]; then
        ok "Using existing credentials file"
        return 0
    fi

    local token_id="twinbox-token-$(date +%s)"
    local token_output
    token_output=$(pveum user token add twinbox@pve "$token_id" --privsep 0 2>&1)

    if [[ -n "$token_output" ]]; then
        local token_name="twinbox@pve!$(echo "$token_output" | head -n1 | tr -d '[:space:]')"
        local token_secret=$(echo "$token_output" | tail -n1 | tr -d '[:space:]')
        if [[ -n "$token_name" && -n "$token_secret" && "$token_name" != "!" ]]; then
            ok "Token generated: $token_name"
            cat > "/tmp/twinbox-creds-$CLUSTER.env" <<EOF
API_TOKEN_NAME=$token_name
API_TOKEN_SECRET=$token_secret
API_URL=https://$SELECTED:8006/api2/json
EOF
        else
            err "Token generation failed: could not parse output"
            echo "Output was: $token_output"
            exit 1
        fi
    else
        err "Token generation failed: pveum returned empty output"
        exit 1
    fi
}

get_ubuntu_iso() {
    local iso_dir="/var/lib/vz/template/iso"
    local iso_name="${UBUNTU_VER}-server-cloudimg-amd64.img"
    local iso_path="$iso_dir/$iso_name"

    # Check if ISO already exists in Proxmox storage
    if pvesh get /nodes/$SELECTED/storage/local/content --output-format json 2>/dev/null | \
        python3 -c "import sys, json; content = json.load(sys.stdin); print('yes' if any(item.get('volid','').endswith('$iso_name') for item in content) else 'no')" 2>/dev/null | grep -q yes; then
        ok "Ubuntu cloud image already in storage: $iso_name"
        ISO="local:iso/$iso_name"
        return
    fi

    mkdir -p "$iso_dir"
    if [[ -f "$iso_path" ]]; then
        ok "Ubuntu cloud image exists: $iso_path"
        # Upload it to storage first if not already there
        if pvesh create /nodes/$SELECTED/storage/local/content --content iso --filename "$iso_name" --file "$iso_path" &>/dev/null; then
            ok "Uploaded to storage"
            rm -f "$iso_path"
            ISO="local:iso/$iso_name"
        else
            warn "Upload failed, using local file as cdrom"
            ISO="$iso_path"
        fi
        return
    fi

    log "Downloading Ubuntu $UBUNTU_VER cloud image..."
    curl -sL -o "$iso_path" "$CLOUD_IMG" && ok "Downloaded" || { err "Download failed"; exit 1; }

    # Upload to Proxmox storage
    log "Uploading to Proxmox storage..."
    if pvesh create /nodes/$SELECTED/storage/local/content --content iso --filename "$iso_name" --file "$iso_path" &>/dev/null; then
        ok "Uploaded to storage"
        rm -f "$iso_path"
        ISO="local:iso/$iso_name"
    else
        warn "Upload failed, using local file"
        ISO="$iso_path"
    fi
}

create_cloudinit() {
    local out="/tmp/cloud-init-$CLUSTER.yml"
    local creds_file="/tmp/twinbox-creds-$CLUSTER.env"
    [[ -f "$creds_file" ]] || { err "Credentials file not found. Run gen_token first."; exit 1; }
    source "$creds_file"

    local db_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32 2>/dev/null || echo "CHANGE_$(date +%s)")
    local sec_key=$(openssl rand -base64 32 2>/dev/null || echo "CHANGE_$(date +%s)")

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

write_files:
  - path: /etc/systemd/system/twinbox.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Twinbox Management Console
      Requires=docker.service
      After=docker.service
      Wants=docker.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/bin/docker-compose -f /opt/twinbox/docker-compose.yml up -d
      ExecStop=/usr/bin/docker-compose -f /opt/twinbox/docker-compose.yml down
      User=twinbox
      Group=twinbox
      WorkingDirectory=/opt/twinbox
      Restart=on-failure
      RestartSec=10

      [Install]
      WantedBy=multi-user.target

  - path: /etc/motd
    permissions: '0644'
    owner: root:root
    content: |
      ==========================================
       Twinbox Management VM
      ==========================================

      Web UI: http://<this-vm-ip>:8080
      SSH: ubuntu@<this-vm-ip>

      Twinbox repository: /opt/twinbox
      Docker Compose: /opt/twinbox/docker-compose.yml

      Status: systemctl status twinbox
      Logs: journalctl -u twinbox -f

      ==========================================

runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, twinbox.service]
  - [systemctl, start, twinbox.service]
  - [systemctl, enable, docker]
  - [systemctl, start, docker]

final_message: |
  ==========================================
   Twinbox Setup Complete!
  ==========================================

  Management VM is ready. The Twinbox web
  interface should be accessible shortly.

  SSH to this VM: ssh ubuntu@<this-ip>
  View status: systemctl status twinbox
  View logs: journalctl -u twinbox -f

  ==========================================
EOF
    ok "Cloud-init generated: $out"
    echo "$out"
}

create_vm() {
    local name
    name="twinbox-mgmt-${CLUSTER}"

    log "Discovering cluster-wide VM IDs to find a free one..."

    # Collect all VM IDs from all nodes in the cluster
    local used_vm_ids=()

    # Get VM/CT IDs from a specific node (both QEMU VMs and LXC containers)
    get_vmids_from_node() {
        local node="$1"
        # Get QEMU VMs
        pvesh get /nodes/$node/qemu --output-format json 2>/dev/null | \
        python3 -c "import sys, json; [print(vm['vmid']) for vm in json.load(sys.stdin) if 'vmid' in vm]" 2>/dev/null
        # Get LXC containers
        pvesh get /nodes/$node/lxc --output-format json 2>/dev/null | \
        python3 -c "import sys, json; [print(ct['vmid']) for ct in json.load(sys.stdin) if 'vmid' in ct]" 2>/dev/null
    }

    # Get all node names in cluster
    get_all_nodes() {
        pvesh get /nodes --output-format json 2>/dev/null | \
        python3 -c "import sys, json; [print(item['node']) for item in json.load(sys.stdin) if 'node' in item]" 2>/dev/null
    }

    # Always check the SELECTED node first
    if [[ -n "$SELECTED" ]]; then
        while IFS= read -r vmid; do
            [[ -n "$vmid" ]] && used_vm_ids+=("$vmid")
        done < <(get_vmids_from_node "$SELECTED")
    fi

    # Check all other nodes in the cluster
    while IFS= read -r node; do
        [[ "$node" == "$SELECTED" ]] && continue
        while IFS= read -r vmid; do
            [[ -n "$vmid" ]] && used_vm_ids+=("$vmid")
        done < <(get_vmids_from_node "$node")
    done < <(get_all_nodes)

    # Deduplicate and sort
    if [[ ${#used_vm_ids[@]} -gt 0 ]]; then
        used_vm_ids=($(printf '%s\n' "${used_vm_ids[@]}" | sort -n | uniq))
    fi

    log "Used VM IDs found: ${used_vm_ids[*]:-none}"

    # Find first free VM ID starting from 100
    local vmid=""
    local start_vmid=100
    for ((candidate=start_vmid; candidate<start_vmid+1000; candidate++)); do
        if ! printf '%s\n' "${used_vm_ids[@]}" | grep -qx "$candidate"; then
            vmid="$candidate"
            break
        fi
    done

    if [[ -z "$vmid" ]]; then
        err "No free VM ID found in range 100-1099"
        return 1
    fi

    log "Using VM ID $vmid (free)"
    log "Attempting to create VM $vmid: $name"

    # Suppress all qm create output to ensure clean vmid return
    if ! qm create "$vmid" --name "$name" --memory "$RAM_MB" --cores "$CPU_CORES" \
        --net0 "virtio,bridge=$BRIDGE" \
        --scsi0 "$STORAGE:${DISK_GB},ssd=1" \
        --cdrom "$ISO" \
        --boot "order=ide2" &>/dev/null; then
        err "Failed to create VM $vmid"
        return 1
    fi

    ok "VM $vmid created"

    local ci_file
    ci_file=$(create_cloudinit) || return 1

    # Attach cloud-init config directly using local file path
    qm set "$vmid" --cicustom "user=local:$ci_file" \
        --ipconfig0 "ip=dhcp" &>/dev/null

    echo "$vmid"
    return 0
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
    check_proxmox; prompt_cluster
    log "Configuration:"; echo "  Cluster: $CLUSTER"; echo "  Node: $SELECTED"
    echo "  VM: ${CPU_CORES} CPU, ${RAM_MB}MB RAM, ${DISK_GB}GB disk"; echo "  Bridge: $BRIDGE"
    create_twinbox_user; gen_token; get_ubuntu_iso
    local vmid
    vmid=$(create_vm) || exit 1
    qm start "$vmid"
    local ip
    ip=$(wait_ip "$vmid")
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
