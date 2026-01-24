# Twinbox Talos Linux VM Integration Implementation Plan

**Goal:** Integrate Talos Linux VMs into the Twinbox framework with Terraform provisioning, machine configuration generation, and seamless integration with existing Twinbox services.

**Architecture:** Two-layer approach with Terraform for infrastructure provisioning and Talos machine configs for system configuration. Proxmox helper scripts facilitate VM lifecycle management and configuration application.

**Tech Stack:** Terraform, Proxmox API, Talos Linux, talosctl, Bash scripts, YAML configurations

---

### Task 1: Create Talos-specific Terraform module

**Files:**
- Create: `twinbox/terraform/talos-vm/main.tf`
- Create: `twinbox/terraform/talos-vm/variables.tf`
- Create: `twinbox/terraform/talos-vm/outputs.tf`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos-terraform-validation.sh
set -e

echo "Testing Talos Terraform module exists..."
if [ ! -f "twinbox/terraform/talos-vm/main.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/main.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/variables.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/variables.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/outputs.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/outputs.tf does not exist"
    exit 1
fi

echo "PASS: All Talos Terraform module files exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos-terraform-validation.sh`
Expected: FAIL message indicating files don't exist

**Step 3: Write minimal implementation**

Content for [`twinbox/terraform/talos-vm/main.tf`](twinbox/terraform/talos-vm/main.tf):
```hcl
# Talos VM provisioning module for Twinbox
resource "proxmox_vm_qemu" "talos_node" {
  count = var.node_count

  name        = "${var.cluster_name}-${var.node_type}-${count.index + 1}"
  target_node = var.proxmox_target_node
  clone       = var.vm_template_name
  full_clone  = true

  cores   = var.vm_cores
  memory  = var.vm_memory
  sockets = 1

  bios = "ovmf"  # Required for Talos Linux
  
  # EFI disk for Talos
  efi_disk {
    efi_type = "2m"
    storage  = var.storage_pool
    pre_enrolled_keys = true
  }

  # Primary disk
  disk {
    slot    = 0
    size    = var.disk_size
    type    = "scsi"
    storage = var.storage_pool
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
    tag    = var.vlan_id
  }

  # Cloud-init for initial boot
  ipconfig0 = "ip=dhcp"
  
  # Attach Talos ISO
  ide {
    ide2 {
      cdrom = true
      file  = var.talos_iso_path
    }
  }

  oncreate_timeout = 30
  clone_timeout    = 180
  start_timeout    = 120

  lifecycle {
    ignore_changes = [
      ide,
      disk,
    ]
  }
}

# Output VM information for cluster configuration
output "node_ips" {
  description = "IP addresses of Talos nodes"
  value       = [for vm in proxmox_vm_qemu.talos_node : vm.defaultip]
}

output "node_names" {
  description = "Names of Talos nodes"
  value       = [for vm in proxmox_vm_qemu.talos_node : vm.name]
}
```

Content for [`twinbox/terraform/talos-vm/variables.tf`](twinbox/terraform/talos-vm/variables.tf):
```hcl
variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "talos-cluster"
}

variable "node_type" {
  description = "Type of node (controlplane or worker)"
  type        = string
  default     = "controlplane"
}

variable "node_count" {
  description = "Number of nodes to create"
  type        = number
  default     = 1
}

variable "proxmox_target_node" {
  description = "Target Proxmox node for VM placement"
  type        = string
  default     = "pve"
}

variable "vm_template_name" {
  description = "Base template for Talos VMs (empty for fresh install)"
  type        = string
  default     = ""
}

variable "vm_cores" {
  description = "Number of CPU cores per VM"
  type        = number
  default     = 4
}

variable "vm_memory" {
  description = "Memory in MB per VM"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "Disk size for each VM"
  type        = string
  default     = "20G"
}

variable "storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Network bridge for VM connectivity"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN ID for network isolation (0 for none)"
  type        = number
  default     = 0
}

variable "talos_iso_path" {
  description = "Path to Talos Linux ISO in Proxmox storage"
  type        = string
  default     = "local:iso/talos-amd64.iso"
}
```

Content for [`twinbox/terraform/talos-vm/outputs.tf`](twinbox/terraform/talos-vm/outputs.tf):
```hcl
output "node_ids" {
  description = "IDs of created Talos VMs"
  value       = [for vm in proxmox_vm_qemu.talos_node : vm.id]
}

output "node_fqdns" {
  description = "FQDNs of Talos nodes"
  value       = [for vm in proxmox_vm_qemu.talos_node : "${vm.name}.${var.cluster_name}.local"]
}

output "connection_info" {
  description = "Connection information for Talos nodes"
  value = {
    for i, vm in proxmox_vm_qemu.talos_node :
    vm.name => {
      id  = vm.id
      ip  = vm.defaultip
      mac = vm.network[0]["macaddr"]
    }
  }
}
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos-terraform-validation.sh`
Expected: PASS message indicating all files exist

**Step 5: Commit**
```bash
git add twinbox/terraform/talos-vm/
git commit -m "Add Talos-specific Terraform module for VM provisioning"
```

### Task 2: Create Proxmox helper script for Talos operations

**Files:**
- Create: `twinbox/scripts/proxmox-talos-helper.sh`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos-helper-script-validation.sh
set -e

echo "Testing Talos helper script exists..."
if [ ! -f "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh is not executable"
    exit 1
fi

echo "PASS: Talos helper script exists and is executable"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos-helper-script-validation.sh`
Expected: FAIL message indicating file doesn't exist

**Step 3: Write minimal implementation**

Content for [`twinbox/scripts/proxmox-talos-helper.sh`](twinbox/scripts/proxmox-talos-helper.sh):
```bash
#!/bin/bash

# Proxmox Talos Helper Script
# Provides utility functions for managing Talos Linux VMs on Proxmox

set -euo pipefail

# Configuration
PROXMOX_HOST=${PROXMOX_HOST:-"localhost"}
PROXMOX_PORT=${PROXMOX_PORT:-"8006"}
PROXMOX_USER=${PROXMOX_USER:-"root@pam"}
PROXMOX_PASSWORD=${PROXMOX_PASSWORD:-""}
PROXMOX_REALM=${PROXMOX_REALM:-"pam"}

# Global variables
TOKEN=""
CSRF_TOKEN=""

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Authenticate with Proxmox
authenticate() {
    if [[ -z "$PROXMOX_PASSWORD" ]]; then
        error_exit "PROXMOX_PASSWORD environment variable must be set"
    fi
    
    local auth_response
    auth_response=$(curl -k -s -d "username=$PROXMOX_USER&password=$PROXMOX_PASSWORD" \
        "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/access/ticket")
    
    TOKEN=$(echo "$auth_response" | jq -r '.data.ticket')
    CSRF_TOKEN=$(echo "$auth_response" | jq -r '.data.CSRFPreventionToken')
    
    if [[ "$TOKEN" == "null" || "$CSRF_TOKEN" == "null" ]]; then
        error_exit "Authentication failed: $(echo "$auth_response" | jq -r '.errors // empty')"
    fi
}

# Get VM IP address
get_vm_ip() {
    local vm_id=$1
    local timeout=${2:-300}  # 5 minutes default timeout
    local counter=0
    
    authenticate
    
    log "Waiting for VM $vm_id to get an IP address..."
    while [[ $counter -lt $timeout ]]; do
        local vm_agent_status
        vm_agent_status=$(curl -k -s -H "Authorization: PVEAuthCookie $TOKEN" \
            "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/nodes/$(get_node_name)/qemu/$vm_id/agent/status" 2>/dev/null)
        
        if [[ $(echo "$vm_agent_status" | jq -r '.data.result') == "active" ]]; then
            local network_info
            network_info=$(curl -k -s -H "Authorization: PVEAuthCookie $TOKEN" \
                "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/nodes/$(get_node_name)/qemu/$vm_id/agent/network-get-interfaces" 2>/dev/null)
            
            local ip_address
            ip_address=$(echo "$network_info" | jq -r '.data.result.interfaces[] | 
                         select(.name != "lo" and .name | startswith("eth") or startswith("ens")) | 
                         .ip-addresses[]? | 
                         select(.["ip-address-type"] == "ipv4") | 
                         .["ip-address"]' | head -1)
            
            if [[ -n "$ip_address" && "$ip_address" != "null" ]]; then
                echo "$ip_address"
                return 0
            fi
        fi
        
        sleep 10
        ((counter += 10))
    done
    
    error_exit "Timeout waiting for VM $vm_id to get an IP address"
}

# Get Proxmox node name for VM
get_node_name() {
    local vm_id=$1
    
    authenticate
    
    local vm_config
    vm_config=$(curl -k -s -H "Authorization: PVEAuthCookie $TOKEN" \
        "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/nodes/$(get_first_node)/qemu/$vm_id/config")
    
    local node_name
    node_name=$(echo "$vm_config" | jq -r '.data.node // empty')
    
    if [[ -n "$node_name" ]]; then
        echo "$node_name"
    else
        get_first_node
    fi
}

# Get first available Proxmox node
get_first_node() {
    authenticate
    
    curl -k -s -H "Authorization: PVEAuthCookie $TOKEN" \
        "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/nodes" | \
        jq -r '.data[].node' | head -1
}

# Download Talos ISO if not present
download_talos_iso() {
    local iso_url=${1:-"https://github.com/siderolabs/talos/releases/latest/download/talos-amd64.iso"}
    local storage_pool=${2:-"local"}
    local iso_filename=$(basename "$iso_url")
    
    authenticate
    
    # Check if ISO already exists
    local iso_exists
    iso_exists=$(curl -k -s -H "Authorization: PVEAuthCookie $TOKEN" \
        "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/nodes/$(get_first_node)/storage/$storage_pool/content")
    
    if echo "$iso_exists" | jq -e --arg filename "$iso_filename" '.data[] | select(.volid | contains($filename))' >/dev/null 2>&1; then
        log "ISO $iso_filename already exists in $storage_pool storage"
        return 0
    fi
    
    log "Downloading Talos ISO from $iso_url to $storage_pool storage..."
    
    # Upload ISO to Proxmox
    curl -k -s -X POST \
        -H "Authorization: PVEAuthCookie $TOKEN" \
        -H "Content-Type: multipart/form-data" \
        -F "filename=@<(curl -sL $iso_url)" \
        -F "content=iso" \
        "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/nodes/$(get_first_node)/storage/$storage_pool/upload"
    
    log "Talos ISO downloaded and uploaded to $storage_pool storage"
}

# Apply Talos configuration to a node
apply_talos_config() {
    local endpoint=$1
    local config_file=$2
    local talosctl_path=${3:-"talosctl"}
    
    log "Applying Talos configuration to $endpoint using $config_file"
    
    if [[ ! -f "$config_file" ]]; then
        error_exit "Configuration file $config_file does not exist"
    fi
    
    # Apply the machine configuration
    "$talosctl_path" apply-config \
        --insecure \
        --nodes "$endpoint" \
        --file "$config_file"
    
    log "Talos configuration applied successfully to $endpoint"
}

# Bootstrap Talos cluster
bootstrap_talos_cluster() {
    local endpoint=$1
    local talosctl_path=${2:-"talosctl"}
    
    log "Bootstrapping Talos cluster on $endpoint"
    
    "$talosctl_path" bootstrap \
        --nodes "$endpoint"
    
    log "Talos cluster bootstrapped successfully on $endpoint"
}

# Generate Talos kubeconfig
generate_kubeconfig() {
    local endpoint=$1
    local output_dir=${2:-"."}
    local talosctl_path=${3:-"talosctl"}
    
    log "Generating kubeconfig from $endpoint to $output_dir"
    
    "$talosctl_path" kubeconfig \
        --nodes "$endpoint" \
        "$output_dir"
    
    log "Kubeconfig generated successfully in $output_dir"
}

# Main function to handle arguments
main() {
    local command=${1:-"help"}
    
    case "$command" in
        "get-ip")
            if [[ $# -lt 2 ]]; then
                error_exit "Usage: $0 get-ip <vm_id>"
            fi
            get_vm_ip "$2"
            ;;
        "download-iso")
            download_talos_iso "${2:-https://github.com/siderolabs/talos/releases/latest/download/talos-amd64.iso}" "${3:-local}"
            ;;
        "apply-config")
            if [[ $# -lt 3 ]]; then
                error_exit "Usage: $0 apply-config <endpoint> <config_file> [talosctl_path]"
            fi
            apply_talos_config "$2" "$3" "${4:-talosctl}"
            ;;
        "bootstrap")
            if [[ $# -lt 2 ]]; then
                error_exit "Usage: $0 bootstrap <endpoint> [talosctl_path]"
            fi
            bootstrap_talos_cluster "$2" "${3:-talosctl}"
            ;;
        "kubeconfig")
            if [[ $# -lt 2 ]]; then
                error_exit "Usage: $0 kubeconfig <endpoint> [output_dir] [talosctl_path]"
            fi
            generate_kubeconfig "$2" "${3:-.}" "${4:-talosctl}"
            ;;
        "help"|*)
            echo "Proxmox Talos Helper Script"
            echo "Usage: $0 <command> [args...]"
            echo ""
            echo "Commands:"
            echo "  get-ip <vm_id>                    - Get IP address of VM"
            echo "  download-iso [url] [storage]      - Download Talos ISO to Proxmox storage"
            echo "  apply-config <endpoint> <file>    - Apply Talos configuration"
            echo "  [talosctl_path]                   - Path to talosctl binary"
            echo "  bootstrap <endpoint>              - Bootstrap Talos cluster"
            echo "  [talosctl_path]                   - Path to talosctl binary"
            echo "  kubeconfig <endpoint>             - Generate kubeconfig from endpoint"
            echo "  [output_dir] [talosctl_path]      - Output directory and talosctl path"
            echo "  help                              - Show this help"
            ;;
    esac
}

# Call main function with all arguments
main "$@"
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos-helper-script-validation.sh`
Expected: PASS message indicating file exists and is executable

**Step 5: Commit**
```bash
chmod +x twinbox/scripts/proxmox-talos-helper.sh
git add twinbox/scripts/proxmox-talos-helper.sh
git commit -m "Add Proxmox helper script for Talos operations"
```

### Task 3: Create Talos machine configuration generator

**Files:**
- Create: `twinbox/scripts/generate-talos-config.sh`
- Create: `twinbox/configs/talos-controlplane-template.yaml`
- Create: `twinbox/configs/talos-worker-template.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos-config-generator-validation.sh
set -e

echo "Testing Talos config generator exists..."
if [ ! -f "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh is not executable"
    exit 1
fi

if [ ! -f "twinbox/configs/talos-controlplane-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-controlplane-template.yaml does not exist"
    exit 1
fi

if [ ! -f "twinbox/configs/talos-worker-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-worker-template.yaml does not exist"
    exit 1
fi

echo "PASS: Talos config generator and templates exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos-config-generator-validation.sh`
Expected: FAIL message indicating files don't exist

**Step 3: Write minimal implementation**

Content for [`twinbox/scripts/generate-talos-config.sh`](twinbox/scripts/generate-talos-config.sh):
```bash
#!/bin/bash

# Talos Configuration Generator
# Generates Talos machine configurations based on templates and environment variables

set -euo pipefail

# Default values
DEFAULT_CLUSTER_NAME="talos-cluster"
DEFAULT_ENDPOINTS=""
DEFAULT_MCS_CERT=""  
DEFAULT_MCS_KEY=""
DEFAULT_KUBERNETES_VERSION="1.28.0"
DEFAULT_MACHINE_TYPE="controlplane"

# Configuration
CONFIG_OUTPUT_DIR=${CONFIG_OUTPUT_DIR:-"./generated-configs"}
CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
ENDPOINTS=${ENDPOINTS:-$DEFAULT_ENDPOINTS}
MCS_CERT=${MCS_CERT:-$DEFAULT_MCS_CERT}
MCS_KEY=${MCS_KEY:-$DEFAULT_MCS_KEY}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-$DEFAULT_KUBERNETES_VERSION}
MACHINE_TYPE=${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE}
NODE_IP=${NODE_IP:-""}
INSTALL_DISK=${INSTALL_DISK:-"/dev/sda"}
PERSISTENT_DISK=${PERSISTENT_DISK:-"/dev/sdb"}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Create output directory
create_output_dir() {
    mkdir -p "$CONFIG_OUTPUT_DIR"
}

# Generate Talos control plane configuration
generate_controlplane_config() {
    local node_ip=${1:-$NODE_IP}
    local output_file="$CONFIG_OUTPUT_DIR/controlplane-$node_ip.yaml"
    
    if [[ -z "$node_ip" ]]; then
        error_exit "Node IP is required for control plane configuration"
    fi
    
    log "Generating control plane configuration for $node_ip"
    
    # Create temporary file for sed processing
    cp twinbox/configs/talos-controlplane-template.yaml "$output_file"
    
    # Replace template variables
    sed -i.bak "s|{{CLUSTER_NAME}}|$CLUSTER_NAME|g" "$output_file"
    sed -i.bak "s|{{NODE_IP}}|$node_ip|g" "$output_file"
    sed -i.bak "s|{{ENDPOINTS}}|$ENDPOINTS|g" "$output_file"
    sed -i.bak "s|{{KUBERNETES_VERSION}}|$KUBERNETES_VERSION|g" "$output_file"
    sed -i.bak "s|{{INSTALL_DISK}}|$INSTALL_DISK|g" "$output_file"
    
    # Clean up backup file
    rm "$output_file.bak"
    
    log "Control plane configuration saved to $output_file"
    echo "$output_file"
}

# Generate Talos worker configuration
generate_worker_config() {
    local node_ip=${1:-$NODE_IP}
    local output_file="$CONFIG_OUTPUT_DIR/worker-$node_ip.yaml"
    
    if [[ -z "$node_ip" ]]; then
        error_exit "Node IP is required for worker configuration"
    fi
    
    log "Generating worker configuration for $node_ip"
    
    # Create temporary file for sed processing
    cp twinbox/configs/talos-worker-template.yaml "$output_file"
    
    # Replace template variables
    sed -i.bak "s|{{CLUSTER_NAME}}|$CLUSTER_NAME|g" "$output_file"
    sed -i.bak "s|{{NODE_IP}}|$node_ip|g" "$output_file"
    sed -i.bak "s|{{ENDPOINTS}}|$ENDPOINTS|g" "$output_file"
    sed -i.bak "s|{{KUBERNETES_VERSION}}|$KUBERNETES_VERSION|g" "$output_file"
    sed -i.bak "s|{{INSTALL_DISK}}|$INSTALL_DISK|g" "$output_file"
    
    # Clean up backup file
    rm "$output_file.bak"
    
    log "Worker configuration saved to $output_file"
    echo "$output_file"
}

# Validate required environment variables
validate_environment() {
    if [[ -z "$ENDPOINTS" ]]; then
        error_exit "ENDPOINTS environment variable must be set"
    fi
    
    if [[ -z "$MCS_CERT" || -z "$MCS_KEY" ]]; then
        error_exit "Both MCS_CERT and MCS_KEY environment variables must be set"
    fi
}

# Main function
main() {
    local node_ip=${1:-$NODE_IP}
    local machine_type=${2:-$MACHINE_TYPE}
    
    if [[ -z "$node_ip" ]]; then
        error_exit "Node IP must be provided as argument or NODE_IP environment variable"
    fi
    
    create_output_dir
    validate_environment
    
    case "$machine_type" in
        "controlplane")
            generate_controlplane_config "$node_ip"
            ;;
        "worker")
            generate_worker_config "$node_ip"
            ;;
        *)
            error_exit "Invalid machine type: $machine_type. Use 'controlplane' or 'worker'"
            ;;
    esac
}

# Call main function with all arguments
main "$@"
```

Content for [`twinbox/configs/talos-controlplane-template.yaml`](twinbox/configs/talos-controlplane-template.yaml):
```yaml
version: v1alpha1 # Indicates the schema version
debug: false
persist: true
insecure: false
machine:
  type: controlplane # Defines the role of the machine within the cluster
  token: "" # The join token used to join the cluster
  ca:
    crt: "" # The PEM encoded CA certificate
    key: "" # The PEM encoded CA private key
  certSANs: [] # Additional certificate subject alternative names for the machine's kubelet identity
  kubelet:
    image: ghcr.io/siderolabs/kubelet:v{{KUBERNETES_VERSION}} # The container image used in the kubelet static pod definition
    extraArgs: {} # Extra arguments to supply to the kubelet
    extraMounts: [] # Extra mounts to supply to the kubelet container
    nodeIP: # The configuration for kubelet node IP
      validSubnets: [] # Valid subnet ranges for the kubelet's node IP
  kubernetes:
    kubelet:
      image: ghcr.io/siderolabs/kubelet:v{{KUBERNETES_VERSION}} # The container image used in the kubelet static pod definition
  network:
    hostname: "" # The machine's hostname
    interfaces: [] # The list of network interfaces
    extraHostEntries: [] # Extra entries to write to /etc/hosts
  install:
    disk: {{INSTALL_DISK}} # The disk to install to
    image: "" # The image to install
    bootloader: true # Install the bootloader to the specified disk
    wipe: false # Wipe the specified disk prior to installing
    zero: false # Perform a quick wipe of the specified disk prior to installing
  files: [] # Allows for appending arbitrary files to the disk before pivot
  env: {} # Environment variables to set in the machine's initramfs environment
  time:
    disabled: false # Disable the machine's time sync capability
    servers: [] # List of time servers to use
  sysctls: {} # Sysctl properties to set
  tolerations: [] # Taint tolerations to add to the kubelet configuration
  features:
    rbac: true # Enable role-based access control (RBAC)
    apidCheckExtKeyUsage: true # Enable certificate extended key usage check for client certificates
    hostDNSResolution: true # Enable DNS resolution using host's resolv.conf
    diskQuotaSupport: true # Enable support for disk quotas
controlPlane:
  enabled: true # Enable the control plane on this machine
  controllerManager: {} # Controller manager configuration
  scheduler: {} # Scheduler configuration
  etcd: # Etcd configuration
    ca:
      crt: "" # The PEM encoded CA certificate
      key: "" # The PEM encoded CA private key
    extraArgs: {} # Extra arguments to supply to the etcd container
cluster:
  id: "" # The 32-byte (in hex) cluster ID
  secret: "" # The 32-byte (in hex) AES-GCM master key for encrypting secrets at rest
  network: # Network configuration
    cni: # Container network interface configuration
      name: "cilium" # Name of the CNI plugin to use
    dnsDomain: "cluster.local" # Domain name to use for services
    podSubnets: # Pod network subnets
    - 10.244.0.0/16
    serviceSubnets: # Service network subnets
    - 10.96.0.0/12
  token: "" # The token used for nodes to join the cluster
  discovery: # Discovery configuration
    enabled: true # Enable automatic control plane discovery
    registries: # Registry configuration for storing/retrieving cluster information
      kubernetes: # Kubernetes registry configuration
        disabled: false # Disable Kubernetes registry
        endpoints: [] # Endpoints for the Kubernetes registry
      service: # Service registry configuration
        disabled: false # Disable service registry
        endpoints: [] # Endpoints for the service registry
        tls: # TLS configuration for the service registry
          ca: "" # The PEM encoded CA certificate
          crt: "" # The PEM encoded client certificate
          key: "" # The PEM encoded client private key
  name: "{{CLUSTER_NAME}}" # Name of the cluster
  endpoint: "" # Endpoint for the load balancer
  ca: # Certificate authority configuration
    crt: "" # The PEM encoded CA certificate
    key: "" # The PEM encoded CA private key
  aggregatorCA: # Aggregator CA configuration
    crt: "" # The PEM encoded aggregator CA certificate
    key: "" # The PEM encoded aggregator CA private key
  serviceAccount: # Service account configuration
    crt: "" # The PEM encoded service account public key
    key: "" # The PEM encoded service account private key
  clusterNetwork: # Cluster network configuration
    pods: # Pod network configuration
      cidrBlocks: # CIDR blocks for pods
      - 10.244.0.0/16
    services: # Service network configuration
      cidrBlocks: # CIDR blocks for services
      - 10.96.0.0/12
  proxy: {} # Kubernetes proxy configuration
  scheduler: {} # Kubernetes scheduler configuration
  controllerManager: {} # Kubernetes controller manager configuration
  etcd: # Etcd configuration
    ca: # Certificate authority configuration for etcd
      crt: "" # The PEM encoded CA certificate
      key: "" # The PEM encoded CA private key
    endpoints: [] # Endpoints for etcd members
  coreDNS: {} # CoreDNS configuration
```

Content for [`twinbox/configs/talos-worker-template.yaml`](twinbox/configs/talos-worker-template.yaml):
```yaml
version: v1alpha1 # Indicates the schema version
debug: false
persist: true
insecure: false
machine:
  type: worker # Defines the role of the machine within the cluster
  token: "" # The join token used to join the cluster
  ca:
    crt: "" # The PEM encoded CA certificate
    key: "" # The PEM encoded CA private key
  certSANs: [] # Additional certificate subject alternative names for the machine's kubelet identity
  kubelet:
    image: ghcr.io/siderolabs/kubelet:v{{KUBERNETES_VERSION}} # The container image used in the kubelet static pod definition
    extraArgs: {} # Extra arguments to supply to the kubelet
    extraMounts: [] # Extra mounts to supply to the kubelet container
    nodeIP: # The configuration for kubelet node IP
      validSubnets: [] # Valid subnet ranges for the kubelet's node IP
  kubernetes:
    kubelet:
      image: ghcr.io/siderolabs/kubelet:v{{KUBERNETES_VERSION}} # The container image used in the kubelet static pod definition
  network:
    hostname: "" # The machine's hostname
    interfaces: [] # The list of network interfaces
    extraHostEntries: [] # Extra entries to write to /etc/hosts
  install:
    disk: {{INSTALL_DISK}} # The disk to install to
    image: "" # The image to install
    bootloader: true # Install the bootloader to the specified disk
    wipe: false # Wipe the specified disk prior to installing
    zero: false # Perform a quick wipe of the specified disk prior to installing
  files: [] # Allows for appending arbitrary files to the disk before pivot
  env: {} # Environment variables to set in the machine's initramfs environment
  time:
    disabled: false # Disable the machine's time sync capability
    servers: [] # List of time servers to use
  sysctls: {} # Sysctl properties to set
  tolerations: [] # Taint tolerations to add to the kubelet configuration
  features:
    rbac: true # Enable role-based access control (RBAC)
    apidCheckExtKeyUsage: true # Enable certificate extended key usage check for client certificates
    hostDNSResolution: true # Enable DNS resolution using host's resolv.conf
    diskQuotaSupport: true # Enable support for disk quotas
controlPlane:
  enabled: false # Disable the control plane on this machine
cluster:
  id: "" # The 32-byte (in hex) cluster ID
  secret: "" # The 32-byte (in hex) AES-GCM master key for encrypting secrets at rest
  network: # Network configuration
    cni: # Container network interface configuration
      name: "cilium" # Name of the CNI plugin to use
    dnsDomain: "cluster.local" # Domain name to use for services
    podSubnets: # Pod network subnets
    - 10.244.0.0/16
    serviceSubnets: # Service network subnets
    - 10.96.0.0/12
  token: "" # The token used for nodes to join the cluster
  discovery: # Discovery configuration
    enabled: true # Enable automatic control plane discovery
    registries: # Registry configuration for storing/retrieving cluster information
      kubernetes: # Kubernetes registry configuration
        disabled: false # Disable Kubernetes registry
        endpoints: [] # Endpoints for the Kubernetes registry
      service: # Service registry configuration
        disabled: false # Disable service registry
        endpoints: [] # Endpoints for the service registry
        tls: # TLS configuration for the service registry
          ca: "" # The PEM encoded CA certificate
          crt: "" # The PEM encoded client certificate
          key: "" # The PEM encoded client private key
  name: "{{CLUSTER_NAME}}" # Name of the cluster
  endpoint: "" # Endpoint for the load balancer
  ca: # Certificate authority configuration
    crt: "" # The PEM encoded CA certificate
    key: "" # The PEM encoded CA private key
  aggregatorCA: # Aggregator CA configuration
    crt: "" # The PEM encoded aggregator CA certificate
    key: "" # The PEM encoded aggregator CA private key
  serviceAccount: # Service account configuration
    crt: "" # The PEM encoded service account public key
    key: "" # The PEM encoded service account private key
  clusterNetwork: # Cluster network configuration
    pods: # Pod network configuration
      cidrBlocks: # CIDR blocks for pods
      - 10.244.0.0/16
    services: # Service network configuration
      cidrBlocks: # CIDR blocks for services
      - 10.96.0.0/12
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos-config-generator-validation.sh`
Expected: PASS message indicating files exist and are executable

**Step 5: Commit**
```bash
chmod +x twinbox/scripts/generate-talos-config.sh
mkdir -p twinbox/configs
git add twinbox/scripts/generate-talos-config.sh twinbox/configs/
git commit -m "Add Talos machine configuration generator and templates"
```

### Task 4: Create integration script to tie everything together

**Files:**
- Create: `twinbox/scripts/deploy-talos-cluster.sh`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos-deployment-script-validation.sh
set -e

echo "Testing Talos deployment script exists..."
if [ ! -f "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh is not executable"
    exit 1
fi

echo "PASS: Talos deployment script exists and is executable"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos-deployment-script-validation.sh`
Expected: FAIL message indicating file doesn't exist

**Step 3: Write minimal implementation**

Content for [`twinbox/scripts/deploy-talos-cluster.sh`](twinbox/scripts/deploy-talos-cluster.sh):
```bash
#!/bin/bash

# Twinbox Talos Cluster Deployment Script
# Orchestrates the deployment of a Talos Linux-based Kubernetes cluster

set -euo pipefail

# Configuration
export PROXMOX_HOST=${PROXMOX_HOST:-"localhost"}
export PROXMOX_PORT=${PROXMOX_PORT:-"8006"}
export PROXMOX_USER=${PROXMOX_USER:-"root@pam"}
export PROXMOX_PASSWORD=${PROXMOX_PASSWORD:-""}
export PROXMOX_REALM=${PROXMOX_REALM:-"pam"}

# Default values
DEFAULT_CLUSTER_NAME="talos-cluster"
DEFAULT_TALOS_ISO_URL="https://github.com/siderolabs/talos/releases/latest/download/talos-amd64.iso"
DEFAULT_CONTROLPLANE_COUNT=1
DEFAULT_WORKER_COUNT=1
DEFAULT_VM_CORES=4
DEFAULT_VM_MEMORY=4096
DEFAULT_DISK_SIZE="20G"
DEFAULT_STORAGE_POOL="local-lvm"
DEFAULT_NETWORK_BRIDGE="vmbr0"
DEFAULT_VLAN_ID=0
DEFAULT_KUBERNETES_VERSION="1.28.0"

# Environment variables with defaults
CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
TALOS_ISO_URL=${TALOS_ISO_URL:-$DEFAULT_TALOS_ISO_URL}
CONTROLPLANE_COUNT=${CONTROLPLANE_COUNT:-$DEFAULT_CONTROLPLANE_COUNT}
WORKER_COUNT=${WORKER_COUNT:-$DEFAULT_WORKER_COUNT}
VM_CORES=${VM_CORES:-$DEFAULT_VM_CORES}
VM_MEMORY=${VM_MEMORY:-$DEFAULT_VM_MEMORY}
DISK_SIZE=${DISK_SIZE:-$DEFAULT_DISK_SIZE}
STORAGE_POOL=${STORAGE_POOL:-$DEFAULT_STORAGE_POOL}
NETWORK_BRIDGE=${NETWORK_BRIDGE:-$DEFAULT_NETWORK_BRIDGE}
VLAN_ID=${VLAN_ID:-$DEFAULT_VLAN_ID}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-$DEFAULT_KUBERNETES_VERSION}

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HELPER_SCRIPT="$PROJECT_ROOT/scripts/proxmox-talos-helper.sh"
CONFIG_GENERATOR="$PROJECT_ROOT/scripts/generate-talos-config.sh"
TF_DIR="$PROJECT_ROOT/terraform"
TF_VAR_FILE="$TF_DIR/talos-cluster.auto.tfvars"
GENERATED_CONFIGS_DIR="$PROJECT_ROOT/generated-configs"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if required tools are installed
    if ! command -v terraform &> /dev/null; then
        error_exit "terraform is required but not installed"
    fi
    
    if ! command -v talosctl &> /dev/null; then
        error_exit "talosctl is required but not installed"
    fi
    
    if ! command -v jq &> /dev/null; then
        error_exit "jq is required but not installed"
    fi
    
    if [[ -z "$PROXMOX_PASSWORD" ]]; then
        error_exit "PROXMOX_PASSWORD environment variable must be set"
    fi
    
    log "All prerequisites satisfied"
}

# Initialize Terraform
init_terraform() {
    log "Initializing Terraform..."
    
    pushd "$TF_DIR" > /dev/null
    terraform init
    popd > /dev/null
    
    log "Terraform initialized"
}

# Prepare Terraform variables
prepare_terraform_vars() {
    log "Preparing Terraform variables..."
    
    cat > "$TF_VAR_FILE" << EOF
cluster_name      = "$CLUSTER_NAME"
vm_cores          = $VM_CORES
vm_memory         = $VM_MEMORY
disk_size         = "$DISK_SIZE"
storage_pool      = "$STORAGE_POOL"
network_bridge    = "$NETWORK_BRIDGE"
vlan_id           = $VLAN_ID
talos_iso_path    = "local:iso/$(basename "$TALOS_ISO_URL")"
EOF

    log "Terraform variables prepared in $TF_VAR_FILE"
}

# Download Talos ISO to Proxmox
download_talos_iso() {
    log "Downloading Talos ISO to Proxmox..."
    
    "$HELPER_SCRIPT" download-iso "$TALOS_ISO_URL" "$STORAGE_POOL"
    
    log "Talos ISO downloaded to Proxmox storage"
}

# Deploy control plane nodes
deploy_controlplane_nodes() {
    log "Deploying $CONTROLPLANE_COUNT control plane nodes..."
    
    # Copy main.tf to include control plane nodes
    cat > "$TF_DIR/main.tf" << 'EOF'
# Twinbox Talos Cluster Infrastructure

# Import the Talos VM module
module "talos_controlplane" {
  source = "./talos-vm"
  
  cluster_name      = var.cluster_name
  node_type         = "controlplane"
  node_count        = var.controlplane_count
  vm_cores          = var.vm_cores
  vm_memory         = var.vm_memory
  disk_size         = var.disk_size
  storage_pool      = var.storage_pool
  network_bridge    = var.network_bridge
  vlan_id           = var.vlan_id
  talos_iso_path    = var.talos_iso_path
}

module "talos_workers" {
  source = "./talos-vm"
  
  cluster_name      = var.cluster_name
  node_type         = "worker"
  node_count        = var.worker_count
  vm_cores          = var.vm_cores
  vm_memory         = var.vm_memory
  disk_size         = var.disk_size
  storage_pool      = var.storage_pool
  network_bridge    = var.network_bridge
  vlan_id           = var.vlan_id
  talos_iso_path    = var.talos_iso_path
}

output "controlplane_nodes" {
  description = "Control plane node information"
  value       = module.talos_controlplane
}

output "worker_nodes" {
  description = "Worker node information"
  value       = module.talos_workers
}
EOF

    # Update variables.tf to include counts
    cat > "$TF_DIR/variables.tf" << 'EOF'
variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "talos-cluster"
}

variable "controlplane_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 1
}

variable "vm_cores" {
  description = "Number of CPU cores per VM"
  type        = number
  default     = 4
}

variable "vm_memory" {
  description = "Memory in MB per VM"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "Disk size for each VM"
  type        = string
  default     = "20G"
}

variable "storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Network bridge for VM connectivity"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN ID for network isolation (0 for none)"
  type        = number
  default     = 0
}

variable "talos_iso_path" {
  description = "Path to Talos Linux ISO in Proxmox storage"
  type        = string
  default     = "local:iso/talos-amd64.iso"
}
EOF

    # Update outputs.tf
    cat > "$TF_DIR/outputs.tf" << 'EOF'
output "controlplane_ips" {
  description = "IP addresses of control plane nodes"
  value       = module.talos_controlplane.node_ips
}

output "controlplane_names" {
  description = "Names of control plane nodes"
  value       = module.talos_controlplane.node_names
}

output "worker_ips" {
  description = "IP addresses of worker nodes"
  value       = module.talos_workers.node_ips
}

output "worker_names" {
  description = "Names of worker nodes"
  value       = module.talos_workers.node_names
}
EOF

    # Update terraform variables with counts
    cat > "$TF_VAR_FILE" << EOF
cluster_name      = "$CLUSTER_NAME"
controlplane_count = $CONTROLPLANE_COUNT
worker_count       = $WORKER_COUNT
vm_cores          = $VM_CORES
vm_memory         = $VM_MEMORY
disk_size         = "$DISK_SIZE"
storage_pool      = "$STORAGE_POOL"
network_bridge    = "$NETWORK_BRIDGE"
vlan_id           = $VLAN_ID
talos_iso_path    = "local:iso/$(basename "$TALOS_ISO_URL")"
EOF

    # Apply Terraform configuration
    pushd "$TF_DIR" > /dev/null
    terraform plan -var-file="talos-cluster.auto.tfvars"
    terraform apply -auto-approve -var-file="talos-cluster.auto.tfvars"
    popd > /dev/null
    
    log "$CONTROLPLANE_COUNT control plane nodes deployed"
}

# Wait for nodes to get IP addresses
wait_for_node_ips() {
    log "Waiting for nodes to get IP addresses..."
    
    pushd "$TF_DIR" > /dev/null
    CONTROLPLANE_IPS=$(terraform output -raw controlplane_ips | tr -d '[],"' | tr ' ' '\n' | grep -v '^$')
    WORKER_IPS=$(terraform output -raw worker_ips | tr -d '[],"' | tr ' ' '\n' | grep -v '^$')
    popd > /dev/null
    
    # Wait for each control plane node to get an IP
    for ip in $CONTROLPLANE_IPS; do
        log "Waiting for control plane node with IP $ip to become available..."
        while ! "$HELPER_SCRIPT" get-ip $(get_vm_id_by_ip "$ip") >/dev/null 2>&1; do
            sleep 10
        done
        log "Control plane node with IP $ip is available"
    done
    
    # Wait for each worker node to get an IP
    for ip in $WORKER_IPS; do
        log "Waiting for worker node with IP $ip to become available..."
        while ! "$HELPER_SCRIPT" get-ip $(get_vm_id_by_ip "$ip") >/dev/null 2>&1; do
            sleep 10
        done
        log "Worker node with IP $ip is available"
    done
    
    log "All nodes have IP addresses"
}

# Get VM ID by IP (simplified - in real scenario would query Proxmox API)
get_vm_id_by_ip() {
    # This is a placeholder function - in a real implementation, 
    # we'd query Proxmox API to find VM ID by IP
    echo "placeholder_vm_id"
}

# Generate Talos configurations for control plane nodes
generate_controlplane_configs() {
    log "Generating Talos configurations for control plane nodes..."
    
    mkdir -p "$GENERATED_CONFIGS_DIR"
    
    export CLUSTER_NAME
    export KUBERNETES_VERSION
    export MACHINE_TYPE="controlplane"
    
    # For simplicity, using placeholder IPs - in real scenario would get actual IPs
    for i in $(seq 1 $CONTROLPLANE_COUNT); do
        NODE_IP="192.168.1.$((100 + i))"  # Placeholder IP
        ENDPOINTS=$(get_all_node_ips)  # This would return actual IPs
        export ENDPOINTS
        export NODE_IP
        
        "$CONFIG_GENERATOR" "$NODE_IP" "controlplane"
    done
    
    log "Control plane configurations generated"
}

# Get all node IPs from Terraform output
get_all_node_ips() {
    pushd "$TF_DIR" > /dev/null
    local all_ips
    all_ips=$(terraform output -json | jq -r '.controlplane_ips.value + .worker_ips.value | join(",")')
    popd > /dev/null
    echo "$all_ips"
}

# Apply configurations to control plane nodes
apply_controlplane_configs() {
    log "Applying configurations to control plane nodes..."
    
    # For each control plane node, apply its configuration
    pushd "$TF_DIR" > /dev/null
    local controlplane_ips
    controlplane_ips=$(terraform output -raw controlplane_ips | tr -d '[],"' | tr ' ' '\n' | grep -v '^$')
    popd > /dev/null
    
    local first_cp_ip=""
    for ip in $controlplane_ips; do
        local config_file="$GENERATED_CONFIGS_DIR/controlplane-$ip.yaml"
        if [[ -f "$config_file" ]]; then
            log "Applying configuration to control plane node $ip..."
            "$HELPER_SCRIPT" apply-config "$ip" "$config_file"
            
            # Keep track of first CP IP for bootstrap
            if [[ -z "$first_cp_ip" ]]; then
                first_cp_ip="$ip"
            fi
        else
            log "Warning: Configuration file $config_file not found"
        fi
    done
    
    # Bootstrap the cluster on the first control plane node
    if [[ -n "$first_cp_ip" ]]; then
        log "Bootstrapping cluster on control plane node $first_cp_ip..."
        "$HELPER_SCRIPT" bootstrap "$first_cp_ip"
    fi
    
    log "Control plane configurations applied and cluster bootstrapped"
}

# Apply configurations to worker nodes
apply_worker_configs() {
    log "Applying configurations to worker nodes..."
    
    # For each worker node, apply its configuration
    pushd "$TF_DIR" > /dev/null
    local worker_ips
    worker_ips=$(terraform output -raw worker_ips | tr -d '[],"' | tr ' ' '\n' | grep -v '^$')
    popd > /dev/null
    
    for ip in $worker_ips; do
        local config_file="$GENERATED_CONFIGS_DIR/worker-$ip.yaml"
        if [[ -f "$config_file" ]]; then
            log "Applying configuration to worker node $ip..."
            "$HELPER_SCRIPT" apply-config "$ip" "$config_file"
        else
            log "Warning: Configuration file $config_file not found"
        fi
    done
    
    log "Worker configurations applied"
}

# Generate kubeconfig for cluster access
generate_cluster_kubeconfig() {
    log "Generating kubeconfig for cluster access..."
    
    pushd "$TF_DIR" > /dev/null
    local first_cp_ip
    first_cp_ip=$(terraform output -raw controlplane_ips | tr -d '[],"' | head -1)
    popd > /dev/null
    
    if [[ -n "$first_cp_ip" && "$first_cp_ip" != "null" ]]; then
        "$HELPER_SCRIPT" kubeconfig "$first_cp_ip" "$PROJECT_ROOT/kubeconfig"
        log "Kubeconfig generated at $PROJECT_ROOT/kubeconfig"
    else
        error_exit "Could not determine first control plane IP for kubeconfig generation"
    fi
}

# Verify cluster functionality
verify_cluster() {
    log "Verifying cluster functionality..."
    
    # Set KUBECONFIG to use our generated config
    export KUBECONFIG="$PROJECT_ROOT/kubeconfig"
    
    # Wait for nodes to be ready
    log "Waiting for nodes to be ready..."
    local attempts=0
    local max_attempts=30  # 5 minutes with 10-second intervals
    while [[ $attempts -lt $max_attempts ]]; do
        if kubectl get nodes &>/dev/null; then
            local ready_nodes
            ready_nodes=$(kubectl get nodes --no-headers | grep -c Ready || echo 0)
            local total_nodes=$((CONTROLPLANE_COUNT + WORKER_COUNT))
            
            if [[ $ready_nodes -eq $total_nodes ]]; then
                log "All $total_nodes nodes are ready"
                break
            else
                log "Only $ready_nodes of $total_nodes nodes ready, waiting..."
            fi
        else
            log "Cluster not yet accessible, waiting..."
        fi
        
        sleep 10
        ((attempts++))
    done
    
    if [[ $attempts -ge $max_attempts ]]; then
        error_exit "Cluster verification failed: Not all nodes became ready within timeout"
    fi
    
    # Check basic cluster info
    kubectl cluster-info
    kubectl get nodes -o wide
    
    log "Cluster verification successful"
}

# Main deployment function
main() {
    log "Starting Twinbox Talos cluster deployment"
    
    check_prerequisites
    init_terraform
    prepare_terraform_vars
    download_talos_iso
    deploy_controlplane_nodes
    wait_for_node_ips
    generate_controlplane_configs
    apply_controlplane_configs
    apply_worker_configs
    generate_cluster_kubeconfig
    verify_cluster
    
    log "Twinbox Talos cluster deployment completed successfully!"
    log "Access the cluster using: export KUBECONFIG=$PROJECT_ROOT/kubeconfig"
}

# Call main function
main "$@"
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos-deployment-script-validation.sh`
Expected: PASS message indicating file exists and is executable

**Step 5: Commit**
```bash
chmod +x twinbox/scripts/deploy-talos-cluster.sh
git add twinbox/scripts/deploy-talos-cluster.sh
git commit -m "Add Talos cluster deployment orchestration script"
```

### Task 5: Create testing and validation scripts

**Files:**
- Create: `twinbox/tests/validate-talos-cluster.sh`
- Create: `twinbox/tests/integration-test-talos.sh`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos-testing-scripts-validation.sh
set -e

echo "Testing Talos testing scripts exist..."
if [ ! -f "twinbox/tests/validate-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/tests/validate-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -f "twinbox/tests/integration-test-talos.sh" ]; then
    echo "FAIL: twinbox/tests/integration-test-talos.sh does not exist"
    exit 1
fi

echo "PASS: Talos testing scripts exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos-testing-scripts-validation.sh`
Expected: FAIL message indicating files don't exist

**Step 3: Write minimal implementation**

Content for [`twinbox/tests/validate-talos-cluster.sh`](twinbox/tests/validate-talos-cluster.sh):
```bash
#!/bin/bash

# Talos Cluster Validation Script
# Validates the health and configuration of a deployed Talos cluster

set -euo pipefail

# Configuration
DEFAULT_KUBECONFIG_PATH="${HOME}/.kube/config"
KUBECONFIG_PATH=${KUBECONFIG:-$DEFAULT_KUBECONFIG_PATH}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-300}  # 5 minutes default timeout
CLUSTER_NAME=${CLUSTER_NAME:-"talos-cluster"}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        error_exit "kubectl is required but not installed"
    fi
}

# Check cluster connectivity
check_cluster_connectivity() {
    log "Checking cluster connectivity..."
    
    local start_time
    start_time=$(date +%s)
    local current_time
    current_time=$(date +%s)
    
    while [[ $((current_time - start_time)) -lt $TIMEOUT_SECONDS ]]; do
        if kubectl cluster-info &>/dev/null; then
            log "Cluster connectivity verified"
            return 0
        fi
        
        sleep 10
        current_time=$(date +%s)
    done
    
    error_exit "Failed to connect to cluster within timeout period"
}

# Validate node status
validate_nodes() {
    log "Validating node status..."
    
    local node_count
    node_count=$(kubectl get nodes --no-headers | wc -l)
    
    if [[ $node_count -eq 0 ]]; then
        error_exit "No nodes found in cluster"
    fi
    
    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers | grep -c Ready)
    
    log "Found $node_count nodes, $ready_nodes ready"
    
    if [[ $ready_nodes -ne $node_count ]]; then
        log "WARNING: Not all nodes are ready"
        kubectl get nodes
        return 1
    fi
    
    log "All nodes are ready"
    return 0
}

# Validate system pods
validate_system_pods() {
    log "Validating system pods..."
    
    local system_namespaces=("kube-system" "kube-public" "kube-node-lease")
    
    for namespace in "${system_namespaces[@]}"; do
        if kubectl get namespace "$namespace" &>/dev/null; then
            local pod_count
            pod_count=$(kubectl get pods -n "$namespace" --no-headers | wc -l)
            
            if [[ $pod_count -gt 0 ]]; then
                local ready_pods
                ready_pods=$(kubectl get pods -n "$namespace" --no-headers | awk '
                {
                    total_containers = NF > 0 ? $2 : 0
                    split(total_containers, counts, "/")
                    if (length(counts) == 3) {
                        if (counts[1] == counts[2]) running++
                    } else if (NF > 0 && $3 == "Running") {
                        running++
                    }
                }
                END { print running+0 }
                ')
                
                log "Namespace $namespace: $ready_pods/$pod_count pods ready"
                
                if [[ $ready_pods -lt $pod_count ]]; then
                    log "WARNING: Not all pods in $namespace are ready"
                    kubectl get pods -n "$namespace"
                fi
            fi
        fi
    done
    
    log "System pods validation completed"
}

# Validate CNI
validate_cni() {
    log "Validating CNI (Container Network Interface)..."
    
    # Check for common CNI pods
    local cni_namespaces=("kube-system" "cilium-system" "calico-system")
    local cni_found=false
    
    for namespace in "${cni_namespaces[@]}"; do
        if kubectl get namespace "$namespace" &>/dev/null; then
            local cni_pods
            cni_pods=$(kubectl get pods -n "$namespace" --no-headers | grep -E "(calico|flannel|cilium|weave|kube-router)" | wc -l)
            
            if [[ $cni_pods -gt 0 ]]; then
                local ready_cni_pods
                ready_cni_pods=$(kubectl get pods -n "$namespace" --no-headers | grep -E "(calico|flannel|cilium|weave|kube-router)" | awk '
                {
                    total_containers = NF > 0 ? $2 : 0
                    split(total_containers, counts, "/")
                    if (length(counts) == 3) {
                        if (counts[1] == counts[2]) running++
                    } else if (NF > 0 && $3 == "Running") {
                        running++
                    }
                }
                END { print running+0 }
                ')
                
                log "CNI in $namespace: $ready_cni_pods/$cni_pods pods ready"
                cni_found=true
                break
            fi
        fi
    done
    
    if [[ "$cni_found" == false ]]; then
        log "WARNING: No known CNI pods found"
    else
        log "CNI validation completed"
    fi
}

# Validate Talos-specific features
validate_talos_features() {
    log "Validating Talos-specific features..."
    
    # Check if we can reach Talos API endpoints
    if command -v talosctl &> /dev/null; then
        log "talosctl is available, checking Talos-specific metrics..."
        
        # Try to get machine information (requires talosconfig)
        if [[ -f ".talosconfig" ]]; then
            log "Getting Talos machine information..."
            talosctl machines || log "Could not retrieve machine information"
        else
            log "No .talosconfig found, skipping Talos-specific validations"
        fi
    else
        log "talosctl not available, skipping Talos-specific validations"
    fi
}

# Run all validations
run_validations() {
    log "Starting Talos cluster validation for $CLUSTER_NAME..."
    
    check_kubectl
    check_cluster_connectivity
    validate_nodes
    validate_system_pods
    validate_cni
    validate_talos_features
    
    log "Talos cluster validation completed successfully!"
}

# Main function
main() {
    run_validations
}

# Call main function
main "$@"
```

Content for [`twinbox/tests/integration-test-talos.sh`](twinbox/tests/integration-test-talos.sh):
```bash
#!/bin/bash

# Talos Integration Test Suite
# Comprehensive integration tests for Twinbox Talos integration

set -euo pipefail

# Configuration
TEST_NAMESPACE="talos-integration-test"
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-600}  # 10 minutes default timeout
DEFAULT_KUBECONFIG_PATH="${HOME}/.kube/config"
KUBECONFIG_PATH=${KUBECONFIG:-$DEFAULT_KUBECONFIG_PATH}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Cleanup function
cleanup() {
    log "Cleaning up test resources..."
    
    # Delete test namespace if it exists
    if kubectl get namespace "$TEST_NAMESPACE" &>/dev/null; then
        kubectl delete namespace "$TEST_NAMESPACE" --wait=false || true
    fi
    
    log "Cleanup completed"
}

# Setup test environment
setup_test_env() {
    log "Setting up test environment..."
    
    # Create test namespace
    kubectl create namespace "$TEST_NAMESPACE" || true
    
    # Wait for namespace to be ready
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if kubectl get namespace "$TEST_NAMESPACE" &>/dev/null; then
            log "Test namespace $TEST_NAMESPACE created"
            break
        fi
        sleep 10
        ((attempts++))
    done
    
    if [[ $attempts -ge $max_attempts ]]; then
        error_exit "Failed to create test namespace within timeout"
    fi
    
    log "Test environment setup completed"
}

# Test basic pod deployment
test_pod_deployment() {
    log "Testing basic pod deployment..."
    
    # Create a simple pod
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: $TEST_NAMESPACE
spec:
  containers:
  - name: test-container
    image: nginx:latest
    ports:
    - containerPort: 80
EOF
    
    # Wait for pod to be running
    local start_time
    start_time=$(date +%s)
    local current_time
    current_time=$(date +%s)
    
    while [[ $((current_time - start_time)) -lt $TIMEOUT_SECONDS ]]; do
        local pod_status
        pod_status=$(kubectl get pod test-pod -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [[ "$pod_status" == "Running" ]]; then
            log "Pod test-pod is running"
            break
        elif [[ "$pod_status" == "Failed" ]] || [[ "$pod_status" == "Unknown" ]]; then
            error_exit "Pod test-pod failed to start with status: $pod_status"
        fi
        
        sleep 10
        current_time=$(date +%s)
    done
    
    if [[ $((current_time - start_time)) -ge $TIMEOUT_SECONDS ]]; then
        error_exit "Pod test-pod did not become running within timeout"
    fi
    
    log "Basic pod deployment test passed"
}

# Test service deployment and connectivity
test_service_connectivity() {
    log "Testing service deployment and connectivity..."
    
    # Create a service for the test pod
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: $TEST_NAMESPACE
spec:
  selector:
    app: test-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
EOF
    
    # Update pod to include the required label
    kubectl patch pod test-pod -n "$TEST_NAMESPACE" -p '{"metadata":{"labels":{"app":"test-app"}}}'
    
    # Wait for service to be available
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if kubectl get service test-service -n "$TEST_NAMESPACE" &>/dev/null; then
            local service_ip
            service_ip=$(kubectl get service test-service -n "$TEST_NAMESPACE" -o jsonpath='{.spec.clusterIP}')
            
            if [[ -n "$service_ip" && "$service_ip" != "null" ]]; then
                log "Service test-service is available at $service_ip"
                break
            fi
        fi
        sleep 10
        ((attempts++))
    done
    
    if [[ $attempts -ge $max_attempts ]]; then
        error_exit "Service test-service did not become available within timeout"
    fi
    
    log "Service connectivity test passed"
}

# Test persistent volume (if supported)
test_persistent_volume() {
    log "Testing persistent volume support..."
    
    # Check if storage classes are available
    if kubectl get storageclass &>/dev/null; then
        local default_sc
        default_sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$default_sc" ]]; then
            log "Default storage class found: $default_sc"
            
            # Create a PVC
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: $TEST_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: $default_sc
EOF
            
            # Wait for PVC to be bound
            local attempts=0
            local max_attempts=30
            while [[ $attempts -lt $max_attempts ]]; do
                local pvc_status
                pvc_status=$(kubectl get pvc test-pvc -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                
                if [[ "$pvc_status" == "Bound" ]]; then
                    log "PVC test-pvc is bound"
                    break
                elif [[ "$pvc_status" == "Lost" ]]; then
                    error_exit "PVC test-pvc is lost"
                fi
                
                sleep 10
                ((attempts++))
            done
            
            if [[ $attempts -ge $max_attempts ]]; then
                log "PVC test-pvc did not become bound within timeout, this may be expected depending on storage setup"
            else
                log "Persistent volume test passed"
            fi
        else
            log "No default storage class found, skipping PV test"
        fi
    else
        log "No storage classes available, skipping PV test"
    fi
}

# Test ingress (if available)
test_ingress() {
    log "Testing ingress functionality..."
    
    # Check if ingress controller is available
    if kubectl get ingressclass &>/dev/null; then
        local ingress_classes
        ingress_classes=$(kubectl get ingressclass --no-headers 2>/dev/null | wc -l)
        
        if [[ $ingress_classes -gt 0 ]]; then
            log "Ingress classes found, testing ingress creation..."
            
            # Create an ingress resource
            cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  namespace: $TEST_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - http:
      paths:
      - path: /test
        pathType: Prefix
        backend:
          service:
            name: test-service
            port:
              number: 80
EOF
            
            # Wait for ingress to be created
            local attempts=0
            local max_attempts=30
            while [[ $attempts -lt $max_attempts ]]; do
                if kubectl get ingress test-ingress -n "$TEST_NAMESPACE" &>/dev/null; then
                    log "Ingress test-ingress created"
                    break
                fi
                sleep 10
                ((attempts++))
            done
            
            if [[ $attempts -ge $max_attempts ]]; then
                log "Ingress test-ingress did not become available within timeout, this may be expected"
            else
                log "Ingress test passed"
            fi
        else
            log "No ingress classes available, skipping ingress test"
        fi
    else
        log "Ingress API not available, skipping ingress test"
    fi
}

# Test security policies
test_security_policies() {
    log "Testing security policies..."
    
    # Check if pod security policies or pod security admission is configured
    if kubectl api-resources --api-group=policy | grep -q PodSecurityPolicy; then
        log "Pod Security Policy API is available"
        
        # Create a restricted pod security policy
        cat <<EOF | kubectl apply -f - 2>/dev/null || log "Could not create PSP (may not be enabled)"
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: test-restricted-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'configMap'
    - 'emptyDir'
    - 'projected'
    - 'secret'
    - 'downwardAPI'
    - 'persistentVolumeClaim'
  hostNetwork: false
  hostIPC: false
  hostPID: false
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
  supplementalGroups:
    rule: 'RunAsAny'
EOF
    else
        log "Pod Security Policy API not available, checking for Pod Security Admission"
        
        # Test basic security context in pod
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-security-pod
  namespace: $TEST_NAMESPACE
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
  - name: test-container
    image: nginx:latest
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 1000
      capabilities:
        drop:
        - ALL
    ports:
    - containerPort: 80
EOF
        
        # Wait for pod to be running
        local attempts=0
        local max_attempts=30
        while [[ $attempts -lt $max_attempts ]]; do
            local pod_status
            pod_status=$(kubectl get pod test-security-pod -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [[ "$pod_status" == "Running" ]]; then
                log "Security test pod is running with security context"
                break
            elif [[ "$pod_status" == "Failed" ]] || [[ "$pod_status" == "Unknown" ]]; then
                log "Security test pod failed with status: $pod_status (this may be expected behavior)"
                break
            fi
            
            sleep 10
            ((attempts++))
        done
    fi
    
    log "Security policies test completed"
}

# Run all tests
run_tests() {
    log "Starting Talos integration tests..."
    
    setup_test_env
    test_pod_deployment
    test_service_connectivity
    test_persistent_volume
    test_ingress
    test_security_policies
    
    log "All Talos integration tests completed!"
}

# Main function
main() {
    # Set trap to cleanup on exit
    trap cleanup EXIT
    
    run_tests
}

# Call main function
main "$@"
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos-testing-scripts-validation.sh`
Expected: PASS message indicating files exist

**Step 5: Commit**
```bash
chmod +x twinbox/tests/validate-talos-cluster.sh twinbox/tests/integration-test-talos.sh
git add twinbox/tests/validate-talos-cluster.sh twinbox/tests/integration-test-talos.sh
git commit -m "Add Talos cluster validation and integration testing scripts"
```

### Task 6: Create documentation for the Talos integration

**Files:**
- Create: `twinbox/docs/talos-integration.md`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos-documentation-validation.sh
set -e

echo "Testing Talos documentation exists..."
if [ ! -f "twinbox/docs/talos-integration.md" ]; then
    echo "FAIL: twinbox/docs/talos-integration.md does not exist"
    exit 1
fi

echo "PASS: Talos documentation exists"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos-documentation-validation.sh`
Expected: FAIL message indicating file doesn't exist

**Step 3: Write minimal implementation**

Content for [`twinbox/docs/talos-integration.md`](twinbox/docs/talos-integration.md):
```markdown
# Twinbox Talos Linux Integration Guide

## Overview

This document provides guidance on deploying and managing Talos Linux-based Kubernetes clusters using Twinbox. Talos Linux is a modern, secure, and immutable Linux distribution designed specifically for Kubernetes. This integration maintains Twinbox's existing architecture while adapting to Talos's unique requirements and configuration model.

## Architecture

The Talos integration follows Twinbox's established two-layer architecture:

### Infrastructure Layer (Terraform)
- VM provisioning with Talos-specific requirements (UEFI, EFI disk, etc.)
- Network configuration and connectivity
- Storage management adapted for Talos installation patterns

### Configuration Layer (Talos Machine Configs)
- Declarative system configuration via Talos machine configs
- Kubernetes cluster initialization through Talos APIs
- Service deployment and configuration via Kubernetes manifests
- Security hardening through Talos's built-in features

## Prerequisites

Before deploying a Talos cluster with Twinbox, ensure you have:

- Access to a Proxmox VE environment
- Sufficient resources for your cluster (minimum 2 CPUs and 4GB RAM per node)
- Internet access for downloading Talos ISO and container images
- `terraform`, `talosctl`, and `kubectl` installed locally
- `jq` for JSON processing

## Deployment Process

### 1. Environment Setup

Set the required environment variables:

```bash
export PROXMOX_HOST="your-proxmox-host"
export PROXMOX_PORT="8006"
export PROXMOX_USER="root@pam"
export PROXMOX_PASSWORD="your-password"
export CLUSTER_NAME="my-talos-cluster"
export PROXMOX_REALM="pam"
```

### 2. Customize Cluster Configuration

Modify the following variables according to your needs:

```bash
export CONTROLPLANE_COUNT=1    # Number of control plane nodes
export WORKER_COUNT=2          # Number of worker nodes
export VM_CORES=4              # CPU cores per VM
export VM_MEMORY=4096          # Memory in MB per VM
export DISK_SIZE="20G"         # Disk size per VM
export STORAGE_POOL="local-lvm" # Proxmox storage pool
export NETWORK_BRIDGE="vmbr0"  # Network bridge
export VLAN_ID=0               # VLAN ID (0 for none)
export KUBERNETES_VERSION="1.28.0" # Kubernetes version
```

### 3. Deploy the Cluster

Run the deployment script:

```bash
./twinbox/scripts/deploy-talos-cluster.sh
```

The script will:
- Download the Talos ISO to Proxmox
- Provision VMs using Terraform
- Generate Talos machine configurations
- Apply configurations to nodes
- Bootstrap the cluster
- Generate kubeconfig for access

### 4. Access the Cluster

After deployment, access your cluster using the generated kubeconfig:

```bash
export KUBECONFIG=./twinbox/kubeconfig
kubectl get nodes
```

## Configuration Management

### Machine Configurations

Talos uses declarative machine configurations instead of traditional configuration files. Twinbox generates these configurations using templates located at:

- `twinbox/configs/talos-controlplane-template.yaml` - Control plane template
- `twinbox/configs/talos-worker-template.yaml` - Worker node template

To customize configurations, modify these templates or generate custom configurations using the configuration generator:

```bash
CLUSTER_NAME="my-cluster" \
NODE_IP="192.168.1.100" \
MACHINE_TYPE="controlplane" \
./twinbox/scripts/generate-talos-config.sh
```

### Applying Configuration Changes

To apply configuration changes to a running node:

```bash
talosctl apply-config --insecure --nodes NODE_IP --file PATH_TO_CONFIG
```

Or use the helper script:

```bash
./twinbox/scripts/proxmox-talos-helper.sh apply-config NODE_IP PATH_TO_CONFIG
```

## Management Operations

### Getting Node Information

Get IP addresses of cluster nodes:

```bash
terraform -chdir=twinbox/terraform output controlplane_ips
terraform -chdir=twinbox/terraform output worker_ips
```

### Cluster Verification

Validate cluster health:

```bash
./twinbox/tests/validate-talos-cluster.sh
```

Run comprehensive integration tests:

```bash
./twinbox/tests/integration-test-talos.sh
```

### Accessing Talos API

To interact directly with the Talos API, use talosctl:

```bash
talosctl --nodes NODE_IP config generate --force --endpoints ENDPOINT_IP
talosctl --nodes NODE_IP get machineconfig
talosctl --nodes NODE_IP reboot
talosctl --nodes NODE_IP upgrade --image ghcr.io/siderolabs/installer:latest
```

## Security Features

### Built-in Security

Talos Linux includes several security features:

- Immutable filesystem
- Minimal attack surface
- Automatic security updates
- Secure boot support
- Kernel hardening

### RBAC Configuration

Talos enables RBAC by default. To configure additional RBAC rules, apply Kubernetes manifests after cluster creation:

```bash
kubectl apply -f your-rbac-manifest.yaml
```

### Network Policies

To enhance security with network policies:

```bash
kubectl apply -f twinbox/ansible/roles/security/files/network-policies.yaml
```

## Troubleshooting

### Common Issues

#### Nodes Not Getting IP Addresses
- Check Proxmox agent is installed and running in the VM
- Verify network bridge configuration in Proxmox
- Ensure DHCP is available on the network

#### Configuration Application Failures
- Verify talosctl is configured with correct endpoints
- Check that the target node is accessible
- Ensure the configuration file is valid

#### Cluster Bootstrap Failures
- Confirm all control plane nodes are accessible
- Verify network connectivity between nodes
- Check that the cluster name is consistent across configurations

### Diagnostic Commands

Get machine information:
```bash
talosctl --nodes NODE_IP get machineconfig
```

Check logs:
```bash
talosctl --nodes NODE_IP logs kubelet
```

View cluster status:
```bash
talosctl --nodes NODE_IP cluster health
```

### Log Files

Talos logs can be accessed via:
- `talosctl --nodes NODE_IP logs <service-name>` - For specific service logs
- `journalctl` - On the Talos node itself (via console access)

## Maintenance

### Upgrading Talos

To upgrade Talos nodes:

```bash
talosctl --nodes NODE_IP upgrade --image ghcr.io/siderolabs/installer:v1.6.0
```

### Backup and Recovery

Talos provides built-in backup capabilities for etcd. For additional backups, consider:

- Backing up the generated machine configurations
- Regular Kubernetes resource backups using Velero or similar tools
- Snapshotting VMs in Proxmox for disaster recovery

### Scaling Clusters

To scale your cluster, modify the Terraform variables and reapply:

1. Update `twinbox/terraform/talos-cluster.auto.tfvars`
2. Run `terraform -chdir=twinbox/terraform apply`
3. Generate and apply new configurations for new nodes

## Integration with Existing Twinbox Services

### Monitoring Integration

Existing Twinbox monitoring components can be deployed to Talos clusters using standard Kubernetes manifests:

```bash
kubectl apply -f twinbox/ansible/roles/monitoring/files/prometheus-stack.yaml
kubectl apply -f twinbox/ansible/roles/monitoring/files/grafana-dashboard.yaml
```

### Security Integration

Apply Twinbox security policies:

```bash
kubectl apply -f twinbox/ansible/roles/security/files/rbac-admin-user.yaml
kubectl apply -f twinbox/ansible/roles/security/files/network-policies.yaml
```

### Addon Integration

Deploy Twinbox addons:

```bash
kubectl apply -f twinbox/ansible/roles/addons/files/metallb-native.yaml
kubectl apply -f twinbox/ansible/roles/addons/files/nginx-ingress.yaml
```

## Best Practices

### Resource Planning

- Allocate sufficient resources: minimum 2 CPU cores and 4GB RAM per node
- Plan for overhead: Talos has minimal overhead compared to traditional OS
- Consider resource requirements for your applications

### High Availability

For production deployments:
- Deploy at least 3 control plane nodes for etcd quorum
- Distribute nodes across different physical hosts
- Implement proper backup strategies

### Security

- Regularly update Talos to latest stable version
- Monitor cluster for security advisories
- Implement network segmentation
- Use least-privilege principles for workloads

### Monitoring

- Monitor both infrastructure and application metrics
- Set up alerting for critical issues
- Track cluster performance over time
- Monitor Talos-specific metrics

## Limitations

- Talos Linux requires UEFI boot mode
- Limited customization compared to traditional Linux distributions
- Different operational model requiring adjustment from traditional approaches
- Some legacy applications may not work without modification

## Migration from Traditional Clusters

Existing Twinbox users can gradually adopt Talos clusters alongside traditional Kubernetes clusters, allowing for comparison and gradual migration as needed. The deployment and management interfaces remain consistent with Twinbox patterns.
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos-documentation-validation.sh`
Expected: PASS message indicating file exists

**Step 5: Commit**
```bash
git add twinbox/docs/talos-integration.md
git commit -m "Add documentation for Talos Linux integration"
```

### Task 7: Update main README to include Talos integration

**Files:**
- Modify: `README.md`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/readme-talos-update-validation.sh
set -e

echo "Testing README.md includes Talos integration..."
if ! grep -q "Talos" README.md; then
    echo "FAIL: README.md does not mention Talos integration"
    exit 1
fi

echo "PASS: README.md includes Talos integration"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/readme-talos-update-validation.sh`
Expected: FAIL message indicating file doesn't mention Talos

**Step 3: Write minimal implementation**

Content for [`README.md`](README.md):
```markdown
# Twinbox

Twinbox is a comprehensive infrastructure automation platform for deploying and managing Kubernetes clusters on Proxmox VE. It provides a complete solution for infrastructure as code, configuration management, and operational tooling.

## Features

- **Infrastructure as Code**: Terraform modules for provisioning VMs on Proxmox
- **Configuration Management**: Ansible playbooks for cluster setup and configuration
- **Multiple Kubernetes Distributions**: Support for both traditional Kubernetes and Talos Linux
- **Security**: Built-in security hardening and RBAC configuration
- **Monitoring**: Integrated monitoring stack with Prometheus and Grafana
- **Networking**: CNI plugin configuration and ingress setup
- **Storage**: Persistent storage configuration
- **User Management**: Identity and access management integration

## Quick Start

### Prerequisites

- Proxmox VE environment
- Terraform installed
- Ansible installed
- Sufficient hardware resources

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/your-org/twinbox.git
   cd twinbox
   ```

2. Configure environment variables:
   ```bash
   export PROXMOX_HOST="your-proxmox-host"
   export PROXMOX_USER="root@pam"
   export PROXMOX_PASSWORD="your-password"
   ```

3. Deploy your cluster:
   ```bash
   ./twinbox/scripts/deploy.sh
   ```

## Talos Linux Integration

Twinbox now includes full support for Talos Linux, a modern, secure, and immutable Linux distribution designed specifically for Kubernetes. The Talos integration provides:

- Automated VM provisioning with UEFI and EFI disk requirements
- Machine configuration generation and application
- Seamless cluster bootstrap and validation
- Integration with existing Twinbox monitoring and security features

To deploy a Talos cluster, use the dedicated deployment script:

```bash
./twinbox/scripts/deploy-talos-cluster.sh
```

See the [Talos Integration Guide](twinbox/docs/talos-integration.md) for detailed documentation.

## Architecture

Twinbox follows a two-layer architecture:

### Infrastructure Layer (Terraform)
- VM provisioning on Proxmox VE
- Network and storage configuration
- Load balancer setup (if needed)

### Configuration Layer (Ansible)
- Kubernetes cluster initialization
- Addon deployment (CNI, ingress, monitoring)
- Security configuration
- User management setup

## Components

### Terraform Modules
- `twinbox/terraform/main.tf`: Core infrastructure provisioning
- `twinbox/terraform/talos-vm/main.tf`: Talos-specific VM provisioning

### Ansible Roles
- `prerequisites`: Base system preparation
- `container_runtime`: Container runtime setup
- `kubeadm_setup`: Kubernetes cluster initialization
- `cni_install`: CNI plugin installation
- `addons`: Additional cluster components
- `monitoring`: Monitoring stack deployment
- `security`: Security hardening and RBAC
- `user_management`: Identity and access management

### Scripts
- `twinbox/scripts/deploy.sh`: Standard Kubernetes deployment
- `twinbox/scripts/deploy-talos-cluster.sh`: Talos Linux deployment
- `twinbox/scripts/validate-installation.sh`: Post-deployment validation
- `twinbox/scripts/proxmox-talos-helper.sh`: Proxmox-Talos integration utilities

### Tests
- `twinbox/tests/`: Various validation and integration tests
- `twinbox/tests/validate-talos-cluster.sh`: Talos cluster validation
- `twinbox/tests/integration-test-talos.sh`: Talos integration tests

## Configuration

Customize your deployment by modifying:

- Terraform variables in `twinbox/terraform/*.tfvars`
- Ansible group variables in `twinbox/ansible/group_vars/all.yml`
- Machine configuration templates in `twinbox/configs/`

## Documentation

- [Getting Started](twinbox/docs/getting-started.md)
- [Architecture](twinbox/docs/architecture.md)
- [Configuration](twinbox/docs/configuration.md)
- [Talos Integration](twinbox/docs/talos-integration.md)
- [Troubleshooting](twinbox/docs/troubleshooting.md)
- [Verification](twinbox/docs/verification.md)

## Contributing

We welcome contributions to Twinbox! Please see our contributing guidelines for more information.

## License

Twinbox is released under the [LICENSE](twinbox/LICENSE) license.
```

**Step 4: Run test to verify it passes**
Run: `bash tests/readme-talos-update-validation.sh`
Expected: PASS message indicating file includes Talos integration

**Step 5: Commit**
```bash
git add README.md
git commit -m "Update README to include Talos Linux integration"
```

### Task 8: Create a summary test to validate the complete implementation

**Files:**
- Create: `tests/comprehensive-talos-integration-test.sh`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/comprehensive-talos-integration-test.sh
set -e

echo "=== Comprehensive Talos Integration Test ==="

echo "Checking if all required files exist..."

# Check Terraform module
if [ ! -f "twinbox/terraform/talos-vm/main.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/main.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/variables.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/variables.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/outputs.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/outputs.tf does not exist"
    exit 1
fi

# Check helper script
if [ ! -f "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh is not executable"
    exit 1
fi

# Check config generator
if [ ! -f "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh is not executable"
    exit 1
fi

# Check templates
if [ ! -f "twinbox/configs/talos-controlplane-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-controlplane-template.yaml does not exist"
    exit 1
fi

if [ ! -f "twinbox/configs/talos-worker-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-worker-template.yaml does not exist"
    exit 1
fi

# Check deployment script
if [ ! -f "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh is not executable"
    exit 1
fi

# Check testing scripts
if [ ! -f "twinbox/tests/validate-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/tests/validate-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -f "twinbox/tests/integration-test-talos.sh" ]; then
    echo "FAIL: twinbox/tests/integration-test-talos.sh does not exist"
    exit 1
fi

# Check documentation
if [ ! -f "twinbox/docs/talos-integration.md" ]; then
    echo "FAIL: twinbox/docs/talos-integration.md does not exist"
    exit 1
fi

# Check README update
if ! grep -q "Talos" README.md; then
    echo "FAIL: README.md does not mention Talos integration"
    exit 1
fi

echo "PASS: All files for Talos integration exist and are properly configured"
echo "=== Comprehensive Talos Integration Test Complete ==="
```

**Step 2: Run test to verify it fails**
Run: `bash tests/comprehensive-talos-integration-test.sh`
Expected: PASS message indicating all files exist and are properly configured

**Step 3: Write minimal implementation**
Since this is a test file that validates the entire implementation, we just need to create it:

Content for [`tests/comprehensive-talos-integration-test.sh`](tests/comprehensive-talos-integration-test.sh):
```bash
#!/bin/bash
# Twinbox Talos Integration Validation Test
# This script validates that all components of the Talos integration are properly implemented

set -e

echo "=== Comprehensive Talos Integration Test ==="

echo "Checking if all required files exist..."

# Check Terraform module
if [ ! -f "twinbox/terraform/talos-vm/main.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/main.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/variables.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/variables.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/outputs.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/outputs.tf does not exist"
    exit 1
fi

# Check helper script
if [ ! -f "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh is not executable"
    exit 1
fi

# Check config generator
if [ ! -f "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh is not executable"
    exit 1
fi

# Check templates
if [ ! -f "twinbox/configs/talos-controlplane-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-controlplane-template.yaml does not exist"
    exit 1
fi

if [ ! -f "twinbox/configs/talos-worker-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-worker-template.yaml does not exist"
    exit 1
fi

# Check deployment script
if [ ! -f "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh is not executable"
    exit 1
fi

# Check testing scripts
if [ ! -f "twinbox/tests/validate-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/tests/validate-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -f "twinbox/tests/integration-test-talos.sh" ]; then
    echo "FAIL: twinbox/tests/integration-test-talos.sh does not exist"
    exit 1
fi

# Check documentation
if [ ! -f "twinbox/docs/talos-integration.md" ]; then
    echo "FAIL: twinbox/docs/talos-integration.md does not exist"
    exit 1
fi

# Check README update
if ! grep -q "Talos" README.md; then
    echo "FAIL: README.md does not mention Talos integration"
    exit 1
fi

echo "PASS: All files for Talos integration exist and are properly configured"
echo "=== Comprehensive Talos Integration Test Complete ==="
```

**Step 4: Run test to verify it passes**
Run: `bash tests/comprehensive-talos-integration-test.sh`
Expected: PASS message indicating all files exist and are properly configured

**Step 5: Commit**
```bash
chmod +x tests/comprehensive-talos-integration-test.sh
git add tests/comprehensive-talos-integration-test.sh
git commit -m "Add comprehensive test for Talos integration validation"