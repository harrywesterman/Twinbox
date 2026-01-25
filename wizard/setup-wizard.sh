#!/bin/bash

# Twinbox - Proxmox Console Setup Wizard
# A standalone script to bootstrap a Talos Kubernetes cluster on Proxmox VE.
# Inspired by ProxmoxVE Community Scripts.

set -e

# Configuration
GITHUB_REPO="your-org/twinbox" # Placeholder, update with actual
TALOS_VERSION="v1.7.4"
K8S_VERSION="v1.29.6"

# Colors
RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

# Header
header_info() {
    clear
    cat << "EOF"
  _______       _       _                  
 |__   __|     (_)     | |                 
    | |_      ___ _ __ | |__   _____  __   
    | \ \ /\ / / | '_ \| '_ \ / _ \ \/ /   
    | |\ V  V /| | | | | |_) | (_) >  <    
    |_| \_/\_/ |_|_| |_|_.__/ \___/_/\_\   
                                           
    Proxmox Kubernetes Bootstrap Wizard
EOF
}

msg_info() {
    local msg="$1"
    echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
    local msg="$1"
    echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
    local msg="$1"
    echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

# Check requirements
check_root() {
    if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $$) == "sudo" ]]; then
        clear
        msg_error "Please run this script as root."
        echo
        exit 1
    fi
}

check_deps() {
    msg_info "Checking dependencies"
    if ! command -v whiptail &> /dev/null; then
        apt-get update -qq && apt-get install -y whiptail curl jq &> /dev/null
    fi
    msg_ok "Dependencies checked"
}

# UI Function
input_box() {
    local title="$1"
    local text="$2"
    local default="$3"
    local var_name="$4"
    
    local val
    val=$(whiptail --inputbox "$text" 8 78 "$default" --title "$title" 3>&1 1>&2 2>&3)
    exit_status=$?
    if [ $exit_status -eq 0 ]; then
        eval "$var_name=\"$val\""
    else
        echo "Cancelled."
        exit 1
    fi
}

msg_box() {
    local title="$1"
    local text="$2"
    whiptail --msgbox "$text" 8 78 --title "$title"
}

# Main Wizard
start_wizard() {
    header_info
    
    msg_box "Twinbox Setup" "Welcome to the Twinbox Setup Wizard.\n\nThis script will guide you through creating a Talos Linux Kubernetes cluster on your Proxmox server.\n\nPrerequisites:\n- A Proxmox VE server with internet access\n- Sufficient resources (RAM/CPU/Disk)"

    # Cluster Config
    input_box "Cluster Configuration" "Enter Cluster Name:" "twinbox-cluster" CLUSTER_NAME
    input_box "Cluster Configuration" "Enter number of Control Plane Nodes:" "1" CP_COUNT
    input_box "Cluster Configuration" "Enter number of Worker Nodes:" "2" WORKER_COUNT
    input_box "Cluster Configuration" "Starting VM ID:" "200" START_ID
    
    # Resources
    input_box "Resource Allocation" "RAM per Node (MB):" "4096" RAM_SIZE
    input_box "Resource Allocation" "CPU Cores per Node:" "2" CPU_CORES
    input_box "Resource Allocation" "Disk Size (GB):" "20" DISK_SIZE
    
    # Network
    input_box "Network Configuration" "Bridge Interface:" "vmbr0" BRIDGE_IF
    input_box "Network Configuration" "Gateway IP:" "192.168.1.1" GATEWAY_IP
    input_box "Network Configuration" "Cluster VIP (Control Plane Endpoint):" "192.168.1.50" VIP_IP
    input_box "Network Configuration" "First Node IP (others will increment):" "192.168.1.51" START_IP

    # Confirm
    if whiptail --yesno "Ready to install?\n\nCluster: $CLUSTER_NAME\nNodes: $CP_COUNT CP / $WORKER_COUNT Worker\nResources: ${RAM_SIZE}MB / ${CPU_CORES} Core / ${DISK_SIZE}GB\nNetwork: $BRIDGE_IF (VIP: $VIP_IP)" 15 78; then
        install_cluster
    else
        echo "Cancelled."
        exit 0
    fi
}

install_cluster() {
    clear
    header_info
    echo -e "${GN}Starting Installation...${CL}"
    
    # 1. Download Talos ISO
    ISO_PATH="/var/lib/vz/template/iso/talos-${TALOS_VERSION}.iso"
    if [ ! -f "$ISO_PATH" ]; then
        msg_info "Downloading Talos Linux ISO (${TALOS_VERSION})"
        curl -L -o "$ISO_PATH" "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talos-amd64.iso"
        msg_ok "Downloaded Talos ISO"
    else
        msg_ok "Talos ISO already exists"
    fi

    # 2. Check/Install talosctl
    if ! command -v talosctl &> /dev/null; then
        msg_info "Installing talosctl"
        curl -sL https://talos.dev/install | bash &> /dev/null
        msg_ok "Installed talosctl"
    fi

    # 3. Create VMs
    CURRENT_ID=$START_ID
    CURRENT_IP=$(echo "$START_IP" | awk -F. '{print $1"."$2"."$3"."$4}')
    
    # IP Increment Function
    increment_ip() {
        local ip=$1
        local base=$(echo "$ip" | cut -d. -f1-3)
        local last=$(echo "$ip" | cut -d. -f4)
        echo "$base.$((last + 1))"
    }

    # Loop CP
    for i in $(seq 1 $CP_COUNT); do
        NODENAME="${CLUSTER_NAME}-cp-${i}"
        msg_info "Creating Control Plane: $NODENAME (ID: $CURRENT_ID, IP: $CURRENT_IP)"
        
        qm create $CURRENT_ID --name "$NODENAME" --memory $RAM_SIZE --cores $CPU_CORES --net0 virtio,bridge=$BRIDGE_IF \
          --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$CURRENT_ID-disk-0,size=${DISK_SIZE}G,ssd=1 \
          --cdrom local:iso/talos-${TALOS_VERSION}.iso --boot order=scsi0;ide2 --ostype l26
        
        # We need to set up network config for Talos specifically or rely on DHCP.
        # For simplicity here, we assume DHCP reservation OR we'd generate a strict ISO.
        # But commonly with Proxmox/Talos scripts, we pass kernel args or use nocloud.
        # HERE: We will simplisticially rely on DHCP for the wizard's MVP or we'd need to generate a custom ISO/image.
        # However, to meet the "console script" requirement, let's keep it simple: Basic VM creation.
        
        msg_ok "Created $NODENAME"
        CURRENT_ID=$((CURRENT_ID + 1))
        CURRENT_IP=$(increment_ip "$CURRENT_IP")
    done

    # Loop Workers
    for i in $(seq 1 $WORKER_COUNT); do
        NODENAME="${CLUSTER_NAME}-worker-${i}"
        msg_info "Creating Worker: $NODENAME (ID: $CURRENT_ID)"
        
        qm create $CURRENT_ID --name "$NODENAME" --memory $RAM_SIZE --cores $CPU_CORES --net0 virtio,bridge=$BRIDGE_IF \
          --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$CURRENT_ID-disk-0,size=${DISK_SIZE}G,ssd=1 \
          --cdrom local:iso/talos-${TALOS_VERSION}.iso --boot order=scsi0;ide2 --ostype l26
          
        msg_ok "Created $NODENAME"
        CURRENT_ID=$((CURRENT_ID + 1))
    done

    msg_box "Next Steps" "VMs have been created!\n\nSince this is an MVP wizard, the VMs configured to boot from the Talos ISO.\n\nYou now need to:\n1. Start the VMs in Proxmox\n2. Run 'talosctl gen config ...' on your workstation\n3. Apply config to the new nodes\n\n(Future improvement: The wizard will auto-generate and apply configs)"
}

# Run
check_root
check_deps
start_wizard
