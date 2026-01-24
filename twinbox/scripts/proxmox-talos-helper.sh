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