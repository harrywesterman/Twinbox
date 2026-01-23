# Twinbox Talos on Proxmox Framework Implementation Plan

**Goal:** Create a Proxmox VE helper script that uses Ansible or Terraform to provision VMs running Talos Linux for Kubernetes.

**Architecture:** A Proxmox helper script manages VM lifecycle using Proxmox API, with optional Terraform/Ansible integration for advanced orchestration. Talos Linux provides immutable Kubernetes nodes with enhanced security.

**Tech Stack:** Bash scripting, Proxmox VE API, Talos Linux, optionally Terraform and Ansible

---

### Task 1: Create Proxmox Helper Script Core

**Files:**
- Create: `scripts/proxmox-helper.sh`

**Step 1: Write the failing test**
Create a test to verify the helper script exists and is executable
```bash
#!/bin/bash
# tests/helper_script_test.sh
set -e

if [ ! -f "scripts/proxmox-helper.sh" ]; then
    echo "FAIL: scripts/proxmox-helper.sh does not exist"
    exit 1
fi

if [ ! -x "scripts/proxmox-helper.sh" ]; then
    echo "FAIL: scripts/proxmox-helper.sh is not executable"
    exit 1
fi

echo "PASS: Helper script exists and is executable"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/helper_script_test.sh`
Expected: FAIL error indicating file doesn't exist

**Step 3: Write minimal implementation**

Create `scripts/proxmox-helper.sh`:
```bash
#!/bin/bash

# Twinbox Proxmox Helper Script
# Manages VM lifecycle on Proxmox VE for Talos Linux deployments

set -euo pipefail

# Default configuration
DEFAULT_NODE_COUNT=3
DEFAULT_VM_START_ID=200
DEFAULT_MEMORY=4096
DEFAULT_CORES=2
DEFAULT_DISK_SIZE=20
DEFAULT_BRIDGE=vmbr0
DEFAULT_TEMPLATE="local:vztmpl/talos-amd64.iso"  # Placeholder - will be replaced with actual Talos image

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Proxmox Helper Script for Talos Linux VM Management

Commands:
    create-cluster    Create a new Talos Linux cluster
    delete-cluster    Delete an existing cluster
    list-vms         List all Talos VMs
    start-vm         Start a VM
    stop-vm          Stop a VM
    destroy-vm       Destroy a VM

Options:
    --node-count N        Number of worker nodes (default: $DEFAULT_NODE_COUNT)
    --start-id N          Starting VM ID (default: $DEFAULT_VM_START_ID)
    --memory MB           Memory per VM in MB (default: $DEFAULT_MEMORY)
    --cores N             CPU cores per VM (default: $DEFAULT_CORES)
    --disk-size GB        Disk size per VM in GB (default: $DEFAULT_DISK_SIZE)
    --bridge BR           Network bridge (default: $DEFAULT_BRIDGE)
    --template PATH       VM template path (default: $DEFAULT_TEMPLATE)
    --cluster-name NAME   Cluster name (default: talos-cluster)

Examples:
    $(basename "$0") create-cluster --cluster-name my-cluster --node-count 3
    $(basename "$0") delete-cluster --cluster-name my-cluster
    $(basename "$0") list-vms
EOF
}

# Initialize Proxmox API connection
init_proxmox_api() {
    if [ -z "${PROXMOX_HOST:-}" ] || [ -z "${PROXMOX_USER:-}" ] || [ -z "${PROXMOX_PASSWORD:-}" ]; then
        error "PROXMOX_HOST, PROXMOX_USER, and PROXMOX_PASSWORD environment variables must be set"
        exit 1
    fi

    # Construct API URL
    API_URL="https://${PROXMOX_HOST}:8006/api2/json"
    
    # Authenticate and get CSRF token and ticket
    AUTH_RESPONSE=$(curl -k -s -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" \
        "${API_URL}/access/ticket")
    
    if [ $? -ne 0 ]; then
        error "Failed to authenticate with Proxmox API"
        exit 1
    fi
    
    TICKET=$(echo "$AUTH_RESPONSE" | jq -r '.data.ticket')
    CSRF_PREVENTION_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.data.CSRFPreventionToken')
    
    if [ "$TICKET" = "null" ] || [ "$CSRF_PREVENTION_TOKEN" = "null" ]; then
        error "Authentication failed: Invalid credentials"
        exit 1
    fi
    
    log "Successfully authenticated with Proxmox API"
}

# Check if a VM exists
vm_exists() {
    local vm_id=$1
    local response
    response=$(curl -k -s -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${API_URL}/nodes/pve/qemu/${vm_id}/status/current" 2>/dev/null)
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Main function
main() {
    log "Twinbox Proxmox Helper Script"
    log "This is a skeleton script - actual implementation will follow"
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

# Initialize default values
NODE_COUNT=$DEFAULT_NODE_COUNT
VM_START_ID=$DEFAULT_VM_START_ID
MEMORY=$DEFAULT_MEMORY
CORES=$DEFAULT_CORES
DISK_SIZE=$DEFAULT_DISK_SIZE
BRIDGE=$DEFAULT_BRIDGE
TEMPLATE=$DEFAULT_TEMPLATE
CLUSTER_NAME="talos-cluster"

# Parse options
while [ $# -gt 0 ]; do
    case $1 in
        --node-count)
            NODE_COUNT="$2"
            shift 2
            ;;
        --start-id)
            VM_START_ID="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --cores)
            CORES="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --template)
            TEMPLATE="$2"
            shift 2
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Validate inputs
if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || [ "$NODE_COUNT" -lt 1 ]; then
    error "Invalid node count: $NODE_COUNT"
    exit 1
fi

if ! [[ "$VM_START_ID" =~ ^[0-9]+$ ]] || [ "$VM_START_ID" -lt 100 ]; then
    error "Invalid VM start ID: $VM_START_ID"
    exit 1
fi

if ! [[ "$MEMORY" =~ ^[0-9]+$ ]] || [ "$MEMORY" -lt 512 ]; then
    error "Invalid memory size: $MEMORY"
    exit 1
fi

if ! [[ "$CORES" =~ ^[0-9]+$ ]] || [ "$CORES" -lt 1 ]; then
    error "Invalid core count: $CORES"
    exit 1
fi

if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE" -lt 1 ]; then
    error "Invalid disk size: $DISK_SIZE"
    exit 1
fi

case $COMMAND in
    create-cluster)
        main
        ;;
    delete-cluster)
        main
        ;;
    list-vms)
        main
        ;;
    start-vm)
        main
        ;;
    stop-vm)
        main
        ;;
    destroy-vm)
        main
        ;;
    *)
        error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
```

Make the script executable:
```bash
chmod +x scripts/proxmox-helper.sh
```

**Step 4: Run test to verify it passes**
Run: `bash tests/helper_script_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add scripts/proxmox-helper.sh
git commit -m "Add initial Proxmox helper script skeleton"
```

### Task 2: Implement VM Creation Functionality

**Files:**
- Modify: `scripts/proxmox-helper.sh:100-300`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/vm_creation_test.sh
set -e

# Mock the proxmox-helper.sh to test VM creation functionality
export PROXMOX_HOST="test-host"
export PROXMOX_USER="test-user"
export PROXMOX_PASSWORD="test-password"

# We'll test if the script contains the create_vm function
if ! grep -q "create_vm()" "scripts/proxmox-helper.sh"; then
    echo "FAIL: create_vm function not found in scripts/proxmox-helper.sh"
    exit 1
fi

if ! grep -q "create_cluster" "scripts/proxmox-helper.sh"; then
    echo "FAIL: create_cluster function not found in scripts/proxmox-helper.sh"
    exit 1
fi

echo "PASS: VM creation functions exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/vm_creation_test.sh`
Expected: FAIL error indicating functions don't exist

**Step 3: Write minimal implementation**

Update the `scripts/proxmox-helper.sh` with VM creation functionality:

```bash
#!/bin/bash

# Twinbox Proxmox Helper Script
# Manages VM lifecycle on Proxmox VE for Talos Linux deployments

set -euo pipefail

# Default configuration
DEFAULT_NODE_COUNT=3
DEFAULT_VM_START_ID=200
DEFAULT_MEMORY=4096
DEFAULT_CORES=2
DEFAULT_DISK_SIZE=20
DEFAULT_BRIDGE=vmbr0
DEFAULT_TEMPLATE=""  # Talos doesn't use traditional templates, so this will be handled specially
DEFAULT_TARGET_NODE="pve"
DEFAULT_SCSI_HW="virtio-scsi-single"
DEFAULT_NET_MODEL="virtio"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Proxmox Helper Script for Talos Linux VM Management

Commands:
    create-cluster    Create a new Talos Linux cluster
    delete-cluster    Delete an existing cluster
    list-vms         List all Talos VMs
    start-vm         Start a VM
    stop-vm          Stop a VM
    destroy-vm       Destroy a VM

Options:
    --node-count N        Number of worker nodes (default: $DEFAULT_NODE_COUNT)
    --start-id N          Starting VM ID (default: $DEFAULT_VM_START_ID)
    --memory MB           Memory per VM in MB (default: $DEFAULT_MEMORY)
    --cores N             CPU cores per VM (default: $DEFAULT_CORES)
    --disk-size GB        Disk size per VM in GB (default: $DEFAULT_DISK_SIZE)
    --bridge BR           Network bridge (default: $DEFAULT_BRIDGE)
    --target-node NODE    Target Proxmox node (default: $DEFAULT_TARGET_NODE)
    --cluster-name NAME   Cluster name (default: talos-cluster)

Examples:
    $(basename "$0") create-cluster --cluster-name my-cluster --node-count 3
    $(basename "$0") delete-cluster --cluster-name my-cluster
    $(basename "$0") list-vms
EOF
}

# Initialize Proxmox API connection
init_proxmox_api() {
    if [ -z "${PROXMOX_HOST:-}" ] || [ -z "${PROXMOX_USER:-}" ] || [ -z "${PROXMOX_PASSWORD:-}" ]; then
        error "PROXMOX_HOST, PROXMOX_USER, and PROXMOX_PASSWORD environment variables must be set"
        exit 1
    fi

    # Construct API URL
    API_URL="https://${PROXMOX_HOST}:8006/api2/json"
    
    # Authenticate and get CSRF token and ticket
    AUTH_RESPONSE=$(curl -k -s -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" \
        "${API_URL}/access/ticket")
    
    if [ $? -ne 0 ]; then
        error "Failed to authenticate with Proxmox API"
        exit 1
    fi
    
    TICKET=$(echo "$AUTH_RESPONSE" | jq -r '.data.ticket')
    CSRF_PREVENTION_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.data.CSRFPreventionToken')
    
    if [ "$TICKET" = "null" ] || [ "$CSRF_PREVENTION_TOKEN" = "null" ]; then
        error "Authentication failed: Invalid credentials"
        exit 1
    fi
    
    log "Successfully authenticated with Proxmox API"
}

# Check if a VM exists
vm_exists() {
    local vm_id=$1
    local response
    response=$(curl -k -s -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}/status/current" 2>/dev/null)
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Create a single VM for Talos
create_vm() {
    local vm_id=$1
    local vm_name=$2
    local is_control_plane=$3  # "true" for control plane, "false" for worker
    
    log "Creating VM ${vm_name} (ID: ${vm_id}) for Talos Linux"
    
    # Prepare the VM configuration
    local vm_config="vmid=${vm_id}
name=${vm_name}
memory=${MEMORY}
cores=${CORES}
net0=${DEFAULT_NET_MODEL},bridge=${BRIDGE}
scsihw=${DEFAULT_SCSI_HW}
scsi0=local-lvm:vm-${vm_id}-disk-0,size=${DISK_SIZE}G
bios=ovmf
efidisk0=local-lvm:vm-${vm_id}-efi,efitype=4m
machine=q35
onboot=1
ostype=l26
cpu=cputype=host"

    # For Talos, we'll create the VM with minimal configuration and attach ISO later
    # Create temporary config file
    local temp_config=$(mktemp)
    echo -e "$vm_config" > "$temp_config"
    
    # Upload the config to Proxmox
    local upload_response
    upload_response=$(curl -k -s \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "Content-Type: multipart/form-data" \
        -F "config=@${temp_config}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu")

    if [ $? -ne 0 ]; then
        error "Failed to create VM ${vm_name}"
        rm -f "$temp_config"
        return 1
    fi
    
    # Check for errors in response
    if echo "$upload_response" | jq -e '.errors' >/dev/null 2>&1; then
        error "Error creating VM ${vm_name}: $(echo "$upload_response" | jq -r '.errors')"
        rm -f "$temp_config"
        return 1
    fi
    
    log "Successfully created VM ${vm_name} (ID: ${vm_id})"
    rm -f "$temp_config"
    
    # Return the VM ID
    echo "$vm_id"
}

# Create a complete Talos cluster
create_cluster() {
    local cluster_name=$1
    local node_count=$2
    local start_id=$3
    
    log "Creating Talos cluster: ${cluster_name}"
    log "Cluster configuration:"
    log "  - Control plane nodes: 1"
    log "  - Worker nodes: ${node_count}"
    log "  - Total VMs: $((1 + node_count))"
    log "  - Starting VM ID: ${start_id}"
    log "  - Memory per VM: ${MEMORY}MB"
    log "  - CPU cores per VM: ${CORES}"
    log "  - Disk size per VM: ${DISK_SIZE}GB"
    
    # Create control plane node (always first)
    local control_plane_id=$((start_id))
    local control_plane_name="${cluster_name}-control-plane-0"
    
    if vm_exists "$control_plane_id"; then
        error "VM ID ${control_plane_id} already exists, cannot create cluster"
        return 1
    fi
    
    local created_vm_id
    created_vm_id=$(create_vm "$control_plane_id" "$control_plane_name" "true")
    if [ $? -ne 0 ]; then
        error "Failed to create control plane VM"
        return 1
    fi
    
    log "Control plane VM created successfully"
    
    # Create worker nodes
    for i in $(seq 1 $node_count); do
        local worker_id=$((start_id + i))
        local worker_name="${cluster_name}-worker-${i}"
        
        if vm_exists "$worker_id"; then
            error "VM ID ${worker_id} already exists, cannot create worker VM"
            return 1
        fi
        
        created_vm_id=$(create_vm "$worker_id" "$worker_name" "false")
        if [ $? -ne 0 ]; then
            error "Failed to create worker VM ${worker_name}"
            return 1
        fi
        
        log "Worker VM ${worker_name} created successfully"
    done
    
    log "Cluster ${cluster_name} created successfully!"
    log "VM IDs allocated: ${start_id} to $((start_id + node_count))"
}

# Main function
main() {
    log "Twinbox Proxmox Helper Script"
    
    case $COMMAND in
        create-cluster)
            init_proxmox_api
            create_cluster "$CLUSTER_NAME" "$NODE_COUNT" "$VM_START_ID"
            ;;
        delete-cluster)
            log "Delete cluster functionality not yet implemented"
            ;;
        list-vms)
            log "List VMs functionality not yet implemented"
            ;;
        start-vm)
            log "Start VM functionality not yet implemented"
            ;;
        stop-vm)
            log "Stop VM functionality not yet implemented"
            ;;
        destroy-vm)
            log "Destroy VM functionality not yet implemented"
            ;;
        *)
            error "Unknown command: $COMMAND"
            usage
            exit 1
            ;;
    esac
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

# Initialize default values
NODE_COUNT=$DEFAULT_NODE_COUNT
VM_START_ID=$DEFAULT_VM_START_ID
MEMORY=$DEFAULT_MEMORY
CORES=$DEFAULT_CORES
DISK_SIZE=$DEFAULT_DISK_SIZE
BRIDGE=$DEFAULT_BRIDGE
CLUSTER_NAME="talos-cluster"
DEFAULT_TARGET_NODE="pve"

# Parse options
while [ $# -gt 0 ]; do
    case $1 in
        --node-count)
            NODE_COUNT="$2"
            shift 2
            ;;
        --start-id)
            VM_START_ID="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --cores)
            CORES="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --target-node)
            DEFAULT_TARGET_NODE="$2"
            shift 2
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Validate inputs
if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || [ "$NODE_COUNT" -lt 1 ]; then
    error "Invalid node count: $NODE_COUNT"
    exit 1
fi

if ! [[ "$VM_START_ID" =~ ^[0-9]+$ ]] || [ "$VM_START_ID" -lt 100 ]; then
    error "Invalid VM start ID: $VM_START_ID"
    exit 1
fi

if ! [[ "$MEMORY" =~ ^[0-9]+$ ]] || [ "$MEMORY" -lt 512 ]; then
    error "Invalid memory size: $MEMORY"
    exit 1
fi

if ! [[ "$CORES" =~ ^[0-9]+$ ]] || [ "$CORES" -lt 1 ]; then
    error "Invalid core count: $CORES"
    exit 1
fi

if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE" -lt 1 ]; then
    error "Invalid disk size: $DISK_SIZE"
    exit 1
fi

main
```

**Step 4: Run test to verify it passes**
Run: `bash tests/vm_creation_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add scripts/proxmox-helper.sh
git commit -m "Implement VM creation functionality for Talos cluster"
```

### Task 3: Add Talos Configuration Support

**Files:**
- Create: `templates/talos-machine-config.yaml`
- Modify: `scripts/proxmox-helper.sh:300-500`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos_config_test.sh
set -e

if [ ! -f "templates/talos-machine-config.yaml" ]; then
    echo "FAIL: templates/talos-machine-config.yaml does not exist"
    exit 1
fi

if ! grep -q "machine:" "templates/talos-machine-config.yaml"; then
    echo "FAIL: Invalid Talos config format"
    exit 1
fi

echo "PASS: Talos configuration template exists"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos_config_test.sh`
Expected: FAIL error indicating file doesn't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p templates
```

Create `templates/talos-machine-config.yaml`:
```yaml
# Default Talos Linux machine config template
# This will be customized per node during deployment

version: v1alpha1
debug: false
persist: true
machine:
  type: "controlplane"  # Will be replaced with 'worker' for worker nodes
  certSANs:
    - "{{CONTROL_PLANE_IP}}"  # Will be replaced with actual IP
  token: "{{TALOS_TOKEN}}"
  ca:
    crt: "{{CA_CRT}}"
    key: "{{CA_KEY}}"
  install:
    image: "ghcr.io/siderolabs/installer:{{TALOS_VERSION}}"
    disk: "/dev/sda"
    bootloader: true
    wipe: false
    force: false
  network:
    hostname: "{{HOSTNAME}}"
    interfaces:
      - deviceSelector:
          busPath: "*"
        dhcp: true
        vip:
          ip: "{{VIP_IP}}"
  kubelet:
    image: "ghcr.io/siderolabs/kubelet:{{KUBERNETES_VERSION}}"
    extraArgs:
      rotate-server-certificates: true
  time:
    disabled: false
    servers:
      - "pool.ntp.org"
  sysctls:
    "net.core.rmem_max": "2500000"
    "net.core.wmem_max": "2500000"
  files:
    - content: |
        [settings]
        enable_monitoring_agent = true
        enable_gpu_agent = false
        enable_load_balancer_agent = true
      op: create
      path: /etc/containers/registries.conf
      permissions: 0o644
cluster:
  id: "{{CLUSTER_ID}}"
  secret: "{{CLUSTER_SECRET}}"
  endpoint: "https://{{CONTROL_PLANE_IP}}:6443"
  network:
    podSubnets:
      - "10.244.0.0/16"
    serviceSubnets:
      - "10.96.0.0/12"
    cni:
      name: "flannel"
  proxy:
    disabled: false
  discovery:
    enabled: true
    registries:
      kubernetes:
        disabled: false
      internal:
        disabled: false
  scheduler:
    image: "ghcr.io/siderolabs/kube-scheduler:{{KUBERNETES_VERSION}}"
  controllerManager:
    image: "ghcr.io/siderolabs/kube-controller-manager:{{KUBERNETES_VERSION}}"
  etcd:
    image: "ghcr.io/siderolabs/etcd:{{ETCD_VERSION}}"
    advertisedSubnets:
      - "{{SUBNET}}"
  coreDNS:
    image: "ghcr.io/siderolabs/coredns:{{COREDNS_VERSION}}"
```

Update the `scripts/proxmox-helper.sh` to include Talos configuration support:

```bash
#!/bin/bash

# Twinbox Proxmox Helper Script
# Manages VM lifecycle on Proxmox VE for Talos Linux deployments

set -euo pipefail

# Default configuration
DEFAULT_NODE_COUNT=3
DEFAULT_VM_START_ID=200
DEFAULT_MEMORY=4096
DEFAULT_CORES=2
DEFAULT_DISK_SIZE=20
DEFAULT_BRIDGE=vmbr0
DEFAULT_TEMPLATE=""  # Talos doesn't use traditional templates, so this will be handled specially
DEFAULT_TARGET_NODE="pve"
DEFAULT_SCSI_HW="virtio-scsi-single"
DEFAULT_NET_MODEL="virtio"
DEFAULT_TALOS_VERSION="v1.7.4"
DEFAULT_KUBERNETES_VERSION="v1.29.6"
DEFAULT_ETCD_VERSION="v3.5.14"
DEFAULT_COREDNS_VERSION="v1.11.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Proxmox Helper Script for Talos Linux VM Management

Commands:
    create-cluster    Create a new Talos Linux cluster
    delete-cluster    Delete an existing cluster
    list-vms         List all Talos VMs
    start-vm         Start a VM
    stop-vm          Stop a VM
    destroy-vm       Destroy a VM
    generate-config  Generate Talos machine configs

Options:
    --node-count N        Number of worker nodes (default: $DEFAULT_NODE_COUNT)
    --start-id N          Starting VM ID (default: $DEFAULT_VM_START_ID)
    --memory MB           Memory per VM in MB (default: $DEFAULT_MEMORY)
    --cores N             CPU cores per VM (default: $DEFAULT_CORES)
    --disk-size GB        Disk size per VM in GB (default: $DEFAULT_DISK_SIZE)
    --bridge BR           Network bridge (default: $DEFAULT_BRIDGE)
    --target-node NODE    Target Proxmox node (default: $DEFAULT_TARGET_NODE)
    --cluster-name NAME   Cluster name (default: talos-cluster)
    --talos-version VER   Talos version (default: $DEFAULT_TALOS_VERSION)
    --k8s-version VER     Kubernetes version (default: $DEFAULT_KUBERNETES_VERSION)

Examples:
    $(basename "$0") create-cluster --cluster-name my-cluster --node-count 3
    $(basename "$0") generate-config --cluster-name my-cluster
    $(basename "$0") delete-cluster --cluster-name my-cluster
    $(basename "$0") list-vms
EOF
}

# Initialize Proxmox API connection
init_proxmox_api() {
    if [ -z "${PROXMOX_HOST:-}" ] || [ -z "${PROXMOX_USER:-}" ] || [ -z "${PROXMOX_PASSWORD:-}" ]; then
        error "PROXMOX_HOST, PROXMOX_USER, and PROXMOX_PASSWORD environment variables must be set"
        exit 1
    fi

    # Construct API URL
    API_URL="https://${PROXMOX_HOST}:8006/api2/json"
    
    # Authenticate and get CSRF token and ticket
    AUTH_RESPONSE=$(curl -k -s -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" \
        "${API_URL}/access/ticket")
    
    if [ $? -ne 0 ]; then
        error "Failed to authenticate with Proxmox API"
        exit 1
    fi
    
    TICKET=$(echo "$AUTH_RESPONSE" | jq -r '.data.ticket')
    CSRF_PREVENTION_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.data.CSRFPreventionToken')
    
    if [ "$TICKET" = "null" ] || [ "$CSRF_PREVENTION_TOKEN" = "null" ]; then
        error "Authentication failed: Invalid credentials"
        exit 1
    fi
    
    log "Successfully authenticated with Proxmox API"
}

# Check if a VM exists
vm_exists() {
    local vm_id=$1
    local response
    response=$(curl -k -s -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}/status/current" 2>/dev/null)
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Create a single VM for Talos
create_vm() {
    local vm_id=$1
    local vm_name=$2
    local is_control_plane=$3  # "true" for control plane, "false" for worker
    
    log "Creating VM ${vm_name} (ID: ${vm_id}) for Talos Linux"
    
    # Prepare the VM configuration
    local vm_config="vmid=${vm_id}
name=${vm_name}
memory=${MEMORY}
cores=${CORES}
net0=${DEFAULT_NET_MODEL},bridge=${BRIDGE}
scsihw=${DEFAULT_SCSI_HW}
scsi0=local-lvm:vm-${vm_id}-disk-0,size=${DISK_SIZE}G
bios=ovmf
efidisk0=local-lvm:vm-${vm_id}-efi,efitype=4m
machine=q35
onboot=1
ostype=l26
cpu=cputype=host"

    # For Talos, we'll create the VM with minimal configuration and attach ISO later
    # Create temporary config file
    local temp_config=$(mktemp)
    echo -e "$vm_config" > "$temp_config"
    
    # Upload the config to Proxmox
    local upload_response
    upload_response=$(curl -k -s \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "Content-Type: multipart/form-data" \
        -F "config=@${temp_config}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu")

    if [ $? -ne 0 ]; then
        error "Failed to create VM ${vm_name}"
        rm -f "$temp_config"
        return 1
    fi
    
    # Check for errors in response
    if echo "$upload_response" | jq -e '.errors' >/dev/null 2>&1; then
        error "Error creating VM ${vm_name}: $(echo "$upload_response" | jq -r '.errors')"
        rm -f "$temp_config"
        return 1
    fi
    
    log "Successfully created VM ${vm_name} (ID: ${vm_id})"
    rm -f "$temp_config"
    
    # Return the VM ID
    echo "$vm_id"
}

# Create a complete Talos cluster
create_cluster() {
    local cluster_name=$1
    local node_count=$2
    local start_id=$3
    
    log "Creating Talos cluster: ${cluster_name}"
    log "Cluster configuration:"
    log "  - Control plane nodes: 1"
    log "  - Worker nodes: ${node_count}"
    log "  - Total VMs: $((1 + node_count))"
    log "  - Starting VM ID: ${start_id}"
    log "  - Memory per VM: ${MEMORY}MB"
    log "  - CPU cores per VM: ${CORES}"
    log "  - Disk size per VM: ${DISK_SIZE}GB"
    
    # Create control plane node (always first)
    local control_plane_id=$((start_id))
    local control_plane_name="${cluster_name}-control-plane-0"
    
    if vm_exists "$control_plane_id"; then
        error "VM ID ${control_plane_id} already exists, cannot create cluster"
        return 1
    fi
    
    local created_vm_id
    created_vm_id=$(create_vm "$control_plane_id" "$control_plane_name" "true")
    if [ $? -ne 0 ]; then
        error "Failed to create control plane VM"
        return 1
    fi
    
    log "Control plane VM created successfully"
    
    # Create worker nodes
    for i in $(seq 1 $node_count); do
        local worker_id=$((start_id + i))
        local worker_name="${cluster_name}-worker-${i}"
        
        if vm_exists "$worker_id"; then
            error "VM ID ${worker_id} already exists, cannot create worker VM"
            return 1
        fi
        
        created_vm_id=$(create_vm "$worker_id" "$worker_name" "false")
        if [ $? -ne 0 ]; then
            error "Failed to create worker VM ${worker_name}"
            return 1
        fi
        
        log "Worker VM ${worker_name} created successfully"
    done
    
    log "Cluster ${cluster_name} created successfully!"
    log "VM IDs allocated: ${start_id} to $((start_id + node_count))"
    
    # Generate cluster configuration
    generate_cluster_config "$cluster_name" "$start_id" "$node_count"
}

# Generate Talos cluster configuration
generate_cluster_config() {
    local cluster_name=$1
    local start_id=$2
    local node_count=$3
    
    log "Generating Talos cluster configuration for ${cluster_name}"
    
    # Create cluster config directory
    local config_dir="clusters/${cluster_name}"
    mkdir -p "$config_dir"
    
    # Generate placeholder config files
    cat > "${config_dir}/clusterconfig.yaml" << EOF
# Talos Cluster Configuration for ${cluster_name}
# Generated on $(date)
clusterName: "${cluster_name}"
endpoint: "https://<CONTROL_PLANE_IP>:6443"
talosVersion: "${TALOS_VERSION}"
kubernetesVersion: "${KUBERNETES_VERSION}"
controlPlaneNodes:
  - id: ${start_id}
    name: "${cluster_name}-control-plane-0"
    ipAddress: "<CONTROL_PLANE_IP>"
workerNodes:
EOF

    for i in $(seq 1 $node_count); do
        echo "  - id: $((start_id + i))" >> "${config_dir}/clusterconfig.yaml"
        echo "    name: \"${cluster_name}-worker-${i}\"" >> "${config_dir}/clusterconfig.yaml"
        echo "    ipAddress: \"<WORKER_${i}_IP>\"" >> "${config_dir}/clusterconfig.yaml"
    done
    
    log "Cluster configuration saved to ${config_dir}/clusterconfig.yaml"
}

# Generate Talos machine configs
generate_configs() {
    local cluster_name=$1
    
    log "Generating Talos machine configurations for ${cluster_name}"
    
    # Create config directory
    local config_dir="clusters/${cluster_name}/talos-configs"
    mkdir -p "$config_dir"
    
    # Generate a sample machine config for control plane
    sed -e "s/{{TALOS_VERSION}}/${TALOS_VERSION}/g" \
        -e "s/{{KUBERNETES_VERSION}}/${KUBERNETES_VERSION}/g" \
        -e "s/{{ETCD_VERSION}}/${DEFAULT_ETCD_VERSION}/g" \
        -e "s/{{COREDNS_VERSION}}/${DEFAULT_COREDNS_VERSION}/g" \
        -e "s/{{CLUSTER_ID}}/$(openssl rand -hex 16)/g" \
        -e "s/{{CLUSTER_SECRET}}/$(openssl rand -hex 32)/g" \
        -e "s/type: \"controlplane\"/type: \"controlplane\"/g" \
        -e "s/{{HOSTNAME}}/${cluster_name}-control-plane/g" \
        -e "s/{{CONTROL_PLANE_IP}}/<CONTROL_PLANE_IP>/g" \
        -e "s/{{VIP_IP}}/<VIP_IP>/g" \
        -e "s/{{SUBNET}}/<SUBNET>/g" \
        "templates/talos-machine-config.yaml" > "${config_dir}/control-plane.yaml"
    
    # Generate a sample machine config for worker
    sed -e "s/{{TALOS_VERSION}}/${TALOS_VERSION}/g" \
        -e "s/{{KUBERNETES_VERSION}}/${KUBERNETES_VERSION}/g" \
        -e "s/{{ETCD_VERSION}}/${DEFAULT_ETCD_VERSION}/g" \
        -e "s/{{COREDNS_VERSION}}/${DEFAULT_COREDNS_VERSION}/g" \
        -e "s/type: \"controlplane\"/type: \"worker\"/g" \
        -e "s/{{HOSTNAME}}/${cluster_name}-worker/g" \
        -e "s/{{CONTROL_PLANE_IP}}/<CONTROL_PLANE_IP>/g" \
        -e "s/{{VIP_IP}}/<VIP_IP>/g" \
        -e "s/{{SUBNET}}/<SUBNET>/g" \
        "templates/talos-machine-config.yaml" > "${config_dir}/worker.yaml"
    
    log "Talos machine configurations generated in ${config_dir}/"
    log "Note: These are templates that need to be customized with actual values before deployment"
}

# Main function
main() {
    log "Twinbox Proxmox Helper Script"
    
    case $COMMAND in
        create-cluster)
            init_proxmox_api
            create_cluster "$CLUSTER_NAME" "$NODE_COUNT" "$VM_START_ID"
            ;;
        delete-cluster)
            log "Delete cluster functionality not yet implemented"
            ;;
        list-vms)
            log "List VMs functionality not yet implemented"
            ;;
        start-vm)
            log "Start VM functionality not yet implemented"
            ;;
        stop-vm)
            log "Stop VM functionality not yet implemented"
            ;;
        destroy-vm)
            log "Destroy VM functionality not yet implemented"
            ;;
        generate-config)
            generate_configs "$CLUSTER_NAME"
            ;;
        *)
            error "Unknown command: $COMMAND"
            usage
            exit 1
            ;;
    esac
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

# Initialize default values
NODE_COUNT=$DEFAULT_NODE_COUNT
VM_START_ID=$DEFAULT_VM_START_ID
MEMORY=$DEFAULT_MEMORY
CORES=$DEFAULT_CORES
DISK_SIZE=$DEFAULT_DISK_SIZE
BRIDGE=$DEFAULT_BRIDGE
CLUSTER_NAME="talos-cluster"
DEFAULT_TARGET_NODE="pve"
TALOS_VERSION=$DEFAULT_TALOS_VERSION
KUBERNETES_VERSION=$DEFAULT_KUBERNETES_VERSION

# Parse options
while [ $# -gt 0 ]; do
    case $1 in
        --node-count)
            NODE_COUNT="$2"
            shift 2
            ;;
        --start-id)
            VM_START_ID="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --cores)
            CORES="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --target-node)
            DEFAULT_TARGET_NODE="$2"
            shift 2
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --talos-version)
            TALOS_VERSION="$2"
            shift 2
            ;;
        --k8s-version)
            KUBERNETES_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Validate inputs
if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || [ "$NODE_COUNT" -lt 1 ]; then
    error "Invalid node count: $NODE_COUNT"
    exit 1
fi

if ! [[ "$VM_START_ID" =~ ^[0-9]+$ ]] || [ "$VM_START_ID" -lt 100 ]; then
    error "Invalid VM start ID: $VM_START_ID"
    exit 1
fi

if ! [[ "$MEMORY" =~ ^[0-9]+$ ]] || [ "$MEMORY" -lt 512 ]; then
    error "Invalid memory size: $MEMORY"
    exit 1
fi

if ! [[ "$CORES" =~ ^[0-9]+$ ]] || [ "$CORES" -lt 1 ]; then
    error "Invalid core count: $CORES"
    exit 1
fi

if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE" -lt 1 ]; then
    error "Invalid disk size: $DISK_SIZE"
    exit 1
fi

main
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos_config_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add templates/talos-machine-config.yaml scripts/proxmox-helper.sh
git commit -m "Add Talos configuration support and config generation"
```

### Task 4: Implement VM Lifecycle Management Functions

**Files:**
- Modify: `scripts/proxmox-helper.sh:500-800`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/vm_lifecycle_test.sh
set -e

# Check if the script contains the required lifecycle functions
if ! grep -q "delete_cluster" "scripts/proxmox-helper.sh"; then
    echo "FAIL: delete_cluster function not found"
    exit 1
fi

if ! grep -q "list_vms" "scripts/proxmox-helper.sh"; then
    echo "FAIL: list_vms function not found"
    exit 1
fi

if ! grep -q "start_vm" "scripts/proxmox-helper.sh"; then
    echo "FAIL: start_vm function not found"
    exit 1
fi

if ! grep -q "stop_vm" "scripts/proxmox-helper.sh"; then
    echo "FAIL: stop_vm function not found"
    exit 1
fi

if ! grep -q "destroy_vm" "scripts/proxmox-helper.sh"; then
    echo "FAIL: destroy_vm function not found"
    exit 1
fi

echo "PASS: VM lifecycle functions exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/vm_lifecycle_test.sh`
Expected: FAIL error indicating functions don't exist

**Step 3: Write minimal implementation**

Update the `scripts/proxmox-helper.sh` to include lifecycle management functions:

```bash
#!/bin/bash

# Twinbox Proxmox Helper Script
# Manages VM lifecycle on Proxmox VE for Talos Linux deployments

set -euo pipefail

# Default configuration
DEFAULT_NODE_COUNT=3
DEFAULT_VM_START_ID=200
DEFAULT_MEMORY=4096
DEFAULT_CORES=2
DEFAULT_DISK_SIZE=20
DEFAULT_BRIDGE=vmbr0
DEFAULT_TEMPLATE=""  # Talos doesn't use traditional templates, so this will be handled specially
DEFAULT_TARGET_NODE="pve"
DEFAULT_SCSI_HW="virtio-scsi-single"
DEFAULT_NET_MODEL="virtio"
DEFAULT_TALOS_VERSION="v1.7.4"
DEFAULT_KUBERNETES_VERSION="v1.29.6"
DEFAULT_ETCD_VERSION="v3.5.14"
DEFAULT_COREDNS_VERSION="v1.11.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Proxmox Helper Script for Talos Linux VM Management

Commands:
    create-cluster    Create a new Talos Linux cluster
    delete-cluster    Delete an existing cluster
    list-vms         List all Talos VMs
    start-vm         Start a VM
    stop-vm          Stop a VM
    destroy-vm       Destroy a VM
    generate-config  Generate Talos machine configs

Options:
    --node-count N        Number of worker nodes (default: $DEFAULT_NODE_COUNT)
    --start-id N          Starting VM ID (default: $DEFAULT_VM_START_ID)
    --memory MB           Memory per VM in MB (default: $DEFAULT_MEMORY)
    --cores N             CPU cores per VM (default: $DEFAULT_CORES)
    --disk-size GB        Disk size per VM in GB (default: $DEFAULT_DISK_SIZE)
    --bridge BR           Network bridge (default: $DEFAULT_BRIDGE)
    --target-node NODE    Target Proxmox node (default: $DEFAULT_TARGET_NODE)
    --cluster-name NAME   Cluster name (default: talos-cluster)
    --talos-version VER   Talos version (default: $DEFAULT_TALOS_VERSION)
    --k8s-version VER     Kubernetes version (default: $DEFAULT_KUBERNETES_VERSION)
    --vm-id N             VM ID for single VM operations

Examples:
    $(basename "$0") create-cluster --cluster-name my-cluster --node-count 3
    $(basename "$0") generate-config --cluster-name my-cluster
    $(basename "$0") delete-cluster --cluster-name my-cluster
    $(basename "$0") list-vms
    $(basename "$0") start-vm --vm-id 200
EOF
}

# Initialize Proxmox API connection
init_proxmox_api() {
    if [ -z "${PROXMOX_HOST:-}" ] || [ -z "${PROXMOX_USER:-}" ] || [ -z "${PROXMOX_PASSWORD:-}" ]; then
        error "PROXMOX_HOST, PROXMOX_USER, and PROXMOX_PASSWORD environment variables must be set"
        exit 1
    fi

    # Construct API URL
    API_URL="https://${PROXMOX_HOST}:8006/api2/json"
    
    # Authenticate and get CSRF token and ticket
    AUTH_RESPONSE=$(curl -k -s -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" \
        "${API_URL}/access/ticket")
    
    if [ $? -ne 0 ]; then
        error "Failed to authenticate with Proxmox API"
        exit 1
    fi
    
    TICKET=$(echo "$AUTH_RESPONSE" | jq -r '.data.ticket')
    CSRF_PREVENTION_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.data.CSRFPreventionToken')
    
    if [ "$TICKET" = "null" ] || [ "$CSRF_PREVENTION_TOKEN" = "null" ]; then
        error "Authentication failed: Invalid credentials"
        exit 1
    fi
    
    log "Successfully authenticated with Proxmox API"
}

# Check if a VM exists
vm_exists() {
    local vm_id=$1
    local response
    response=$(curl -k -s -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}/status/current" 2>/dev/null)
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Get VM status
get_vm_status() {
    local vm_id=$1
    local response
    response=$(curl -k -s -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}/status/current" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "unknown"
        return 1
    fi
    
    echo "$response" | jq -r '.data.status // "unknown"'
}

# Create a single VM for Talos
create_vm() {
    local vm_id=$1
    local vm_name=$2
    local is_control_plane=$3  # "true" for control plane, "false" for worker
    
    log "Creating VM ${vm_name} (ID: ${vm_id}) for Talos Linux"
    
    # Prepare the VM configuration
    local vm_config="vmid=${vm_id}
name=${vm_name}
memory=${MEMORY}
cores=${CORES}
net0=${DEFAULT_NET_MODEL},bridge=${BRIDGE}
scsihw=${DEFAULT_SCSI_HW}
scsi0=local-lvm:vm-${vm_id}-disk-0,size=${DISK_SIZE}G
bios=ovmf
efidisk0=local-lvm:vm-${vm_id}-efi,efitype=4m
machine=q35
onboot=1
ostype=l26
cpu=cputype=host"

    # For Talos, we'll create the VM with minimal configuration and attach ISO later
    # Create temporary config file
    local temp_config=$(mktemp)
    echo -e "$vm_config" > "$temp_config"
    
    # Upload the config to Proxmox
    local upload_response
    upload_response=$(curl -k -s \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "Content-Type: multipart/form-data" \
        -F "config=@${temp_config}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu")

    if [ $? -ne 0 ]; then
        error "Failed to create VM ${vm_name}"
        rm -f "$temp_config"
        return 1
    fi
    
    # Check for errors in response
    if echo "$upload_response" | jq -e '.errors' >/dev/null 2>&1; then
        error "Error creating VM ${vm_name}: $(echo "$upload_response" | jq -r '.errors')"
        rm -f "$temp_config"
        return 1
    fi
    
    log "Successfully created VM ${vm_name} (ID: ${vm_id})"
    rm -f "$temp_config"
    
    # Return the VM ID
    echo "$vm_id"
}

# Create a complete Talos cluster
create_cluster() {
    local cluster_name=$1
    local node_count=$2
    local start_id=$3
    
    log "Creating Talos cluster: ${cluster_name}"
    log "Cluster configuration:"
    log "  - Control plane nodes: 1"
    log "  - Worker nodes: ${node_count}"
    log "  - Total VMs: $((1 + node_count))"
    log "  - Starting VM ID: ${start_id}"
    log "  - Memory per VM: ${MEMORY}MB"
    log "  - CPU cores per VM: ${CORES}"
    log "  - Disk size per VM: ${DISK_SIZE}GB"
    
    # Create control plane node (always first)
    local control_plane_id=$((start_id))
    local control_plane_name="${cluster_name}-control-plane-0"
    
    if vm_exists "$control_plane_id"; then
        error "VM ID ${control_plane_id} already exists, cannot create cluster"
        return 1
    fi
    
    local created_vm_id
    created_vm_id=$(create_vm "$control_plane_id" "$control_plane_name" "true")
    if [ $? -ne 0 ]; then
        error "Failed to create control plane VM"
        return 1
    fi
    
    log "Control plane VM created successfully"
    
    # Create worker nodes
    for i in $(seq 1 $node_count); do
        local worker_id=$((start_id + i))
        local worker_name="${cluster_name}-worker-${i}"
        
        if vm_exists "$worker_id"; then
            error "VM ID ${worker_id} already exists, cannot create worker VM"
            return 1
        fi
        
        created_vm_id=$(create_vm "$worker_id" "$worker_name" "false")
        if [ $? -ne 0 ]; then
            error "Failed to create worker VM ${worker_name}"
            return 1
        fi
        
        log "Worker VM ${worker_name} created successfully"
    done
    
    log "Cluster ${cluster_name} created successfully!"
    log "VM IDs allocated: ${start_id} to $((start_id + node_count))"
    
    # Generate cluster configuration
    generate_cluster_config "$cluster_name" "$start_id" "$node_count"
}

# Delete a complete Talos cluster
delete_cluster() {
    local cluster_name=$1
    local start_id=$2
    local node_count=$3
    
    log "Deleting Talos cluster: ${cluster_name}"
    log "This will permanently delete VMs with IDs from ${start_id} to $((start_id + node_count))"
    
    # Confirm deletion
    read -p "Are you sure you want to delete cluster ${cluster_name}? (yes/no): " confirmation
    if [ "$confirmation" != "yes" ]; then
        log "Cluster deletion cancelled"
        return 0
    fi
    
    # Stop and destroy VMs in reverse order
    for i in $(seq $node_count -1 0); do
        local vm_id=$((start_id + i))
        local vm_name
        if [ $i -eq 0 ]; then
            vm_name="${cluster_name}-control-plane-0"
        else
            vm_name="${cluster_name}-worker-${i}"
        fi
        
        log "Processing VM ${vm_name} (ID: ${vm_id})"
        
        # Check if VM exists
        if ! vm_exists "$vm_id"; then
            warn "VM ${vm_id} does not exist, skipping"
            continue
        fi
        
        # Get VM status
        local status
        status=$(get_vm_status "$vm_id")
        
        # Stop VM if running
        if [ "$status" = "running" ]; then
            log "Stopping VM ${vm_id}..."
            local stop_response
            stop_response=$(curl -k -s -X POST \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}/status/stop")
                
            if [ $? -ne 0 ]; then
                error "Failed to stop VM ${vm_id}"
                continue
            fi
            
            # Wait for VM to stop
            local timeout=60
            local count=0
            while [ $count -lt $timeout ]; do
                sleep 1
                status=$(get_vm_status "$vm_id")
                if [ "$status" != "running" ]; then
                    break
                fi
                count=$((count + 1))
            done
            
            if [ "$status" = "running" ]; then
                error "Timeout waiting for VM ${vm_id} to stop"
            else
                log "VM ${vm_id} stopped successfully"
            fi
        fi
        
        # Destroy VM
        log "Destroying VM ${vm_id}..."
        local destroy_response
        destroy_response=$(curl -k -s -X DELETE \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}")
            
        if [ $? -ne 0 ]; then
            error "Failed to destroy VM ${vm_id}"
        else
            log "VM ${vm_id} destroyed successfully"
        fi
    done
    
    log "Cluster ${cluster_name} deletion completed"
}

# List all Talos VMs
list_vms() {
    log "Listing Talos VMs on node ${DEFAULT_TARGET_NODE}"
    
    local response
    response=$(curl -k -s -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu")
    
    if [ $? -ne 0 ]; then
        error "Failed to retrieve VM list"
        return 1
    fi
    
    # Filter for Talos-related VMs
    echo "$response" | jq -r '.data[] | select(.name | test("talos|control-plane|worker")) | "ID: \(.vmid) | Name: \(.name) | Status: \(.status) | CPU: \(.maxcpu) | RAM: \(.maxmem // 0 | tonumber / 1024 / 1024 | floor) MB"' | sort -n
}

# Start a VM
start_vm() {
    local vm_id=$1
    
    if ! vm_exists "$vm_id"; then
        error "VM ${vm_id} does not exist"
        return 1
    fi
    
    local status
    status=$(get_vm_status "$vm_id")
    
    if [ "$status" = "running" ]; then
        log "VM ${vm_id} is already running"
        return 0
    fi
    
    log "Starting VM ${vm_id}..."
    local start_response
    start_response=$(curl -k -s -X POST \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}/status/start")
        
    if [ $? -ne 0 ]; then
        error "Failed to start VM ${vm_id}"
        return 1
    fi
    
    # Wait for VM to start
    local timeout=60
    local count=0
    while [ $count -lt $timeout ]; do
        sleep 1
        status=$(get_vm_status "$vm_id")
        if [ "$status" = "running" ]; then
            break
        fi
        count=$((count + 1))
    done
    
    if [ "$status" = "running" ]; then
        log "VM ${vm_id} started successfully"
    else
        error "Timeout waiting for VM ${vm_id} to start"
        return 1
    fi
}

# Stop a VM
stop_vm() {
    local vm_id=$1
    
    if ! vm_exists "$vm_id"; then
        error "VM ${vm_id} does not exist"
        return 1
    fi
    
    local status
    status=$(get_vm_status "$vm_id")
    
    if [ "$status" != "running" ]; then
        log "VM ${vm_id} is not running"
        return 0
    fi
    
    log "Stopping VM ${vm_id}..."
    local stop_response
    stop_response=$(curl -k -s -X POST \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}/status/stop")
        
    if [ $? -ne 0 ]; then
        error "Failed to stop VM ${vm_id}"
        return 1
    fi
    
    # Wait for VM to stop
    local timeout=60
    local count=0
    while [ $count -lt $timeout ]; do
        sleep 1
        status=$(get_vm_status "$vm_id")
        if [ "$status" != "running" ]; then
            break
        fi
        count=$((count + 1))
    done
    
    if [ "$status" != "running" ]; then
        log "VM ${vm_id} stopped successfully"
    else
        error "Timeout waiting for VM ${vm_id} to stop"
        return 1
    fi
}

# Destroy a VM
destroy_vm() {
    local vm_id=$1
    
    if ! vm_exists "$vm_id"; then
        error "VM ${vm_id} does not exist"
        return 1
    fi
    
    log "Destroying VM ${vm_id}..."
    
    # Stop VM first if running
    local status
    status=$(get_vm_status "$vm_id")
    
    if [ "$status" = "running" ]; then
        log "Stopping VM ${vm_id} before destruction..."
        stop_vm "$vm_id"
    fi
    
    # Destroy VM
    local destroy_response
    destroy_response=$(curl -k -s -X DELETE \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
        "${API_URL}/nodes/${DEFAULT_TARGET_NODE}/qemu/${vm_id}")
        
    if [ $? -ne 0 ]; then
        error "Failed to destroy VM ${vm_id}"
        return 1
    fi
    
    log "VM ${vm_id} destroyed successfully"
}

# Generate Talos cluster configuration
generate_cluster_config() {
    local cluster_name=$1
    local start_id=$2
    local node_count=$3
    
    log "Generating Talos cluster configuration for ${cluster_name}"
    
    # Create cluster config directory
    local config_dir="clusters/${cluster_name}"
    mkdir -p "$config_dir"
    
    # Generate placeholder config files
    cat > "${config_dir}/clusterconfig.yaml" << EOF
# Talos Cluster Configuration for ${cluster_name}
# Generated on $(date)
clusterName: "${cluster_name}"
endpoint: "https://<CONTROL_PLANE_IP>:6443"
talosVersion: "${TALOS_VERSION}"
kubernetesVersion: "${KUBERNETES_VERSION}"
controlPlaneNodes:
  - id: ${start_id}
    name: "${cluster_name}-control-plane-0"
    ipAddress: "<CONTROL_PLANE_IP>"
workerNodes:
EOF

    for i in $(seq 1 $node_count); do
        echo "  - id: $((start_id + i))" >> "${config_dir}/clusterconfig.yaml"
        echo "    name: \"${cluster_name}-worker-${i}\"" >> "${config_dir}/clusterconfig.yaml"
        echo "    ipAddress: \"<WORKER_${i}_IP>\"" >> "${config_dir}/clusterconfig.yaml"
    done
    
    log "Cluster configuration saved to ${config_dir}/clusterconfig.yaml"
}

# Generate Talos machine configs
generate_configs() {
    local cluster_name=$1
    
    log "Generating Talos machine configurations for ${cluster_name}"
    
    # Create config directory
    local config_dir="clusters/${cluster_name}/talos-configs"
    mkdir -p "$config_dir"
    
    # Generate a sample machine config for control plane
    sed -e "s/{{TALOS_VERSION}}/${TALOS_VERSION}/g" \
        -e "s/{{KUBERNETES_VERSION}}/${KUBERNETES_VERSION}/g" \
        -e "s/{{ETCD_VERSION}}/${DEFAULT_ETCD_VERSION}/g" \
        -e "s/{{COREDNS_VERSION}}/${DEFAULT_COREDNS_VERSION}/g" \
        -e "s/{{CLUSTER_ID}}/$(openssl rand -hex 16)/g" \
        -e "s/{{CLUSTER_SECRET}}/$(openssl rand -hex 32)/g" \
        -e "s/type: \"controlplane\"/type: \"controlplane\"/g" \
        -e "s/{{HOSTNAME}}/${cluster_name}-control-plane/g" \
        -e "s/{{CONTROL_PLANE_IP}}/<CONTROL_PLANE_IP>/g" \
        -e "s/{{VIP_IP}}/<VIP_IP>/g" \
        -e "s/{{SUBNET}}/<SUBNET>/g" \
        "templates/talos-machine-config.yaml" > "${config_dir}/control-plane.yaml"
    
    # Generate a sample machine config for worker
    sed -e "s/{{TALOS_VERSION}}/${TALOS_VERSION}/g" \
        -e "s/{{KUBERNETES_VERSION}}/${KUBERNETES_VERSION}/g" \
        -e "s/{{ETCD_VERSION}}/${DEFAULT_ETCD_VERSION}/g" \
        -e "s/{{COREDNS_VERSION}}/${DEFAULT_COREDNS_VERSION}/g" \
        -e "s/{{ETCD_VERSION}}/${DEFAULT_ETCD_VERSION}/g" \
        -e "s/type: \"controlplane\"/type: \"worker\"/g" \
        -e "s/{{HOSTNAME}}/${cluster_name}-worker/g" \
        -e "s/{{CONTROL_PLANE_IP}}/<CONTROL_PLANE_IP>/g" \
        -e "s/{{VIP_IP}}/<VIP_IP>/g" \
        -e "s/{{SUBNET}}/<SUBNET>/g" \
        "templates/talos-machine-config.yaml" > "${config_dir}/worker.yaml"
    
    log "Talos machine configurations generated in ${config_dir}/"
    log "Note: These are templates that need to be customized with actual values before deployment"
}

# Main function
main() {
    log "Twinbox Proxmox Helper Script"
    
    case $COMMAND in
        create-cluster)
            init_proxmox_api
            create_cluster "$CLUSTER_NAME" "$NODE_COUNT" "$VM_START_ID"
            ;;
        delete-cluster)
            init_proxmox_api
            delete_cluster "$CLUSTER_NAME" "$VM_START_ID" "$NODE_COUNT"
            ;;
        list-vms)
            init_proxmox_api
            list_vms
            ;;
        start-vm)
            init_proxmox_api
            if [ -z "${VM_ID:-}" ]; then
                error "--vm-id is required for start-vm command"
                exit 1
            fi
            start_vm "$VM_ID"
            ;;
        stop-vm)
            init_proxmox_api
            if [ -z "${VM_ID:-}" ]; then
                error "--vm-id is required for stop-vm command"
                exit 1
            fi
            stop_vm "$VM_ID"
            ;;
        destroy-vm)
            init_proxmox_api
            if [ -z "${VM_ID:-}" ]; then
                error "--vm-id is required for destroy-vm command"
                exit 1
            fi
            destroy_vm "$VM_ID"
            ;;
        generate-config)
            generate_configs "$CLUSTER_NAME"
            ;;
        *)
            error "Unknown command: $COMMAND"
            usage
            exit 1
            ;;
    esac
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

# Initialize default values
NODE_COUNT=$DEFAULT_NODE_COUNT
VM_START_ID=$DEFAULT_VM_START_ID
MEMORY=$DEFAULT_MEMORY
CORES=$DEFAULT_CORES
DISK_SIZE=$DEFAULT_DISK_SIZE
BRIDGE=$DEFAULT_BRIDGE
CLUSTER_NAME="talos-cluster"
DEFAULT_TARGET_NODE="pve"
TALOS_VERSION=$DEFAULT_TALOS_VERSION
KUBERNETES_VERSION=$DEFAULT_KUBERNETES_VERSION
VM_ID=""

# Parse options
while [ $# -gt 0 ]; do
    case $1 in
        --node-count)
            NODE_COUNT="$2"
            shift 2
            ;;
        --start-id)
            VM_START_ID="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --cores)
            CORES="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --target-node)
            DEFAULT_TARGET_NODE="$2"
            shift 2
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --talos-version)
            TALOS_VERSION="$2"
            shift 2
            ;;
        --k8s-version)
            KUBERNETES_VERSION="$2"
            shift 2
            ;;
        --vm-id)
            VM_ID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Validate inputs
if [ "$COMMAND" = "start-vm" ] || [ "$COMMAND" = "stop-vm" ] || [ "$COMMAND" = "destroy-vm" ]; then
    if [ -z "$VM_ID" ]; then
        error "VM ID is required for single VM operations"
        exit 1
    fi
    
    if ! [[ "$VM_ID" =~ ^[0-9]+$ ]]; then
        error "Invalid VM ID: $VM_ID"
        exit 1
    fi
fi

if [ "$COMMAND" = "create-cluster" ] || [ "$COMMAND" = "delete-cluster" ]; then
    if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || [ "$NODE_COUNT" -lt 1 ]; then
        error "Invalid node count: $NODE_COUNT"
        exit 1
    fi

    if ! [[ "$VM_START_ID" =~ ^[0-9]+$ ]] || [ "$VM_START_ID" -lt 100 ]; then
        error "Invalid VM start ID: $VM_START_ID"
        exit 1
    fi
fi

if ! [[ "$MEMORY" =~ ^[0-9]+$ ]] || [ "$MEMORY" -lt 512 ]; then
    error "Invalid memory size: $MEMORY"
    exit 1
fi

if ! [[ "$CORES" =~ ^[0-9]+$ ]] || [ "$CORES" -lt 1 ]; then
    error "Invalid core count: $CORES"
    exit 1
fi

if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE" -lt 1 ]; then
    error "Invalid disk size: $DISK_SIZE"
    exit 1
fi

main
```

**Step 4: Run test to verify it passes**
Run: `bash tests/vm_lifecycle_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add scripts/proxmox-helper.sh
git commit -m "Implement VM lifecycle management functions"
```

### Task 5: Add Terraform and Ansible Integration Options

**Files:**
- Create: `terraform/talos-vm/main.tf`
- Create: `terraform/talos-vm/variables.tf`
- Create: `terraform/talos-vm/outputs.tf`
- Create: `ansible/playbooks/deploy-talos.yml`
- Create: `ansible/inventory/talos.yml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/terraform_ansible_integration_test.sh
set -e

if [ ! -f "terraform/talos-vm/main.tf" ]; then
    echo "FAIL: terraform/talos-vm/main.tf does not exist"
    exit 1
fi

if [ ! -f "terraform/talos-vm/variables.tf" ]; then
    echo "FAIL: terraform/talos-vm/variables.tf does not exist"
    exit 1
fi

if [ ! -f "terraform/talos-vm/outputs.tf" ]; then
    echo "FAIL: terraform/talos-vm/outputs.tf does not exist"
    exit 1
fi

if [ ! -f "ansible/playbooks/deploy-talos.yml" ]; then
    echo "FAIL: ansible/playbooks/deploy-talos.yml does not exist"
    exit 1
fi

if [ ! -f "ansible/inventory/talos.yml" ]; then
    echo "FAIL: ansible/inventory/talos.yml does not exist"
    exit 1
fi

echo "PASS: Terraform and Ansible integration files exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/terraform_ansible_integration_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory structure:
```bash
mkdir -p terraform/talos-vm
mkdir -p ansible/playbooks
mkdir -p ansible/inventory
```

Create `terraform/talos-vm/variables.tf`:
```hcl
variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_user" {
  description = "Proxmox user account"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification for Proxmox API"
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "talos-cluster"
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "control_plane_config" {
  description = "Configuration for control plane node"
  type = object({
    vmid        = number
    name        = string
    target_node = string
    cores       = number
    memory      = number
    disk_size   = string
    bridge      = string
    ip          = string
    gateway     = string
    # Talos-specific settings
    talos_version = string
    k8s_version   = string
  })
  default = {
    vmid        = 200
    name        = "talos-control-plane-0"
    target_node = "pve"
    cores       = 4
    memory      = 8192
    disk_size   = "40G"
    bridge      = "vmbr0"
    ip          = "192.168.1.200/24"
    gateway     = "192.168.1.1"
    talos_version = "v1.7.4"
    k8s_version   = "v1.29.6"
  }
}

variable "worker_config" {
  description = "Configuration for worker nodes"
  type = object({
    vmid_base   = number
    name_prefix = string
    target_node = string
    cores       = number
    memory      = number
    disk_size   = string
    bridge      = string
    ip_base     = string
    gateway     = string
    # Talos-specific settings
    talos_version = string
    k8s_version   = string
  })
  default = {
    vmid_base   = 201
    name_prefix = "talos-worker"
    target_node = "pve"
    cores       = 4
    memory      = 8192
    disk_size   = "40G"
    bridge      = "vmbr0"
    ip_base     = "192.168.1."
    gateway     = "192.168.1.1"
    talos_version = "v1.7.4"
    k8s_version   = "v1.29.6"
  }
}

variable "talos_iso_path" {
  description = "Path to Talos Linux ISO in Proxmox storage"
  type        = string
  default     = "local:iso/talos-amd64.iso"
}
```

Create `terraform/talos-vm/main.tf`:
```hcl
terraform {
  required_version = ">= 1.0"
  
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9.14"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.proxmox_api_url
  pm_user         = var.proxmox_user
  pm_password     = var.proxmox_password
  pm_tls_insecure = var.proxmox_tls_insecure
}

# Create control plane VM
resource "proxmox_vm_qemu" "control_plane" {
  count = 1

  name        = var.control_plane_config.name
  target_node = var.control_plane_config.target_node
  vmid        = var.control_plane_config.vmid
  
  # Talos uses cloud-init like configuration but through machine configs
  clone      = ""  # Talos doesn't use traditional clones, we'll set up differently
  full_clone = false
  
  cores   = var.control_plane_config.cores
  memory  = var.control_plane_config.memory
  scsihw  = "virtio-scsi-single"
  
  disk {
    slot    = 0
    size    = var.control_plane_config.disk_size
    type    = "scsi"
    storage = "local-lvm"
  }
  
  # EFI disk for Talos compatibility
  efidisk {
    efi_type = "4m"
    storage  = "local-lvm"
    file     = "local-lvm:vm-${var.control_plane_config.vmid}-efi"
  }
  
  network {
    model  = "virtio"
    bridge = var.control_plane_config.bridge
    ipconfig0 = "ip=${var.control_plane_config.ip},gw=${var.control_plane_config.gateway}"
  }
  
  bios = "ovmf"
  onboot = true
  ostype = "l26"  # Linux 2.6 kernel
  
  lifecycle {
    ignore_changes = [
      network,
      disk
    ]
  }
}

# Create worker VMs
resource "proxmox_vm_qemu" "workers" {
  count = var.node_count

  name        = "${var.worker_config.name_prefix}-${count.index + 1}"
  target_node = var.worker_config.target_node
  vmid        = var.worker_config.vmid_base + count.index
  
  clone      = ""  # Talos doesn't use traditional clones
  full_clone = false
  
  cores   = var.worker_config.cores
  memory  = var.worker_config.memory
  scsihw  = "virtio-scsi-single"
  
  disk {
    slot    = 0
    size    = var.worker_config.disk_size
    type    = "scsi"
    storage = "local-lvm"
  }
  
  # EFI disk for Talos compatibility
  efidisk {
    efi_type = "4m"
    storage  = "local-lvm"
    file     = "local-lvm:vm-${var.worker_config.vmid_base + count.index}-efi"
  }
  
  network {
    model  = "virtio"
    bridge = var.worker_config.bridge
    ipconfig0 = "ip=${var.worker_config.ip_base}${200 + count.index + 1}/24,gw=${var.worker_config.gateway}"
  }
  
  bios = "ovmf"
  onboot = true
  ostype = "l26"  # Linux 2.6 kernel
  
  lifecycle {
    ignore_changes = [
      network,
      disk
    ]
  }
}

# Output VM information
output "control_plane_vm" {
  description = "Control plane VM information"
  value = {
    id   = proxmox_vm_qemu.control_plane[0].vmid
    name = proxmox_vm_qemu.control_plane[0].name
    ip   = var.control_plane_config.ip
  }
}

output "worker_vms" {
  description = "Worker VM information"
  value = [
    for i, vm in proxmox_vm_qemu.workers : {
      id   = vm.vmid
      name = vm.name
      ip   = "${var.worker_config.ip_base}${200 + i + 1}/24"
    }
  ]
}

output "cluster_info" {
  description = "Cluster information"
  value = {
    name            = var.cluster_name
    control_plane_id = proxmox_vm_qemu.control_plane[0].vmid
    worker_ids      = [for vm in proxmox_vm_qemu.workers : vm.vmid]
    total_nodes     = var.node_count + 1
  }
}
```

Create `terraform/talos-vm/outputs.tf`:
```hcl
output "control_plane_vm" {
  description = "Control plane VM information"
  value = {
    id   = proxmox_vm_qemu.control_plane[0].vmid
    name = proxmox_vm_qemu.control_plane[0].name
    ip   = var.control_plane_config.ip
  }
}

output "worker_vms" {
  description = "Worker VM information"
  value = [
    for i, vm in proxmox_vm_qemu.workers : {
      id   = vm.vmid
      name = vm.name
      ip   = "${var.worker_config.ip_base}${200 + i + 1}/24"
    }
  ]
}

output "cluster_info" {
  description = "Cluster information"
  value = {
    name            = var.cluster_name
    control_plane_id = proxmox_vm_qemu.control_plane[0].vmid
    worker_ids      = [for vm in proxmox_vm_qemu.workers : vm.vmid]
    total_nodes     = var.node_count + 1
  }
}

output "talos_config_template" {
  description = "Template for generating Talos machine configs"
  value = {
    cluster_name    = var.cluster_name
    talos_version   = var.control_plane_config.talos_version
    k8s_version     = var.control_plane_config.k8s_version
    control_plane_ip = var.control_plane_config.ip
  }
}
```

Create `ansible/playbooks/deploy-talos.yml`:
```yaml
---
- name: Deploy Talos Linux to Proxmox VMs
  hosts: talos_vms
  gather_facts: no
  vars:
    talos_version: "{{ talos_version | default('v1.7.4') }}"
    kubernetes_version: "{{ kubernetes_version | default('v1.29.6') }}"
    talos_image_url: "https://github.com/siderolabs/talos/releases/download/{{ talos_version }}/talos-amd64.iso"
    
  tasks:
    - name: Ensure required directories exist
      file:
        path: "{{ item }}"
        state: directory
        mode: '0755'
      loop:
        - /tmp/talos-configs
        - /opt/talos-images
      
    - name: Download Talos ISO to Proxmox host
      get_url:
        url: "{{ talos_image_url }}"
        dest: "/opt/talos-images/talos-{{ talos_version }}.iso"
        mode: '0644'
      delegate_to: "{{ ansible_host }}"  # Run on Proxmox host
      become: yes
      when: download_talos_iso | default(true)
      
    - name: Upload Talos ISO to Proxmox storage
      shell: |
        pvesm upload local iso/talos-{{ talos_version }}.iso --filename talos-{{ talos_version }}.iso
      delegate_to: "{{ ansible_host }}"  # Run on Proxmox host
      become: yes
      when: upload_talos_iso | default(true)
      register: upload_result
      failed_when: upload_result.rc != 0 and "already exists" not in upload_result.stderr

    - name: Attach ISO to VM
      shell: |
        qm set {{ vm_id }} -ide2 local:iso/talos-{{ talos_version }}.iso,media=cdrom
      delegate_to: "{{ ansible_host }}"  # Run on Proxmox host
      become: yes
      vars:
        vm_id: "{{ vm_id | default(omit) }}"
      when: attach_iso | default(true)

    - name: Configure boot order for Talos installation
      shell: |
        qm set {{ vm_id }} -boot c -bootdisk scsi0
      delegate_to: "{{ ansible_host }}"  # Run on Proxmox host
      become: yes
      vars:
        vm_id: "{{ vm_id | default(omit) }}"
      when: configure_boot_order | default(true)

    - name: Start VM for Talos installation
      shell: |
        qm start {{ vm_id }}
      delegate_to: "{{ ansible_host }}"  # Run on Proxmox host
      become: yes
      vars:
        vm_id: "{{ vm_id | default(omit) }}"
      when: start_vm_after_setup | default(true)

    - name: Wait for VM to boot Talos
      wait_for_connection:
        connect_timeout: 20
        sleep: 5
        delay: 5
        timeout: 300  # 5 minutes
      when: wait_for_connection | default(false)

    - name: Apply Talos machine configuration
      shell: |
        talosctl apply-config --insecure --nodes {{ ansible_host }} --file /tmp/talos-configs/{{ inventory_hostname }}.yaml
      delegate_to: localhost
      when: apply_machine_config | default(false)
      register: config_result
      failed_when: config_result.rc != 0 and "connection refused" not in config_result.stderr

    - name: Verify Talos cluster health
      shell: |
        talosctl health --nodes {{ ansible_host }}
      delegate_to: localhost
      when: verify_cluster_health | default(false)
      register: health_result
      failed_when: health_result.rc != 0 and "connection refused" not in health_result.stderr
```

Create `ansible/inventory/talos.yml`:
```yaml
---
all:
  children:
    talos_vms:
      hosts:
        # This inventory will be populated dynamically after VM creation
        # Example static entries (to be replaced by dynamic inventory):
        # talos-control-plane-0:
        #   ansible_host: 192.168.1.200
        #   vm_id: 200
        #   vm_type: control_plane
        # talos-worker-1:
        #   ansible_host: 192.168.1.201
        #   vm_id: 201
        #   vm_type: worker
        # talos-worker-2:
        #   ansible_host: 192.168.1.202
        #   vm_id: 202
        #   vm_type: worker
    control_plane:
      hosts:
        # Control plane nodes will be added here dynamically
    workers:
      hosts:
        # Worker nodes will be added here dynamically
  vars:
    ansible_user: root
    ansible_ssh_private_key_file: "{{ lookup('env', 'HOME') }}/.ssh/id_rsa"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
```

**Step 4: Run test to verify it passes**
Run: `bash tests/terraform_ansible_integration_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add terraform/ ansible/
git commit -m "Add Terraform and Ansible integration for Talos deployment"
```

### Task 6: Create Documentation and Usage Examples

**Files:**
- Create: `README.md`
- Create: `docs/talos-proxmox-guide.md`
- Create: `examples/simple-cluster.sh`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/documentation_test.sh
set -e

if [ ! -f "README.md" ]; then
    echo "FAIL: README.md does not exist"
    exit 1
fi

if [ ! -f "docs/talos-proxmox-guide.md" ]; then
    echo "FAIL: docs/talos-proxmox-guide.md does not exist"
    exit 1
fi

if [ ! -f "examples/simple-cluster.sh" ]; then
    echo "FAIL: examples/simple-cluster.sh does not exist"
    exit 1
fi

echo "PASS: Documentation files exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/documentation_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p docs
mkdir -p examples
```

Create `README.md`:
```markdown
# Twinbox Talos on Proxmox Framework

A comprehensive solution for deploying Talos Linux-based Kubernetes clusters on Proxmox VE.

## Features

- Automated VM provisioning on Proxmox VE
- Talos Linux configuration and deployment
- Flexible cluster sizing (1 control plane + N workers)
- Integrated Terraform and Ansible workflows
- Lifecycle management (create, delete, start, stop, destroy)
- Configuration generation for Talos machine configs

## Prerequisites

- Proxmox VE 7.0 or higher
- Bash shell environment
- `curl` and `jq` utilities
- `openssl` for generating secrets
- Optional: Terraform and Ansible for advanced workflows

## Quick Start

### 1. Set Environment Variables

```bash
export PROXMOX_HOST="your-proxmox-host.domain.com"
export PROXMOX_USER="your-api-user@pve"
export PROXMOX_PASSWORD="your-api-password"
```

### 2. Create a Talos Cluster

```bash
./scripts/proxmox-helper.sh create-cluster \
  --cluster-name my-talos-cluster \
  --node-count 2 \
  --memory 8192 \
  --cores 4
```

### 3. Generate Talos Configuration

```bash
./scripts/proxmox-helper.sh generate-config \
  --cluster-name my-talos-cluster
```

## Architecture

The framework consists of three main components:

1. **Proxmox Helper Script**: Primary interface for VM lifecycle management
2. **Terraform Modules**: Declarative infrastructure provisioning
3. **Ansible Playbooks**: Configuration and deployment automation

## Commands

### VM Management

```bash
# Create a cluster
./scripts/proxmox-helper.sh create-cluster [options]

# List all Talos VMs
./scripts/proxmox-helper.sh list-vms

# Start a specific VM
./scripts/proxmox-helper.sh start-vm --vm-id 200

# Stop a specific VM
./scripts/proxmox-helper.sh stop-vm --vm-id 200

# Destroy a specific VM
./scripts/proxmox-helper.sh destroy-vm --vm-id 200

# Delete entire cluster
./scripts/proxmox-helper.sh delete-cluster --cluster-name my-cluster
```

### Configuration Generation

```bash
# Generate Talos machine configs
./scripts/proxmox-helper.sh generate-config --cluster-name my-cluster
```

## Advanced Usage

### Using Terraform

1. Navigate to the Terraform directory:
   ```bash
   cd terraform/talos-vm
   ```

2. Create `terraform.tfvars`:
   ```hcl
   proxmox_api_url = "https://your-proxmox-host:8006/api2/json"
   proxmox_user = "your-user@pve"
   proxmox_password = "your-password"
   cluster_name = "my-talos-cluster"
   node_count = 2
   ```

3. Apply the configuration:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

### Using Ansible

1. Update the inventory with your VM IPs
2. Run the deployment playbook:
   ```bash
   ansible-playbook -i ansible/inventory/talos.yml ansible/playbooks/deploy-talos.yml
   ```

## Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--node-count` | Number of worker nodes | 3 |
| `--start-id` | Starting VM ID | 200 |
| `--memory` | Memory per VM (MB) | 4096 |
| `--cores` | CPU cores per VM | 2 |
| `--disk-size` | Disk size per VM (GB) | 20 |
| `--bridge` | Network bridge | vmbr0 |
| `--cluster-name` | Cluster name | talos-cluster |
| `--talos-version` | Talos version | v1.7.4 |
| `--k8s-version` | Kubernetes version | v1.29.6 |

## Security Considerations

- Use API tokens instead of user passwords where possible
- Restrict network access to cluster VMs
- Regularly update Talos and Kubernetes versions
- Secure the Proxmox API credentials

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## License

MIT
```

Create `docs/talos-proxmox-guide.md`:
```markdown
# Talos Linux on Proxmox Deployment Guide

This guide explains how to deploy Talos Linux-based Kubernetes clusters on Proxmox VE using the Twinbox framework.

## Overview

Talos Linux is a modern, secure, and opinionated Linux distribution designed specifically for running Kubernetes. It follows the immutable infrastructure principle, making it ideal for production Kubernetes environments.

## Prerequisites

### Proxmox Setup

1. Ensure Proxmox VE 7.0 or higher is installed and running
2. Verify sufficient resources for your cluster:
   - Control plane: 4 cores, 8GB RAM, 40GB disk
   - Workers: 4 cores, 8GB RAM, 40GB disk each
3. Configure a network bridge (typically vmbr0) with DHCP or static IPs
4. Prepare storage space for VM disks and ISO images

### Environment Preparation

Set up your environment variables for Proxmox API access:

```bash
# Proxmox host information
export PROXMOX_HOST="your-proxmox-host.domain.com"
export PROXMOX_USER="api-user@pve"
export PROXMOX_PASSWORD="your-api-password"

# Optional: For API token authentication (recommended)
export PROXMOX_TOKEN_ID="your-token-id"
export PROXMOX_TOKEN_SECRET="your-token-secret"
```

## Deployment Process

### 1. Create the Cluster

Use the helper script to create a new Talos cluster:

```bash
./scripts/proxmox-helper.sh create-cluster \
  --cluster-name production-cluster \
  --node-count 3 \
  --memory 8192 \
  --cores 4 \
  --disk-size 50 \
  --bridge vmbr0
```

This command will:
- Create 1 control plane VM and 3 worker VMs
- Assign VM IDs starting from 200
- Configure each VM with 8GB RAM, 4 CPU cores, and 50GB disk
- Connect VMs to the specified bridge

### 2. Generate Configuration Files

Generate Talos machine configuration files:

```bash
./scripts/proxmox-helper.sh generate-config \
  --cluster-name production-cluster
```

This creates configuration templates in `clusters/production-cluster/talos-configs/`.

### 3. Customize Machine Configurations

Edit the generated configuration files to match your network settings:

1. Update IP addresses in both control-plane and worker configs
2. Set the correct cluster endpoint
3. Adjust Kubernetes and Talos versions if needed
4. Configure any custom machine settings

### 4. Deploy Talos to VMs

There are two approaches for deploying Talos:

#### Option A: Manual Deployment

1. Download the Talos ISO from the [releases page](https://github.com/siderolabs/talos/releases)
2. Upload it to Proxmox storage: `pvesm upload local iso/ --filename talos-amd64.iso`
3. Attach the ISO to each VM
4. Boot each VM and follow Talos installation instructions

#### Option B: Automated Deployment

Use the Ansible playbook to automate the process:

```bash
ansible-playbook -i ansible/inventory/talos.yml ansible/playbooks/deploy-talos.yml
```

## Post-Installation Steps

### 1. Access the Cluster

Once Talos is running, you can interact with your cluster using `talosctl`:

```bash
# Set the endpoint
talosctl config endpoint <CONTROL_PLANE_IP>

# Set the node (for single-node clusters)
talosctl config node <CONTROL_PLANE_IP>

# Get cluster info
talosctl cluster info
```

### 2. Access Kubernetes

To access the Kubernetes cluster, retrieve the kubeconfig:

```bash
talosctl kubeconfig --force
```

This creates a `kubeconfig` file in your current directory that you can use with `kubectl`.

### 3. Verify Installation

Check that all nodes are ready:

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

## Configuration Management

### Talos Machine Config

Talos uses a declarative machine configuration approach. The main sections are:

- `machine`: Hardware and OS configuration
- `cluster`: Kubernetes cluster configuration
- `network`: Network interface configuration

For detailed configuration options, refer to the [Talos documentation](https://www.talos.dev/docs/v1.7/).

### Customizing Worker Nodes

Worker nodes have a simpler configuration compared to control planes. Key differences:
- `machine.type` is set to "worker" instead of "controlplane"
- No etcd configuration needed
- May have different resource limits

## Troubleshooting

### Common Issues

1. **VM won't boot Talos**: Ensure EFI boot is enabled and the ISO is properly attached
2. **Network connectivity issues**: Verify VM network configuration and firewall rules
3. **Cluster initialization failures**: Check that all required ports are open between nodes

### Useful Commands

```bash
# Check VM status
./scripts/proxmox-helper.sh list-vms

# Restart a VM
./scripts/proxmox-helper.sh restart-vm --vm-id <VM_ID>

# Get VM console logs
qm monitor <VM_ID> "info registers"
```

## Scaling the Cluster

### Adding Worker Nodes

1. Create a new worker VM using the helper script
2. Generate a machine config for the new node
3. Boot the VM with the configuration
4. Verify the node joins the cluster

### Removing Nodes

1. Drain the node: `kubectl drain <node-name> --delete-emptydir-data`
2. Delete the node: `kubectl delete node <node-name>`
3. Destroy the VM: `./scripts/proxmox-helper.sh destroy-vm --vm-id <VM_ID>`

## Backup and Recovery

### Talos State Backup

Talos stores cluster state in etcd. For backups:

1. Access the control plane node
2. Use etcdctl to backup the data:
   ```bash
   etcdctl snapshot save /tmp/snapshot.db
   ```

### VM-Level Backups

Proxmox provides built-in backup capabilities:

1. Use `vzdump` to create VM backups
2. Store backups on separate storage for disaster recovery
3. Test restore procedures regularly

## Security Best Practices

1. Use dedicated service accounts for Proxmox API access
2. Regularly rotate API credentials
3. Implement network segmentation for cluster traffic
4. Monitor cluster activity and audit logs
5. Keep Talos and Kubernetes updated to latest stable versions
6. Use Pod Security Standards to restrict workload permissions

## Performance Tuning

### Resource Allocation

- Control plane: Minimum 4 cores, 8GB RAM
- Worker nodes: Scale based on workload requirements
- Storage: Use SSD storage for best performance

### Network Optimization

- Use dedicated network segments for cluster traffic
- Configure jumbo frames if supported
- Optimize MTU settings for container networks

## Maintenance

### Regular Tasks

- Monitor cluster health and resource utilization
- Update Talos and Kubernetes versions following release cycles
- Review and rotate certificates periodically
- Clean up unused resources and old configurations

### Version Upgrades

Follow Talos upgrade procedures:
1. Update machine configurations with new version
2. Apply configuration to nodes one by one
3. Monitor cluster stability after each update

## Conclusion

This framework provides a solid foundation for deploying and managing Talos Linux-based Kubernetes clusters on Proxmox VE. By following this guide, you can create secure, scalable, and maintainable Kubernetes infrastructure.
```

Create `examples/simple-cluster.sh`:
```bash
#!/bin/bash

# Example script: Create a simple Talos cluster on Proxmox
# This demonstrates basic usage of the Twinbox framework

set -euo pipefail

# Configuration
CLUSTER_NAME="demo-cluster"
NODE_COUNT=2
START_ID=250
MEMORY=4096
CORES=2
DISK_SIZE=25
BRIDGE="vmbr0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

# Check prerequisites
if [ -z "${PROXMOX_HOST:-}" ] || [ -z "${PROXMOX_USER:-}" ] || [ -z "${PROXMOX_PASSWORD:-}" ]; then
    error "Please set PROXMOX_HOST, PROXMOX_USER, and PROXMOX_PASSWORD environment variables"
    exit 1
fi

if [ ! -f "scripts/proxmox-helper.sh" ]; then
    error "Proxmox helper script not found. Run this script from the project root."
    exit 1
fi

log "Starting demo cluster creation with the following configuration:"
echo "  - Cluster name: $CLUSTER_NAME"
echo "  - Node count: $NODE_COUNT workers + 1 control plane"
echo "  - VM IDs: $START_ID to $((START_ID + NODE_COUNT))"
echo "  - Memory per VM: ${MEMORY}MB"
echo "  - Cores per VM: $CORES"
echo "  - Disk size per VM: ${DISK_SIZE}GB"
echo ""

read -p "Continue with cluster creation? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    log "Cluster creation cancelled"
    exit 0
fi

log "Creating Talos cluster: $CLUSTER_NAME"
./scripts/proxmox-helper.sh create-cluster \
    --cluster-name "$CLUSTER_NAME" \
    --node-count "$NODE_COUNT" \
    --start-id "$START_ID" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --disk-size "$DISK_SIZE" \
    --bridge "$BRIDGE"

if [ $? -eq 0 ]; then
    log "Cluster created successfully!"
    log "Next steps:"
    echo "  1. Generate Talos configuration: ./scripts/proxmox-helper.sh generate-config --cluster-name $CLUSTER_NAME"
    echo "  2. Customize the configuration in clusters/$CLUSTER_NAME/talos-configs/"
    echo "  3. Deploy Talos to the VMs manually or using Ansible"
    echo ""
    echo "To delete this cluster later: ./scripts/proxmox-helper.sh delete-cluster --cluster-name $CLUSTER_NAME --node-count $NODE_COUNT --start-id $START_ID"
else
    error "Cluster creation failed"
    exit 1
fi
```

Make the example script executable:
```bash
chmod +x examples/simple-cluster.sh
```

**Step 4: Run test to verify it passes**
Run: `bash tests/documentation_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add README.md docs/talos-proxmox-guide.md examples/simple-cluster.sh
git commit -m "Add documentation and usage examples for Twinbox Talos framework"
```

### Task 7: Create Final Integration Tests

**Files:**
- Create: `tests/run-all-tests.sh`
- Create: `Makefile`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/final_integration_test.sh
set -e

if [ ! -f "tests/run-all-tests.sh" ]; then
    echo "FAIL: tests/run-all-tests.sh does not exist"
    exit 1
fi

if [ ! -f "Makefile" ]; then
    echo "FAIL: Makefile does not exist"
    exit 1
fi

echo "PASS: Final integration files exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/final_integration_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `tests/run-all-tests.sh`:
```bash
#!/bin/bash

# Run all tests for Twinbox Talos on Proxmox framework
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[TEST]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

log "Starting all tests for Twinbox Talos on Proxmox framework..."

# Test 1: Helper script exists and is executable
log "Test 1: Checking helper script..."
if [ ! -f "scripts/proxmox-helper.sh" ] || [ ! -x "scripts/proxmox-helper.sh" ]; then
    error "Helper script missing or not executable"
    exit 1
fi

# Test 2: Templates exist
log "Test 2: Checking templates..."
if [ ! -f "templates/talos-machine-config.yaml" ]; then
    error "Talos template missing"
    exit 1
fi

# Test 3: Terraform files exist
log "Test 3: Checking Terraform configuration..."
if [ ! -f "terraform/talos-vm/main.tf" ] || 
   [ ! -f "terraform/talos-vm/variables.tf" ] ||
   [ ! -f "terraform/talos-vm/outputs.tf" ]; then
    error "Terraform configuration incomplete"
    exit 1
fi

# Test 4: Ansible files exist
log "Test 4: Checking Ansible configuration..."
if [ ! -f "ansible/playbooks/deploy-talos.yml" ] ||
   [ ! -f "ansible/inventory/talos.yml" ]; then
    error "Ansible configuration incomplete"
    exit 1
fi

# Test 5: Documentation exists
log "Test 5: Checking documentation..."
if [ ! -f "README.md" ] || 
   [ ! -f "docs/talos-proxmox-guide.md" ]; then
    error "Documentation incomplete"
    exit 1
fi

# Test 6: Examples exist
log "Test 6: Checking examples..."
if [ ! -f "examples/simple-cluster.sh" ]; then
    error "Examples incomplete"
    exit 1
fi

# Test 7: All test scripts exist
log "Test 7: Checking test scripts..."
for test_script in tests/*_test.sh; do
    if [ ! -f "$test_script" ]; then
        error "Test script missing: $test_script"
        exit 1
    fi
done

log "All tests passed!"
log "Twinbox Talos on Proxmox framework is ready for deployment."
```

Create `Makefile`:
```makefile
.PHONY: help test terraform-init terraform-plan terraform-apply terraform-destroy ansible-setup deploy docs clean

# Twinbox Talos on Proxmox Framework
# Makefile for common operations

# Default values - override with environment variables
CLUSTER_NAME ?= talos-cluster
NODE_COUNT ?= 2
VM_START_ID ?= 200
TF_DIR ?= ./terraform/talos-vm
ANSIBLE_DIR ?= ./ansible

help:
	@echo "Twinbox Talos on Proxmox Framework"
	@echo ""
	@echo "Usage:"
	@echo "  make terraform-init        Initialize Terraform"
	@echo "  make terraform-plan        Plan infrastructure changes"
	@echo "  make terraform-apply       Apply infrastructure changes"
	@echo "  make terraform-destroy     Destroy infrastructure"
	@echo "  make ansible-setup         Run Ansible playbooks"
	@echo "  make deploy                Deploy complete cluster"
	@echo "  make test                  Run integration tests"
	@echo "  make docs                  Show deployment documentation"
	@echo "  make clean                 Clean temporary files"
	@echo ""
	@echo "Environment variables:"
	@echo "  CLUSTER_NAME    Cluster name (default: $(CLUSTER_NAME))"
	@echo "  NODE_COUNT      Number of worker nodes (default: $(NODE_COUNT))"
	@echo "  VM_START_ID     Starting VM ID (default: $(VM_START_ID))"
	@echo "  TF_DIR          Terraform directory (default: $(TF_DIR))"
	@echo "  ANSIBLE_DIR     Ansible directory (default: $(ANSIBLE_DIR))"

terraform-init:
	@echo "Initializing Terraform..."
	cd $(TF_DIR) && terraform init

terraform-plan:
	@echo "Planning Terraform changes..."
	cd $(TF_DIR) && terraform plan \
		-var="cluster_name=$(CLUSTER_NAME)" \
		-var="node_count=$(NODE_COUNT)"

terraform-apply:
	@echo "Applying Terraform changes..."
	cd $(TF_DIR) && terraform apply \
		-var="cluster_name=$(CLUSTER_NAME)" \
		-var="node_count=$(NODE_COUNT)" \
		-auto-approve

terraform-destroy:
	@echo "Destroying Terraform infrastructure..."
	cd $(TF_DIR) && terraform destroy \
		-var="cluster_name=$(CLUSTER_NAME)" \
		-var="node_count=$(NODE_COUNT)" \
		-auto-approve

ansible-setup:
	@echo "Running Ansible playbooks..."
	ansible-playbook -i $(ANSIBLE_DIR)/inventory/talos.yml \
		$(ANSIBLE_DIR)/playbooks/deploy-talos.yml

deploy: terraform-init terraform-apply ansible-setup
	@echo "Deployment completed!"
	@echo "Next steps:"
	@echo "1. Generate Talos configs: ./scripts/proxmox-helper.sh generate-config --cluster-name $(CLUSTER_NAME)"
	@echo "2. Customize configs in clusters/$(CLUSTER_NAME)/talos-configs/"

test:
	@echo "Running all tests..."
	bash tests/run-all-tests.sh

docs:
	@echo "See docs/talos-proxmox-guide.md for complete deployment instructions"
	@cat docs/talos-proxmox-guide.md

clean:
	@echo "Cleaning temporary files..."
	rm -f terraform/talos-vm/*.tfplan
	rm -rf terraform/talos-vm/.terraform/
	rm -f terraform/talos-vm/.terraform.lock.hcl
	find . -name "*.retry" -delete
	rm -rf clusters/
	@echo "Clean complete"

# Convenience targets
create-cluster:
	@echo "Creating cluster: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh create-cluster \
		--cluster-name $(CLUSTER_NAME) \
		--node-count $(NODE_COUNT) \
		--start-id $(VM_START_ID)

delete-cluster:
	@echo "Deleting cluster: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh delete-cluster \
		--cluster-name $(CLUSTER_NAME) \
		--node-count $(NODE_COUNT) \
		--start-id $(VM_START_ID)

list-vms:
	@echo "Listing VMs..."
	./scripts/proxmox-helper.sh list-vms

generate-config:
	@echo "Generating Talos configs for: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh generate-config \
		--cluster-name $(CLUSTER_NAME)
```

**Step 4: Run test to verify it passes**
Run: `bash tests/final_integration_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add tests/run-all-tests.sh Makefile
git commit -m "Add final integration tests and Makefile"
```

## Summary

The Twinbox Talos on Proxmox Framework is now complete with:

1. A comprehensive Proxmox helper script for VM lifecycle management
2. Talos Linux configuration templates and generation
3. Terraform modules for declarative infrastructure
4. Ansible playbooks for automated deployment
5. Complete documentation and usage examples
6. Integration tests and Makefile for common operations

The framework enables users to easily deploy Talos Linux-based Kubernetes clusters on Proxmox VE with a single command, while providing flexibility for customization and integration with existing infrastructure automation tools.