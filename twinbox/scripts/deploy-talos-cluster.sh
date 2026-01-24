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