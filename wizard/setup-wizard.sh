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

    # Management Node Config
    input_box "Management Node" "Install Management Node (Ubuntu)? (y/n)" "y" INSTALL_MGT
    if [ "$INSTALL_MGT" == "y" ]; then
        input_box "Management Node" "Management Node ID:" "100" MGT_ID
        input_box "Management Node" "Management Node RAM (MB):" "2048" MGT_RAM
        input_box "Management Node" "Management Node Cores:" "2" MGT_CORES
        # We need an SSH key for the management node
        input_box "Management Node" "Paste your SSH Public Key (starts with ssh-rsa ...):" "" SSH_KEY
    fi

    # Confirm
    if whiptail --yesno "Ready to install?\n\nCluster: $CLUSTER_NAME\nNodes: $CP_COUNT CP / $WORKER_COUNT Worker\nResources: ${RAM_SIZE}MB / ${CPU_CORES} Core / ${DISK_SIZE}GB\nNetwork: $BRIDGE_IF (VIP: $VIP_IP)\n\nManagement Node: $INSTALL_MGT (ID: $MGT_ID)" 15 78; then
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
    
    # 0. Setup Storage
    mkdir -p /var/lib/vz/template/iso
    mkdir -p /var/lib/vz/template/cache
    mkdir -p /var/lib/vz/snippets

    # 1. Download Talos ISO
    ISO_PATH="/var/lib/vz/template/iso/talos-${TALOS_VERSION}.iso"
    if [ ! -f "$ISO_PATH" ]; then
        msg_info "Downloading Talos Linux ISO (${TALOS_VERSION})"
        curl -L -o "$ISO_PATH" "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talos-amd64.iso"
        msg_ok "Downloaded Talos ISO"
    else
        msg_ok "Talos ISO already exists"
    fi

    # Initialize IP Arrays for Bootstrap Script
    CP_IPS=()
    WORKER_IPS=()
    CURRENT_ID=$START_ID
    # Helper to calculate IP
    get_ip() {
        local offset=$1
        local base=$(echo "$START_IP" | cut -d. -f1-3)
        local start_octet=$(echo "$START_IP" | cut -d. -f4)
        echo "$base.$((start_octet + offset))"
    }

    # 2. Create Talos VMs (First, to gather IPs for Management Node)
    
    # Loop CP
    for i in $(seq 1 $CP_COUNT); do
        NODENAME="${CLUSTER_NAME}-cp-${i}"
        NODE_IP=$(get_ip $((i - 1)))
        CP_IPS+=("$NODE_IP")
        
        msg_info "Creating Control Plane: $NODENAME (ID: $CURRENT_ID)"
        qm create $CURRENT_ID --name "$NODENAME" --memory $RAM_SIZE --cores $CPU_CORES --net0 virtio,bridge=$BRIDGE_IF \
          --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$CURRENT_ID-disk-0,size=${DISK_SIZE}G,ssd=1 \
          --cdrom local:iso/talos-${TALOS_VERSION}.iso --boot order=scsi0;ide2 --ostype l26
        
        msg_ok "Created $NODENAME"
        CURRENT_ID=$((CURRENT_ID + 1))
    done

    # Loop Workers
    for i in $(seq 1 $WORKER_COUNT); do
        NODENAME="${CLUSTER_NAME}-worker-${i}"
        NODE_IP=$(get_ip $((CP_COUNT + i - 1)))
        WORKER_IPS+=("$NODE_IP")

        msg_info "Creating Worker: $NODENAME (ID: $CURRENT_ID)"
        qm create $CURRENT_ID --name "$NODENAME" --memory $RAM_SIZE --cores $CPU_CORES --net0 virtio,bridge=$BRIDGE_IF \
          --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$CURRENT_ID-disk-0,size=${DISK_SIZE}G,ssd=1 \
          --cdrom local:iso/talos-${TALOS_VERSION}.iso --boot order=scsi0;ide2 --ostype l26
          
        msg_ok "Created $NODENAME"
        CURRENT_ID=$((CURRENT_ID + 1))
    done

    # 3. Management Node Provisioning
    if [ "$INSTALL_MGT" == "y" ]; then
        UBUNTU_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
        IMG_NAME="noble-server-cloudimg-amd64.img"
        IMG_PATH="/var/lib/vz/template/cache/$IMG_NAME"
        
        if [ ! -f "$IMG_PATH" ]; then
            msg_info "Downloading Ubuntu 24.04 Cloud Image"
            curl -L -o "$IMG_PATH" "$UBUNTU_URL"
            msg_ok "Downloaded Ubuntu Image"
        else
            msg_ok "Ubuntu Image already exists"
        fi

        msg_info "Creating Management Node (ID: $MGT_ID)"
        
        # Prepare IPs string for the script
        CP_IPS_STR="${CP_IPS[*]}"
        WORKER_IPS_STR="${WORKER_IPS[*]}"

        # Create Cloud-Init Snippet
        SNIPPET_FILE="/var/lib/vz/snippets/mgt-${MGT_ID}-user-data.yaml"
        cat <<EOF > "$SNIPPET_FILE"
#cloud-config
hostname: twinbox-mgt
manage_etc_hosts: true
users:
  - default
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $SSH_KEY
package_update: true
packages:
  - curl
  - wget
  - unzip
  - git
  - software-properties-common
write_files:
  - path: /home/ubuntu/bootstrap-cluster.sh
    permissions: '0755'
    owner: ubuntu:ubuntu
    content: |
      #!/bin/bash
      set -e
      CLUSTER_NAME="$CLUSTER_NAME"
      VIP_IP="$VIP_IP"
      CP_IPS=($CP_IPS_STR)
      WORKER_IPS=($WORKER_IPS_STR)
      
      echo "Bootstrapping \$CLUSTER_NAME..."
      
      # Generate Config
      talosctl gen config \$CLUSTER_NAME https://\${VIP_IP}:6443
      
      # Apply Config to Control Plane
      for ip in "\${CP_IPS[@]}"; do
        echo "Applying controlplane config to \$ip..."
        talosctl apply-config --insecure --nodes \$ip --file controlplane.yaml
      done
      
      # Apply Config to Workers
      for ip in "\${WORKER_IPS[@]}"; do
        echo "Applying worker config to \$ip..."
        talosctl apply-config --insecure --nodes \$ip --file worker.yaml
      done
      
      # Bootstrap
      echo "Bootstrapping etcd on \${CP_IPS[0]}..."
      talosctl bootstrap --nodes \${CP_IPS[0]} --endpoints \${CP_IPS[0]} --talosconfig talosconfig
      
      # Kubeconfig
      echo " retrieving kubeconfig..."
      talosctl kubeconfig --nodes \${CP_IPS[0]} --endpoints \${CP_IPS[0]} --talosconfig talosconfig
      
      echo "Cluster bootstrapped! verify with: kubectl get nodes"

runcmd:
  # Install Terraform
  - wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  - echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
  - apt-get update && apt-get install -y terraform
  # Install Ansible
  - apt-add-repository --yes --update ppa:ansible/ansible
  - apt-get install -y ansible
  # Install Kubectl
  - curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
  - install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  # Install Talosctl
  - curl -sL https://talos.dev/install | bash
  # Basic SSH Config
  - mkdir -p /home/ubuntu/.ssh
  - echo "Host *\n\tStrictHostKeyChecking no\n" > /home/ubuntu/.ssh/config
  - chown -R ubuntu:ubuntu /home/ubuntu/.ssh
EOF
        
        # Create VM
        qm create $MGT_ID --name "twinbox-mgt" --memory $MGT_RAM --cores $MGT_CORES --net0 virtio,bridge=$BRIDGE_IF
        qm importdisk $MGT_ID "$IMG_PATH" local-lvm
        qm set $MGT_ID --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$MGT_ID-disk-0
        qm set $MGT_ID --ide2 local-lvm:cloudinit
        qm set $MGT_ID --boot c --bootdisk scsi0
        qm set $MGT_ID --cicustom "user=local:snippets/$(basename $SNIPPET_FILE)"
        qm set $MGT_ID --ipconfig0 ip=dhcp
        qm resize $MGT_ID scsi0 +10G

        msg_ok "Created Management Node ($MGT_ID)"
    fi

    # 4. Auto-Start VMs
    msg_info "Starting VMs..."
    
    # Start MGT first
    if [ "$INSTALL_MGT" == "y" ]; then
        qm start $MGT_ID
        msg_ok "Started Management Node ($MGT_ID)"
    fi
    
    # Start Talos Nodes
    # Using the IDs we looped through. Recalculate IDs for simplicity or store them.
    # Re-loop to start
    ITER_ID=$START_ID
    for i in $(seq 1 $((CP_COUNT + WORKER_COUNT))); do
       qm start $ITER_ID
       msg_ok "Started Talos Node ($ITER_ID)"
       ITER_ID=$((ITER_ID + 1))
    done

    msg_box "Done" "Installation & Startup Complete!\n\n1. Wait a few minutes for Management VM to initialize.\n2. Login: ssh ubuntu@<MGT_IP>\n3. Run: ./bootstrap-cluster.sh\n\nYour cluster will be ready!"
}

# Run
check_root
check_deps
start_wizard
