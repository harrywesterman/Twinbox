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

check_virt_customize() {
    if ! command -v virt-customize &>/dev/null; then
        log "virt-customize (libguestfs-tools) is not installed."
        log "This tool can pre-install qemu-guest-agent into the cloud image for better reliability."
        read -p "Install libguestfs-tools now? (recommended) [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Installing libguestfs-tools..."
            if apt-get update &>/dev/null && apt-get install -y libguestfs-tools &>/dev/null; then
                ok "libguestfs-tools installed"
            else
                err "Failed to install libguestfs-tools. Will continue without it."
            fi
        else
            log "Skipping libguestfs-tools. qemu-guest-agent will be installed via cloud-init."
        fi
    fi
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

get_ubuntu_cloud_image() {
    local storage_dir="/var/lib/vz"
    local img_name="${UBUNTU_VER}-server-cloudimg-amd64.img"
    local img_path="$storage_dir/$img_name"

    mkdir -p "$storage_dir"

    # Download if not exists locally
    if [[ ! -f "$img_path" ]]; then
        log "Downloading Ubuntu $UBUNTU_VER cloud image..."
        curl -sL -o "$img_path" "$CLOUD_IMG" && ok "Downloaded" || { err "Download failed"; exit 1; }
    else
        ok "Ubuntu cloud image exists: $img_path"
    fi

    # If virt-customize is available, install qemu-guest-agent into the image
    if command -v virt-customize &>/dev/null; then
        log "Customizing cloud image: installing qemu-guest-agent..."
        if virt-customize -a "$img_path" --install qemu-guest-agent &>/dev/null; then
            ok "qemu-guest-agent installed in base image"
        else
            warn "virt-customize failed, will rely on cloud-init to install agent"
        fi
    else
        log "virt-customize not found (libguestfs-tools not installed). Will install qemu-guest-agent via cloud-init."
    fi

    # Upload to Proxmox storage if not already there
    if pvesh get /nodes/$SELECTED/storage/local/content --output-format json 2>/dev/null | \
        python3 -c "import sys, json; content = json.load(sys.stdin); print('yes' if any(item.get('volid','').endswith('$img_name') for item in content) else 'no')" 2>/dev/null | grep -q yes; then
        ok "Cloud image already in Proxmox storage"
    else
        log "Uploading to Proxmox storage..."
        if pvesh create /nodes/$SELECTED/storage/local/content --content iso --filename "$img_name" --file "$img_path" &>/dev/null; then
            ok "Uploaded to storage"
        else
            warn "Upload to storage failed, will use local file"
        fi
    fi

    # Store the path for importdisk (needs filesystem path, not storage ref)
    CLOUD_IMAGE_PATH="$img_path"
}

create_cloudinit_iso() {
    local base_dir="/tmp/cloud-init-$CLUSTER"
    local user_data="$base_dir/user-data"
    local meta_data="$base_dir/meta-data"
    local iso_tmp="/tmp/cloud-init-$CLUSTER.iso"
    local iso_name="cloud-init-$CLUSTER.iso"
    local storage_iso_path="/var/lib/vz/template/iso/$iso_name"
    local creds_file="/tmp/twinbox-creds-$CLUSTER.env"
    [[ -f "$creds_file" ]] || { err "Credentials file not found. Run gen_token first."; exit 1; }
    source "$creds_file"

    local db_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32 2>/dev/null || echo "CHANGE_$(date +%s)")
    local sec_key=$(openssl rand -base64 32 2>/dev/null || echo "CHANGE_$(date +%s)")

    mkdir -p "$base_dir"

    # Create user-data (cloud-config)
    cat > "$user_data" <<EOF_USERDATA
#cloud-config
package_update: true
package_upgrade: true
packages: [docker.io, docker-compose, jq, yq, curl, git, python3-pip, python3-yaml, qemu-guest-agent]
runcmd:
  - [groupadd, -g, 999, twinbox]
  - [useradd, -u, 999, -g, twinbox, -m, -s, /bin/bash, twinbox]
  - [usermod, -aG, docker, twinbox]
  - [mkdir, -p, /opt/twinbox]
  - [chown, -R, twinbox:twinbox, /opt/twinbox]
  - [systemctl, enable, qemu-guest-agent]
  - [systemctl, start, qemu-guest-agent]
write_files:
  - path: /opt/twinbox/config/proxmox-creds.yaml
    permissions: '0600'
    owner: twinbox:twinbox
    content: |
      api_url: ${API_URL}
      user: "twinbox@pve"
      token: ${API_TOKEN_SECRET}
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
      SSH: ubuntu@<this-ip>

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
  ===========================================

  Management VM is ready. The Twinbox web
  interface should be accessible shortly.

  SSH to this vm: ssh ubuntu@<this-ip>
  View status: systemctl status twinbox
  View logs: journalctl -u twinbox -f

  ==========================================
EOF_USERDATA

    # Create meta-data (substitute actual VM ID and cluster name)
    cat > "$meta_data" <<EOF_METADATA
instance-id: cloud-vm-$vmid
local-hostname: twinbox-mgmt-$CLUSTER
EOF_METADATA

    # Create cloud-init ISO using cloud-localds (preferred) or mkisofs (fallback)
    if command -v cloud-localds &>/dev/null; then
        cloud-localds --disk-format raw "$iso_tmp" "$user_data" "$meta_data"
    else
        warn "cloud-localds not found, using mkisofs..."
        mkisofs -o "$iso_tmp" -volid cidata -joliet -rock "$user_data" "$meta_data" 2>/dev/null || {
            err "Failed to create cloud-init ISO. Install cloud-image-utils package."
            return 1
        }
    fi

    ok "Cloud-init ISO created"

    # Copy ISO to Proxmox template directory so it's accessible via storage
    mkdir -p /var/lib/vz/template/iso
    cp "$iso_tmp" "$storage_iso_path" 2>/dev/null || true

    echo "$iso_name"
}


create_cloudinit_snippet() {
    local snippet_dir="/var/lib/vz/snippets"
    local snippet_file="twinbox-$CLUSTER-user.yaml"
    local snippet_path="$snippet_dir/$snippet_file"
    local creds_file="/tmp/twinbox-creds-$CLUSTER.env"
    [[ -f "$creds_file" ]] || { err "Credentials file not found. Run gen_token first."; exit 1; }
    source "$creds_file"

    local db_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32 2>/dev/null || echo "CHANGE_$(date +%s)")
    local sec_key=$(openssl rand -base64 32 2>/dev/null || echo "CHANGE_$(date +%s)")

    mkdir -p "$snippet_dir"

    cat > "$snippet_path" <<'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages: [docker.io, docker-compose, jq, yq, curl, git, python3-pip, python3-yaml, qemu-guest-agent]
runcmd:
  - [groupadd, -g, 999, twinbox]
  - [useradd, -u, 999, -g, twinbox, -m, -s, /bin/bash, twinbox]
  - [usermod, -aG, docker, twinbox]
  - [mkdir, -p, /opt/twinbox]
  - [chown, -R, twinbox:twinbox, /opt/twinbox]
  - [systemctl, enable, qemu-guest-agent]
  - [systemctl, start, qemu-guest-agent]
write_files:
  - path: /opt/twinbox/config/proxmox-creds.yaml
    permissions: '0600'
    owner: twinbox:twinbox
    content: |
      api_url: ${API_URL}
      user: "twinbox@pve"
      token: ${API_TOKEN_SECRET}
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
      SSH: ubuntu@<this-ip>

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
  ===========================================

  Management VM is ready. The Twinbox web
  interface should be accessible shortly.

  SSH to this VM: ssh ubuntu@<this-ip>
  View status: systemctl status twinbox
  View logs: journalctl -u twinbox -f

  ==========================================
EOF

    ok "Cloud-init snippet created: $snippet_path"
    echo "$snippet_file"
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
        # Collect all IDs from this node into a temporary array to avoid nested process substitution issues
        local node_ids=()
        while IFS= read -r vmid; do
            [[ -n "$vmid" ]] && node_ids+=("$vmid")
        done < <(get_vmids_from_node "$node")
        # Append to global list
        used_vm_ids+=("${node_ids[@]}")
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

    # Ensure cloud image is available
    get_ubuntu_cloud_image || return 1

    # Step 1: Create empty VM (no disk)
    if ! qm create "$vmid" --name "$name" --memory "$RAM_MB" --cores "$CPU_CORES" \
        --net0 "virtio,bridge=$BRIDGE" \
        --agent 1 \
        --scsihw virtio-scsi-single \
        --onboot 1 \
        &>/dev/null; then
        err "Failed to create VM $vmid"
        return 1
    fi
    ok "VM $vmid created (empty)"

    # Step 2: Import cloud image as the boot disk
    log "Importing cloud image as disk..."
    if ! qm importdisk "$vmid" "$CLOUD_IMAGE_PATH" "$STORAGE" &>/dev/null; then
        err "Failed to import disk for VM $vmid"
        qm destroy "$vmid" 2>/dev/null || true
        return 1
    fi

    # Step 3: Attach the imported disk as scsi0
    # The disk will be named vm-<vmid>-disk-0
    local disk_name="vm-${vmid}-disk-0"
    if ! qm set "$vmid" --scsi0 "$STORAGE:$disk_name" &>/dev/null; then
        err "Failed to attach disk to VM $vmid"
        qm destroy "$vmid" 2>/dev/null || true
        return 1
    fi
    ok "Disk attached"

    # Step 4: Configure managed Cloud-Init drive
    local ci_snippet
    ci_snippet=$(create_cloudinit_snippet) || return 1

    # Attach cloud-init ISO as CD-ROM (ide2) and configure cloud-init drive
    qm set "$vmid" \
        --ide2 "local-lvm:cloudinit" \
        --cicustom "user=local:snippets/$ci_snippet" \
        --ipconfig0 "ip=dhcp" \
        --serial0 socket \
        &>/dev/null || warn "Cloud-init configuration may have issues"

    # Set boot order: boot from disk (scsi0), cloud-init will be picked up automatically
    qm set "$vmid" --boot "order=scsi0" &>/dev/null

    ok "Cloud-init configured"

    echo "$vmid"
    return 0
}

wait_ip() {
    local vmid="$1" wait=600 interval=2
    log "Waiting for VM IP address..."
    while (( wait > 0 )); do
        if qm status "$vmid" 2>/dev/null | grep -q running; then
            # Use guest agent's network-get-interfaces for reliable IP detection
            local ip
            ip=$(qm guest network-get-interfaces "$vmid" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data:
        for addr in iface.get('ip-addresses', []):
            if addr.get('ip-address-type') == 'ipv4':
                print(addr['ip-address'])
                sys.exit(0)
except: pass
" 2>/dev/null)
            if [[ -n "$ip" ]]; then
                ok "IP: $ip"
                echo "$ip"
                return 0
            fi
        fi
        sleep "$interval"; wait=$((wait-interval))
        printf " \r%3ds remaining" "$wait"
    done
    echo ""; read -p "Enter IP manually: " manual_ip; echo "$manual_ip"
}

main() {
    clear; echo "=== Twinbox Setup Wizard ==="
    check_proxmox; check_virt_customize; prompt_cluster
    log "Configuration:"; echo "  Cluster: $CLUSTER"; echo "  Node: $SELECTED"
    echo "  VM: ${CPU_CORES} CPU, ${RAM_MB}MB RAM, ${DISK_GB}GB disk"; echo "  Bridge: $BRIDGE"
    create_twinbox_user; gen_token; get_ubuntu_cloud_image
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
