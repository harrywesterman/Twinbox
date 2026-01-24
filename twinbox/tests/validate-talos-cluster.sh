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