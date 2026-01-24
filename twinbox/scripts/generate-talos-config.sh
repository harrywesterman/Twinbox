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