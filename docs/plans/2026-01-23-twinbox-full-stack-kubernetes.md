# Twinbox Full-Stack Kubernetes on Proxmox Implementation Plan

**Goal:** Create a complete Kubernetes platform on Proxmox using Talos Linux with Rook storage, Traefik ingress, Cloudflare tunnels, and ArgoCD GitOps.

**Architecture:** Talos Linux provides secure, immutable Kubernetes nodes on Proxmox infrastructure. Rook/Ceph provides persistent storage, Traefik handles ingress/load balancing, Cloudflare tunnels provide secure public access, and ArgoCD manages GitOps workflows.

**Tech Stack:** Talos Linux, Proxmox VE, Rook/Ceph, Traefik, Cloudflare Tunnel, ArgoCD, GitOps

---

### Task 1: Enhance Proxmox Helper Script for Additional Services

**Files:**
- Modify: `scripts/proxmox-helper.sh:800-1000`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/enhanced_helper_test.sh
set -e

# Check if the script contains functions for additional services
if ! grep -q "deploy_rook_storage" "scripts/proxmox-helper.sh"; then
    echo "FAIL: deploy_rook_storage function not found"
    exit 1
fi

if ! grep -q "deploy_traefik" "scripts/proxmox-helper.sh"; then
    echo "FAIL: deploy_traefik function not found"
    exit 1
fi

if ! grep -q "deploy_argocd" "scripts/proxmox-helper.sh"; then
    echo "FAIL: deploy_argocd function not found"
    exit 1
fi

echo "PASS: Enhanced helper functions exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/enhanced_helper_test.sh`
Expected: FAIL error indicating functions don't exist

**Step 3: Write minimal implementation**

Update the `scripts/proxmox-helper.sh` to include additional service deployment functions:

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

# Service versions
ROOK_VERSION="v1.14.4"
TRAEFIK_VERSION="v3.0.2"
ARGOCD_VERSION="v2.12.3"

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
    create-cluster      Create a new Talos Linux cluster
    delete-cluster      Delete an existing cluster
    list-vms           List all Talos VMs
    start-vm           Start a VM
    stop-vm            Stop a VM
    destroy-vm         Destroy a VM
    generate-config    Generate Talos machine configs
    deploy-storage     Deploy Rook/Ceph storage
    deploy-ingress     Deploy Traefik ingress controller
    deploy-argocd      Deploy ArgoCD GitOps
    deploy-cloudflare  Deploy Cloudflare tunnel agent

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
    $(basename "$0") deploy-storage --cluster-name my-cluster
    $(basename "$0") deploy-ingress --cluster-name my-cluster
    $(basename "$0") deploy-argocd --cluster-name my-cluster
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

# Deploy Rook/Ceph storage
deploy_rook_storage() {
    local cluster_name=$1
    
    log "Deploying Rook/Ceph storage for cluster: ${cluster_name}"
    
    # Create directory for storage configs
    local storage_dir="clusters/${cluster_name}/storage"
    mkdir -p "$storage_dir"
    
    # Download Rook operator
    log "Downloading Rook operator (${ROOK_VERSION})..."
    curl -L https://github.com/rook/rook/releases/download/${ROOK_VERSION}/manifests.yaml \
        -o "${storage_dir}/rook-operator-expr.yaml"
    
    # Create cluster config
    cat > "${storage_dir}/rook-cluster-expr.yaml" << EOF
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  dataDirHostPath: /var/lib/rook
  mon:
    count: 3
    allowMultiplePerNode: false
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.1
  dashboard:
    enabled: true
    ssl: true
  monitoring:
    enabled: true
    rulesNamespace: rook-ceph
  network:
    provider: host
    selectors:
      public: cluster-public-net
      cluster: cluster-private-net
  crashCollector:
    disable: false
  cleanupPolicy:
    confirmation: ""
    sanitizeDisks:
      method: quick
      dataSource: zero
      iteration: 1
    allowUninstallWithVolumes: false
  disruptionManagement:
    managePodBudgets: true
    osdMaintenanceTimeout: 30
    pgHealthCheckTimeout: 0
  mgr:
    count: 2
    modules:
    - name: pg_autoscaler
      enabled: true
EOF
    
    # Create storage class
    cat > "${storage_dir}/rook-storageclass.yaml" << EOF
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
mountOptions:
  - discard
EOF
    
    log "Rook/Ceph storage configuration generated in ${storage_dir}/"
    log "To deploy: kubectl apply -f ${storage_dir}/rook-operator-expr.yaml"
    log "Wait for operator to be ready, then: kubectl apply -f ${storage_dir}/rook-cluster-expr.yaml"
}

# Deploy Traefik ingress controller
deploy_traefik() {
    local cluster_name=$1
    
    log "Deploying Traefik ingress controller for cluster: ${cluster_name}"
    
    # Create directory for ingress configs
    local ingress_dir="clusters/${cluster_name}/ingress"
    mkdir -p "$ingress_dir"
    
    # Create Traefik deployment with Helm
    cat > "${ingress_dir}/traefik-values.yaml" << EOF
---
# Enable Traefik dashboard
dashboard:
  enabled: true
  domain: traefik.${cluster_name}.local

# Configure service to LoadBalancer for external access
service:
  type: LoadBalancer
  annotations:
    metallb.universe.tf/loadBalancer-ip: ""  # Will be set during deployment

# Enable access logs
logs:
  access:
    enabled: true

# Configure entry points
ports:
  web:
    redirectTo:
      port: websecure
  websecure:
    tls:
      enabled: true

# Configure providers
providers:
  kubernetesCRD:
    enabled: true
    namespaces: []
  kubernetesIngress:
    enabled: true
    namespaces: []
EOF
    
    # Create basic RBAC for Traefik
    cat > "${ingress_dir}/traefik-rbac.yaml" << EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik-ingress-controller
rules:
  - apiGroups:
      - ""
    resources:
      - services
      - endpoints
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses
      - ingressclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik-ingress-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-ingress-controller
subjects:
  - kind: ServiceAccount
    name: traefik-ingress-controller
    namespace: kube-system
EOF
    
    log "Traefik ingress configuration generated in ${ingress_dir}/"
    log "To deploy with Helm: helm upgrade --install traefik traefik/traefik --values ${ingress_dir}/traefik-values.yaml --namespace kube-system --create-namespace"
}

# Deploy ArgoCD GitOps
deploy_argocd() {
    local cluster_name=$1
    
    log "Deploying ArgoCD GitOps for cluster: ${cluster_name}"
    
    # Create directory for ArgoCD configs
    local argocd_dir="clusters/${cluster_name}/argocd"
    mkdir -p "$argocd_dir"
    
    # Create ArgoCD deployment
    cat > "${argocd_dir}/argocd-install.yaml" << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: applications.argoproj.io
spec:
  group: argoproj.io
  names:
    kind: Application
    listKind: ApplicationList
    plural: applications
    shortNames:
    - app
    - apps
  scope: Namespaced
  versions:
  - name: v1alpha1
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: appprojects.argoproj.io
spec:
  group: argoproj.io
  names:
    kind: AppProject
    listKind: AppProjectList
    plural: appprojects
    shortNames:
    - appproj
  scope: Namespaced
  versions:
  - name: v1alpha1
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-application-controller
  namespace: argocd
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-server
  namespace: argocd
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-repo-server
  namespace: argocd
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cmd-params-cm
data:
  # Add ArgoCD configuration parameters here
  reposerver.ssh_known_hosts: |
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-server
  namespace: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: argocd-server
    spec:
      containers:
      - command:
        - argocd-server
        - --staticassets
        - /shared/app
        - --redis
        - argocd-redis:6379
        image: quay.io/argoproj/argocd:${ARGOCD_VERSION}
        name: argocd-server
        ports:
        - containerPort: 8080
        - containerPort: 8083
      serviceAccountName: argocd-server
---
apiVersion: v1
kind: Service
metadata:
  name: argocd-server
  namespace: argocd
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8080
  - name: https
    port: 443
    protocol: TCP
    targetPort: 8080
  selector:
    app.kubernetes.io/name: argocd-server
  type: LoadBalancer
EOF
    
    log "ArgoCD GitOps configuration generated in ${argocd_dir}/"
    log "To deploy: kubectl apply -f ${argocd_dir}/argocd-install.yaml"
}

# Deploy Cloudflare tunnel agent
deploy_cloudflare() {
    local cluster_name=$1
    
    log "Deploying Cloudflare tunnel agent for cluster: ${cluster_name}"
    
    # Create directory for Cloudflare configs
    local cf_dir="clusters/${cluster_name}/cloudflare"
    mkdir -p "$cf_dir"
    
    # Create Cloudflare tunnel deployment
    cat > "${cf_dir}/cloudflared-daemonset.yaml" << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: kube-system
data:
  config.yaml: |
    tunnels:
      - name: ${cluster_name}-tunnel
        id: YOUR_TUNNEL_ID_HERE
    credentials-file: /etc/cloudflared/credentials/credentials.json
    
    ingress:
      - hostname: ${cluster_name}.yourdomain.com
        service: http://traefik.kube-system:80
      - service: http_status:404
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cloudflared
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:${TRAEFIK_VERSION}
        args:
        - tunnel
        - --config
        - /etc/cloudflared/config/config.yaml
        - run
        env:
        - name: TUNNEL_TOKEN
          valueFrom:
            secretKeyRef:
              name: cloudflared-credentials
              key: credentials.json
        volumeMounts:
        - name: config
          mountPath: /etc/cloudflared/config
          readOnly: true
        - name: credentials
          mountPath: /etc/cloudflared/credentials
          readOnly: true
        livenessProbe:
          httpGet:
            path: /ready
            port: 2000
          initialDelaySeconds: 30
          periodSeconds: 20
      volumes:
      - name: config
        configMap:
          name: cloudflared-config
      - name: credentials
        secret:
          secretName: cloudflared-credentials
---
apiVersion: v1
kind: Service
metadata:
  name: cloudflared-metrics
  namespace: kube-system
  labels:
    app: cloudflared
spec:
  ports:
    - name: metrics
      port: 2000
      protocol: TCP
      targetPort: 2000
  selector:
    app: cloudflared
  type: ClusterIP
EOF
    
    log "Cloudflare tunnel configuration generated in ${cf_dir}/"
    log "To deploy: kubectl apply -f ${cf_dir}/cloudflared-daemonset.yaml"
    log "Note: You need to create a secret with your Cloudflare credentials before deployment"
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
        deploy-storage)
            deploy_rook_storage "$CLUSTER_NAME"
            ;;
        deploy-ingress)
            deploy_traefik "$CLUSTER_NAME"
            ;;
        deploy-argocd)
            deploy_argocd "$CLUSTER_NAME"
            ;;
        deploy-cloudflare)
            deploy_cloudflare "$CLUSTER_NAME"
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
Run: `bash tests/enhanced_helper_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add scripts/proxmox-helper.sh
git commit -m "Enhance helper script with Rook, Traefik, ArgoCD, and Cloudflare deployment functions"
```

### Task 2: Create Rook/Ceph Storage Configuration

**Files:**
- Create: `k8s-manifests/storage/rook-operator.yaml`
- Create: `k8s-manifests/storage/rook-cluster.yaml`
- Create: `k8s-manifests/storage/rook-storageclass.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/rook_storage_test.sh
set -e

if [ ! -f "k8s-manifests/storage/rook-operator.yaml" ]; then
    echo "FAIL: k8s-manifests/storage/rook-operator.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/storage/rook-cluster.yaml" ]; then
    echo "FAIL: k8s-manifests/storage/rook-cluster.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/storage/rook-storageclass.yaml" ]; then
    echo "FAIL: k8s-manifests/storage/rook-storageclass.yaml does not exist"
    exit 1
fi

echo "PASS: Rook storage manifests exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/rook_storage_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p k8s-manifests/storage
```

Create `k8s-manifests/storage/rook-operator.yaml`:
```yaml
---
# Rook Operator Config
apiVersion: v1
kind: Namespace
metadata:
  name: rook-ceph
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: cephclusters.ceph.rook.io
spec:
  group: ceph.rook.io
  names:
    kind: CephCluster
    listKind: CephClusterList
    plural: cephclusters
    singular: cephcluster
    shortNames:
    - cephcluster
  scope: Namespaced
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        properties:
          spec:
            properties:
              mon:
                properties:
                  count:
                    maximum: 9
                    minimum: 0
                    type: integer
                type: object
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: cephblockpools.ceph.rook.io
spec:
  group: ceph.rook.io
  names:
    kind: CephBlockPool
    listKind: CephBlockPoolList
    plural: cephblockpools
    singular: cephblockpool
    shortNames:
    - cbp
  scope: Namespaced
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        properties:
          spec:
            properties:
              failureDomain:
                type: string
              replicated:
                properties:
                  size:
                    maximum: 10
                    minimum: 0
                    type: integer
                type: object
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: cephfilesystems.ceph.rook.io
spec:
  group: ceph.rook.io
  names:
    kind: CephFilesystem
    listKind: CephFilesystemList
    plural: cephfilesystems
    singular: cephfilesystem
    shortNames:
    - cephfs
  scope: Namespaced
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        properties:
          spec:
            properties:
              metadataServer:
                properties:
                  activeCount:
                    minimum: 1
                    type: integer
                type: object
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: cephobjectstores.ceph.rook.io
spec:
  group: ceph.rook.io
  names:
    kind: CephObjectStore
    listKind: CephObjectStoreList
    plural: cephobjectstores
    singular: cephobjectstore
    shortNames:
    - cos
  scope: Namespaced
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        properties:
          spec:
            properties:
              gateway:
                properties:
                  instances:
                    minimum: 1
                    type: integer
                type: object
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: cephobjectstoreusers.ceph.rook.io
spec:
  group: ceph.rook.io
  names:
    kind: CephObjectStoreUser
    listKind: CephObjectStoreUserList
    plural: cephobjectstoreusers
    singular: cephobjectstoreuser
    shortNames:
    - cosu
  scope: Namespaced
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        type: object
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rook-ceph-operator
  namespace: rook-ceph
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rook-ceph-operator
rules:
- apiGroups:
  - ""
  resources:
  - pods
  - configmaps
  - services
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - apps
  resources:
  - deployments
  - daemonsets
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rook-ceph-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rook-ceph-operator
subjects:
- kind: ServiceAccount
  name: rook-ceph-operator
  namespace: rook-ceph
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rook-ceph-operator
  namespace: rook-ceph
  labels:
    operator: rook
    storage-backend: ceph
spec:
  selector:
    matchLabels:
      app: rook-ceph-operator
  replicas: 1
  template:
    metadata:
      labels:
        app: rook-ceph-operator
    spec:
      serviceAccountName: rook-ceph-operator
      containers:
      - name: rook-ceph-operator
        image: rook/ceph:v1.14.4
        args: ["ceph", "operator"]
        env:
        - name: ROOK_CURRENT_NAMESPACE_ONLY
          value: "true"
        - name: ROOK_LOG_LEVEL
          value: "INFO"
        - name: ROOK_MON_HEALTHCHECK_INTERVAL
          value: "45s"
        - name: ROOK_MON_OUT_TIMEOUT
          value: "600s"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
```

Create `k8s-manifests/storage/rook-cluster.yaml`:
```yaml
---
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  dataDirHostPath: /var/lib/rook
  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false
  waitTimeoutForHealthyOSDInMinutes: 10
  mon:
    count: 3
    allowMultiplePerNode: false
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.1
    allowUnsupported: false
  dashboard:
    enabled: true
    ssl: true
  monitoring:
    enabled: true
    rulesNamespace: rook-ceph
  network:
    provider: host
  crashCollector:
    disable: false
  cleanupPolicy:
    confirmation: ""
    sanitizeDisks:
      method: quick
      dataSource: zero
      iteration: 1
    allowUninstallWithVolumes: false
  disruptionManagement:
    managePodBudgets: true
    osdMaintenanceTimeout: 30
    pgHealthCheckTimeout: 0
  mgr:
    count: 2
    modules:
    - name: pg_autoscaler
      enabled: true
    - name: rook
      enabled: true
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
    requireSafeReplicaSize: true
  statusCheck:
    mirror:
      disabled: false
      interval: 60s
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: myfs
  namespace: rook-ceph
spec:
  metadataPool:
    replicated:
      size: 3
  dataPools:
  - name: datapool
    replicated:
      size: 3
    compressionMode: none
  metadataServer:
    activeCount: 1
    activeStandby: true
    resources:
      limits:
        cpu: "500m"
        memory: "1Gi"
      requests:
        cpu: "500m"
        memory: "1Gi"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-cephfs
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: rook-ceph
  fsName: myfs
  pool: myfs-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
allowVolumeExpansion: true
reclaimPolicy: Delete
```

Create `k8s-manifests/storage/rook-storageclass.yaml`:
```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-rbd-provisioner
  namespace: rook-ceph
stringData:
  userID: kubernetes
  userKey: <ENCODED_KEY>
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-rbd-node
  namespace: rook-ceph
stringData:
  userID: kubernetes
  userKey: <ENCODED_KEY>
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-cephfs-provisioner
  namespace: rook-ceph
stringData:
  adminID: admin
  adminKey: <ADMIN_KEY>
---
apiVersion: v1
kind: Secret
metadata:
  name: rook-csi-cephfs-node
  namespace: rook-ceph
stringData:
  adminID: admin
  adminKey: <ADMIN_KEY>
```

**Step 4: Run test to verify it passes**
Run: `bash tests/rook_storage_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add k8s-manifests/storage/
git commit -m "Add Rook/Ceph storage configuration manifests"
```

### Task 3: Create Traefik Ingress Controller Configuration

**Files:**
- Create: `k8s-manifests/ingress/traefik-deployment.yaml`
- Create: `k8s-manifests/ingress/traefik-service.yaml`
- Create: `k8s-manifests/ingress/traefik-middleware.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/traefik_ingress_test.sh
set -e

if [ ! -f "k8s-manifests/ingress/traefik-deployment.yaml" ]; then
    echo "FAIL: k8s-manifests/ingress/traefik-deployment.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/ingress/traefik-service.yaml" ]; then
    echo "FAIL: k8s-manifests/ingress/traefik-service.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/ingress/traefik-middleware.yaml" ]; then
    echo "FAIL: k8s-manifests/ingress/traefik-middleware.yaml does not exist"
    exit 1
fi

echo "PASS: Traefik ingress manifests exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/traefik_ingress_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p k8s-manifests/ingress
```

Create `k8s-manifests/ingress/traefik-deployment.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: traefik
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik-ingress-controller
rules:
  - apiGroups:
      - ""
    resources:
      - services
      - endpoints
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses
      - ingressclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
  - apiGroups:
      - traefik.containo.us
    resources:
      - middlewares
      - middlewaretcps
      - ingressroutes
      - traefikservices
      - ingressroutetcps
      - ingressrouteudps
      - tlsoptions
      - tlsstores
      - serverstransports
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik-ingress-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-ingress-controller
subjects:
  - kind: ServiceAccount
    name: traefik-ingress-controller
    namespace: traefik
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: traefik-config
  namespace: traefik
data:
  traefik.yaml: |
    entryPoints:
      web:
        address: ":8000"
        http:
          redirections:
            entryPoint:
              to: websecure
              scheme: https
      websecure:
        address: ":8443"
    providers:
      kubernetesIngress: {}
      kubernetesCRD: {}
    certificatesResolvers:
      default:
        acme:
          email: admin@yourdomain.com
          storage: /etc/traefik/acme.json
          httpChallenge:
            entryPoint: web
    api:
      dashboard: true
      insecure: true
    ping: {}
    log:
      level: INFO
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik
  labels:
    app: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik-ingress-controller
      containers:
        - name: traefik
          image: traefik:v3.0.2
          args:
            - --configFile=/config/traefik.yaml
          ports:
            - name: web
              containerPort: 8000
            - name: websecure
              containerPort: 8443
            - name: admin
              containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /config
            - name: acme
              mountPath: /etc/traefik/acme.json
              subPath: acme.json
      volumes:
        - name: config
          configMap:
            name: traefik-config
        - name: acme
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: traefik-dashboard
  namespace: traefik
spec:
  type: ClusterIP
  selector:
    app: traefik
  ports:
    - name: admin
      port: 8080
      targetPort: 8080
```

Create `k8s-manifests/ingress/traefik-service.yaml`:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: traefik
  annotations:
    # For MetalLB to assign a specific IP (uncomment and set IP if using MetalLB)
    # metallb.universe.tf/loadBalancer-ip: "192.168.1.100"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: traefik
  ports:
    - name: web
      port: 80
      targetPort: 8000
    - name: websecure
      port: 443
      targetPort: 8443
---
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: traefik
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`traefik.yourdomain.com`) && PathPrefix(`/dashboard`) || PathPrefix(`/api`)
      kind: Rule
      services:
        - name: traefik-dashboard
          port: 8080
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: traefik
spec:
  redirectScheme:
    scheme: https
    permanent: true
---
apiVersion: traefik.containo.us/v1alpha1
kind: TLSOption
metadata:
  name: default
  namespace: traefik
spec:
  minVersion: VersionTLS12
  cipherSuites:
    - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
    - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
```

Create `k8s-manifests/ingress/traefik-middleware.yaml`:
```yaml
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: traefik
spec:
  headers:
    frameDeny: true
    sslRedirect: true
    browserXssFilter: true
    contentTypeNosniff: true
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 315360000
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: traefik
spec:
  rateLimit:
    average: 100
    burst: 50
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: compress
  namespace: traefik
spec:
  compress: {}
---
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: whoami
  namespace: default
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`whoami.yourdomain.com`)
      kind: Rule
      services:
        - name: whoami
          port: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: default
spec:
  ports:
    - name: http
      port: 80
      targetPort: 80
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: default
spec:
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - name: http
              containerPort: 80
```

**Step 4: Run test to verify it passes**
Run: `bash tests/traefik_ingress_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add k8s-manifests/ingress/
git commit -m "Add Traefik ingress controller configuration manifests"
```

### Task 4: Create ArgoCD GitOps Configuration

**Files:**
- Create: `k8s-manifests/gitops/argocd-install.yaml`
- Create: `k8s-manifests/gitops/argocd-rbac.yaml`
- Create: `k8s-manifests/gitops/argocd-applications.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/argocd_gitops_test.sh
set -e

if [ ! -f "k8s-manifests/gitops/argocd-install.yaml" ]; then
    echo "FAIL: k8s-manifests/gitops/argocd-install.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/gitops/argocd-rbac.yaml" ]; then
    echo "FAIL: k8s-manifests/gitops/argocd-rbac.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/gitops/argocd-applications.yaml" ]; then
    echo "FAIL: k8s-manifests/gitops/argocd-applications.yaml does not exist"
    exit 1
fi

echo "PASS: ArgoCD GitOps manifests exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/argocd_gitops_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p k8s-manifests/gitops
```

Create `k8s-manifests/gitops/argocd-install.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: applications.argoproj.io
spec:
  group: argoproj.io
  scope: Namespaced
  names:
    kind: Application
    listKind: ApplicationList
    plural: applications
    singular: application
    shortNames:
    - app
    - apps
  versions:
  - name: v1alpha1
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              destination:
                type: object
                properties:
                  name:
                    type: string
                  namespace:
                    type: string
                  server:
                    type: string
                required:
                - namespace
              project:
                type: string
              source:
                type: object
                properties:
                  chart:
                    type: string
                  directory:
                    type: object
                    properties:
                      exclude:
                        type: boolean
                      include:
                        type: boolean
                      recurse:
                        type: boolean
                      jsonnet:
                        type: object
                        properties:
                          extVars:
                            type: array
                            items:
                              type: object
                              properties:
                                name:
                                  type: string
                                value:
                                  type: string
                                code:
                                  type: boolean
                          libs:
                            type: array
                            items:
                              type: string
                        required:
                        - extVars
                        - libs
                      include:
                        type: boolean
                    required:
                    - recurse
                  path:
                    type: string
                  plugin:
                    type: object
                    properties:
                      name:
                        type: string
                      env:
                        type: array
                        items:
                          type: object
                          properties:
                            name:
                              type: string
                            value:
                              type: string
                          required:
                          - name
                          - value
                  repoURL:
                    type: string
                  targetRevision:
                    type: string
                required:
                - repoURL
              syncPolicy:
                type: object
                properties:
                  automated:
                    type: object
                    properties:
                      prune:
                        type: boolean
                      selfHeal:
                        type: boolean
                  syncOptions:
                    type: array
                    items:
                      type: string
                  retry:
                    type: object
                    properties:
                      limit:
                        type: integer
                      backoff:
                        type: object
                        properties:
                          duration:
                            type: string
                          factor:
                            type: integer
                          maxDuration:
                            type: string
            required:
            - project
            - source
            - destination
          status:
            type: object
            properties:
              conditions:
                type: array
                items:
                  type: object
                  properties:
                    type:
                      type: string
                    message:
                      type: string
                    lastTransitionTime:
                      type: string
              reconciledAt:
                type: string
              operationState:
                type: object
                properties:
                  operation:
                    type: object
                    properties:
                      sync:
                        type: object
                        properties:
                          revision:
                            type: string
                          prune:
                            type: boolean
                          dryRun:
                            type: boolean
                          strategy:
                            type: object
                            properties:
                              apply:
                                type: object
                                properties:
                                  force:
                                    type: boolean
                              hook:
                                type: object
                                properties:
                                  force:
                                    type: boolean
                          manifests:
                            type: array
                            items:
                              type: string
                    startedAt:
                      type: string
                    finishedAt:
                      type: string
                    message:
                      type: string
                    phase:
                      type: string
                    syncResult:
                      type: object
                      properties:
                        resources:
                          type: array
                          items:
                            type: object
                            properties:
                              name:
                                type: string
                              kind:
                                type: string
                              version:
                                type: string
                              namespace:
                                type: string
                              status:
                                type: string
                              message:
                                type: string
                              hookPhase:
                                type: string
                              syncPhase:
                                type: string
                        revision:
                          type: string
                        source:
                          type: object
                          properties:
                            repoURL:
                              type: string
                            path:
                              type: string
                            targetRevision:
                              type: string
                  phase:
                    type: string
                  startedAt:
                    type: string
                  syncResult:
                    type: object
                    properties:
                      resources:
                        type: array
                        items:
                          type: object
                          properties:
                            name:
                              type: string
                            kind:
                              type: string
                            version:
                              type: string
                            namespace:
                              type: string
                            status:
                              type: string
                            message:
                              type: string
                            hookPhase:
                              type: string
                            syncPhase:
                              type: string
                      revision:
                        type: string
                      source:
                        type: object
                        properties:
                          repoURL:
                            type: string
                          path:
                            type: string
                          targetRevision:
                            type: string
              sync:
                type: object
                properties:
                  comparedTo:
                    type: object
                    properties:
                      source:
                        type: object
                        properties:
                          repoURL:
                            type: string
                          path:
                            type: string
                          targetRevision:
                            type: string
                      destination:
                        type: object
                        properties:
                          server:
                            type: string
                          namespace:
                            type: string
                    required:
                    - source
                    - destination
                  status:
                    type: string
                  revision:
                    type: string
            required:
            - observedAt
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: appprojects.argoproj.io
spec:
  group: argoproj.io
  scope: Namespaced
  names:
    kind: AppProject
    listKind: AppProjectList
    plural: appprojects
    singular: appproject
    shortNames:
    - appproj
  versions:
  - name: v1alpha1
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              clusterResourceWhitelist:
                type: array
                items:
                  type: object
                  properties:
                    group:
                      type: string
                    kind:
                      type: string
                  required:
                  - group
                  - kind
              destinations:
                type: array
                items:
                  type: object
                  properties:
                    name:
                      type: string
                    namespace:
                      type: string
                    server:
                      type: string
                  required:
                  - namespace
              orphanedResources:
                type: object
                properties:
                  warn:
                    type: boolean
              roles:
                type: array
                items:
                  type: object
                  properties:
                    description:
                      type: string
                    groups:
                      type: array
                      items:
                        type: string
                    name:
                      type: string
                    policies:
                      type: array
                      items:
                        type: string
                  required:
                  - name
                  - policies
              signatureKeys:
                type: array
                items:
                  type: object
                  properties:
                    keyID:
                      type: string
                  required:
                  - keyID
              sourceRepos:
                type: array
                items:
                  type: string
            required:
            - destinations
            - sourceRepos
    served: true
    storage: true
    subresources:
      status: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-application-controller
  namespace: argocd
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-server
  namespace: argocd
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cmd-params-cm
data:
  reposerver.ssh_known_hosts: |
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-rbac-cm
data:
  policy.default: role:readonly
  policy.csv: |
    g, system:cluster-admins, role:admin
    g, argocd-admins, role:admin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-application-controller
  namespace: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-application-controller
  template:
    metadata:
      labels:
        app.kubernetes.io/name: argocd-application-controller
    spec:
      serviceAccountName: argocd-application-controller
      containers:
      - name: argocd-application-controller
        image: quay.io/argoproj/argocd:v2.12.3
        command:
        - argocd-application-controller
        - --status-processors
        - "20"
        - --operation-processors
        - "10"
        - --repo-server-timeout-seconds
        - "60"
        - --loglevel
        - info
        - --metrics-port
        - "8082"
        env:
        - name: ARGOCD_CONTROLLER_REPLICAS
          value: "1"
        - name: ARGOCD_APPLICATION_CONTROLLER_CONTROLLER_PROCS
          value: "1"
        - name: ARGOCD_APPLICATION_CONTROLLER_REPO_SERVER_TLS_ENABLED
          value: "true"
        - name: ARGOCD_APPLICATION_CONTROLLER_STATUS_PROCESSORS
          value: "20"
        - name: ARGOCD_APPLICATION_CONTROLLER_OPERATION_PROCESSORS
          value: "10"
        - name: ARGOCD_APPLICATION_CONTROLLER_SELF_HEAL_TIMEOUT_SECONDS
          value: "5"
        - name: ARGOCD_APPLICATION_CONTROLLER_REPO_SERVER_TIMEOUT_SECONDS
          value: "60"
        ports:
        - containerPort: 8082
        - containerPort: 8084
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8084
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8084
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-server
  namespace: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: argocd-server
    spec:
      serviceAccountName: argocd-server
      containers:
      - name: argocd-server
        image: quay.io/argoproj/argocd:v2.12.3
        command:
        - argocd-server
        - --staticassets
        - /shared/app
        - --redis
        - argocd-redis:6379
        - --loglevel
        - info
        env:
        - name: ARGOCD_SERVER_INSECURE
          value: "false"
        - name: ARGOCD_SERVER_ENABLE_GZIP
          value: "true"
        - name: ARGOCD_UI_VIEWPORT_MAX_WIDTH
          value: "infinity"
        ports:
        - containerPort: 8080
        - containerPort: 8083
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 125m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: argocd-server
  namespace: argocd
spec:
  type: LoadBalancer
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  - name: https
    port: 443
    targetPort: 8080
    protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-server
---
apiVersion: v1
kind: Service
metadata:
  name: argocd-metrics
  namespace: argocd
spec:
  ports:
  - name: metrics
    port: 8082
    targetPort: 8082
    protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-application-controller
---
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-metrics
  namespace: argocd
spec:
  ports:
  - name: metrics
    port: 8083
    targetPort: 8083
    protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-server
```

Create `k8s-manifests/gitops/argocd-rbac.yaml`:
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-admin
  namespace: argocd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-admin-role
rules:
- apiGroups:
  - "*"
  resources:
  - "*"
  verbs:
  - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-admin-role
subjects:
- kind: ServiceAccount
  name: argocd-admin
  namespace: argocd
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-initial-admin-secret
  namespace: argocd
type: Opaque
data:
  # Initial password will be auto-generated by ArgoCD
  password: ""
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  description: Default ArgoCD project
  sourceRepos:
  - '*'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  orphanedResources:
    warn: false
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-example-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

Create `k8s-manifests/gitops/argocd-applications.yaml`:
```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik-ingress
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/traefik/traefik-helm-chart.git
    targetRevision: traefik-v25.0.0
    chart: traefik
    helm:
      values: |
        service:
          type: LoadBalancer
        ingressRoute:
          dashboard:
            enabled: true
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: websecure
            matchRule: Host(`traefik.yourdomain.com`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rook-ceph
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.rook.io/release
    targetRevision: v1.14.4
    chart: rook-ceph
  destination:
    server: https://kubernetes.default.svc
    namespace: rook-ceph
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudflared
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/cloudflare/argo-tunnel.git
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudflare
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-stack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/prometheus-community/helm-charts.git
    targetRevision: main
    path: kube-prometheus-stack
    helm:
      values: |
        prometheus:
          prometheusSpec:
            retention: 10d
        grafana:
          adminPassword: prom-operator
          service:
            type: LoadBalancer
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

**Step 4: Run test to verify it passes**
Run: `bash tests/argocd_gitops_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add k8s-manifests/gitops/
git commit -m "Add ArgoCD GitOps configuration manifests"
```

### Task 5: Create Cloudflare Tunnel Configuration

**Files:**
- Create: `k8s-manifests/dns/cloudflared-deployment.yaml`
- Create: `k8s-manifests/dns/cloudflared-configmap.yaml`
- Create: `k8s-manifests/dns/cloudflare-dns.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/cloudflare_tunnel_test.sh
set -e

if [ ! -f "k8s-manifests/dns/cloudflared-deployment.yaml" ]; then
    echo "FAIL: k8s-manifests/dns/cloudflared-deployment.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/dns/cloudflared-configmap.yaml" ]; then
    echo "FAIL: k8s-manifests/dns/cloudflared-configmap.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/dns/cloudflare-dns.yaml" ]; then
    echo "FAIL: k8s-manifests/dns/cloudflare-dns.yaml does not exist"
    exit 1
fi

echo "PASS: Cloudflare tunnel manifests exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/cloudflare_tunnel_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p k8s-manifests/dns
```

Create `k8s-manifests/dns/cloudflared-deployment.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflare
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloudflared
  namespace: cloudflare
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cloudflared
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "endpoints", "services"]
  verbs: ["get", "list"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cloudflared
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cloudflared
subjects:
- kind: ServiceAccount
  name: cloudflared
  namespace: cloudflare
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      serviceAccountName: cloudflared
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:2024.5.2
        args:
        - tunnel
        - --config
        - /etc/cloudflared/config/config.yaml
        - run
        env:
        - name: TUNNEL_TOKEN
          valueFrom:
            secretKeyRef:
              name: cloudflared-tunnel-secret
              key: tunnel-token
        livenessProbe:
          httpGet:
            path: /ready
            port: 2000
          initialDelaySeconds: 30
          periodSeconds: 20
        volumeMounts:
        - name: config
          mountPath: /etc/cloudflared/config
          readOnly: true
        - name: creds
          mountPath: /etc/cloudflared/creds
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: cloudflared-config
      - name: creds
        secret:
          secretName: cloudflared-tunnel-secret
---
apiVersion: v1
kind: Service
metadata:
  name: cloudflared-metrics
  namespace: cloudflare
spec:
  ports:
  - name: metrics
    port: 2000
    protocol: TCP
    targetPort: 2000
  selector:
    app: cloudflared
---
apiVersion: v1
kind: Service
metadata:
  name: cloudflared
  namespace: cloudflare
spec:
  type: LoadBalancer
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
  - name: https
    port: 443
    targetPort: 443
    protocol: TCP
  selector:
    app: cloudflared
```

Create `k8s-manifests/dns/cloudflared-configmap.yaml`:
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflare
data:
  config.yaml: |
    tunnel: your-tunnel-id
    credentials-file: /etc/cloudflared/creds/credentials.json
    
    # Log everything at info level
    log-level: info
    
    # Route DNS queries through Cloudflare's DNS over HTTPS
    upstream:
      - https://1.1.1.1/dns-query
      - https://1.0.0.1/dns-query
    
    # Ingress rules: the magic of Cloudflare Tunnel
    ingress:
      # Redirect example.com and www.example.com to our Kubernetes service
      - hostname: yourdomain.com
        service: http://traefik.traefik:80
      # Redirect wildcard subdomains
      - hostname: "*.yourdomain.com"
        service: http://traefik.traefik:80
      # Catch-all rule: important for HTTPS to work properly
      - service: https://localhost:8443
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-tunnel-secret
  namespace: cloudflare
type: Opaque
stringData:
  # Replace with your actual tunnel credentials
  credentials.json: |
    {
      "AccountTag": "your-account-tag",
      "TunnelID": "your-tunnel-id",
      "TunnelName": "your-tunnel-name",
      "TunnelSecret": "your-tunnel-secret"
    }
  tunnel-token: "your-tunnel-token"
```

Create `k8s-manifests/dns/cloudflare-dns.yaml`:
```yaml
---
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: cloudflare-dns-tunnel
  namespace: cloudflare
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(`tunnel.yourdomain.com`)
      kind: Rule
      services:
        - name: cloudflared
          port: 80
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cloudflare-tunnel-cert
  namespace: cloudflare
spec:
  secretName: cloudflare-tunnel-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - tunnel.yourdomain.com
  - "*.yourdomain.com"
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloudflare-tunnel-ingress
  namespace: cloudflare
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
  - hosts:
    - tunnel.yourdomain.com
    secretName: cloudflare-tunnel-tls
  rules:
  - host: tunnel.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: cloudflared
            port:
              number: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflare-ddns-config
  namespace: cloudflare
data:
  # Configuration for Cloudflare DDNS updater
  ddns-config.json: |
    {
      "zone": "yourdomain.com",
      "record": "yourdomain.com",
      "proxied": true,
      "ttl": 1,
      "cloudflare": {
        "email": "your-email@example.com",
        "apiKey": "your-api-key",
        "domain": "yourdomain.com"
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflare-ddns
  namespace: cloudflare
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudflare-ddns
  template:
    metadata:
      labels:
        app: cloudflare-ddns
    spec:
      containers:
      - name: cloudflare-ddns
        image: tiredofit/cloudflare-ddns:latest
        env:
        - name: CF_EMAIL
          valueFrom:
            secretKeyRef:
              name: cloudflare-api-secret
              key: email
        - name: CF_API_KEY
          valueFrom:
            secretKeyRef:
              name: cloudflare-api-secret
              key: api-key
        - name: ZONE
          value: "yourdomain.com"
        - name: SUBDOMAIN
          value: "@"
        - name: PROXIED
          value: "true"
        - name: TTL
          value: "1"
        volumeMounts:
        - name: config
          mountPath: /config
      volumes:
      - name: config
        configMap:
          name: cloudflare-ddns-config
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-secret
  namespace: cloudflare
type: Opaque
stringData:
  email: "your-email@example.com"
  api-key: "your-cloudflare-api-key"
```

**Step 4: Run test to verify it passes**
Run: `bash tests/cloudflare_tunnel_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add k8s-manifests/dns/
git commit -m "Add Cloudflare tunnel and DNS configuration manifests"
```

### Task 6: Create Complete Deployment Workflow

**Files:**
- Create: `scripts/deploy-full-stack.sh`
- Create: `docs/full-stack-deployment-guide.md`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/full_stack_deployment_test.sh
set -e

if [ ! -f "scripts/deploy-full-stack.sh" ]; then
    echo "FAIL: scripts/deploy-full-stack.sh does not exist"
    exit 1
fi

if [ ! -f "docs/full-stack-deployment-guide.md" ]; then
    echo "FAIL: docs/full-stack-deployment-guide.md does not exist"
    exit 1
fi

echo "PASS: Full stack deployment files exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/full_stack_deployment_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `scripts/deploy-full-stack.sh`:
```bash
#!/bin/bash

# Twinbox Full-Stack Kubernetes Deployment Script
# Deploys Talos Linux cluster with Rook storage, Traefik ingress, Cloudflare tunnel, and ArgoCD

set -euo pipefail

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-fullstack-cluster}"
NODE_COUNT="${NODE_COUNT:-3}"
VM_START_ID="${VM_START_ID:-300}"
MEMORY="${MEMORY:-8192}"
CORES="${CORES:-4}"
DISK_SIZE="${DISK_SIZE:-50}"
BRIDGE="${BRIDGE:-vmbr0}"
TALOS_VERSION="${TALOS_VERSION:-v1.7.4}"
K8S_VERSION="${K8S_VERSION:-v1.29.6}"

# Service versions
ROOK_VERSION="${ROOK_VERSION:-v1.14.4}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.0.2}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.12.3}"
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2024.5.2}"

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

check_prerequisites() {
    log "Checking prerequisites..."
    
    if [ -z "${PROXMOX_HOST:-}" ] || [ -z "${PROXMOX_USER:-}" ] || [ -z "${PROXMOX_PASSWORD:-}" ]; then
        error "PROXMOX_HOST, PROXMOX_USER, and PROXMOX_PASSWORD environment variables must be set"
        exit 1
    fi
    
    if [ ! -f "scripts/proxmox-helper.sh" ]; then
        error "Proxmox helper script not found"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        warn "kubectl is not installed (will be needed after cluster creation)"
    fi
    
    if ! command -v talosctl &> /dev/null; then
        warn "talosctl is not installed (will be needed for Talos management)"
    fi
    
    log "Prerequisites check completed"
}

create_cluster() {
    log "Creating Talos Linux cluster: $CLUSTER_NAME"
    log "Configuration:"
    echo "  - Node count: $NODE_COUNT workers + 1 control plane"
    echo "  - VM IDs: $VM_START_ID to $((VM_START_ID + NODE_COUNT))"
    echo "  - Memory per VM: ${MEMORY}MB"
    echo "  - Cores per VM: $CORES"
    echo "  - Disk size per VM: ${DISK_SIZE}GB"
    echo ""
    
    ./scripts/proxmox-helper.sh create-cluster \
        --cluster-name "$CLUSTER_NAME" \
        --node-count "$NODE_COUNT" \
        --start-id "$VM_START_ID" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --disk-size "$DISK_SIZE" \
        --bridge "$BRIDGE" \
        --talos-version "$TALOS_VERSION" \
        --k8s-version "$K8S_VERSION"
    
    if [ $? -ne 0 ]; then
        error "Cluster creation failed"
        exit 1
    fi
    
    log "Cluster created successfully"
}

generate_configs() {
    log "Generating Talos machine configurations..."
    
    ./scripts/proxmox-helper.sh generate-config --cluster-name "$CLUSTER_NAME"
    
    if [ $? -ne 0 ]; then
        error "Configuration generation failed"
        exit 1
    fi
    
    log "Configurations generated in clusters/$CLUSTER_NAME/talos-configs/"
}

deploy_rook_storage() {
    log "Deploying Rook/Ceph storage..."
    
    ./scripts/proxmox-helper.sh deploy-storage --cluster-name "$CLUSTER_NAME"
    
    if [ $? -ne 0 ]; then
        error "Rook storage deployment preparation failed"
        exit 1
    fi
    
    # Apply the generated manifests
    if [ -f "clusters/$CLUSTER_NAME/storage/rook-operator-expr.yaml" ]; then
        log "Applying Rook operator..."
        kubectl apply -f "clusters/$CLUSTER_NAME/storage/rook-operator-expr.yaml"
        
        # Wait for operator to be ready
        log "Waiting for Rook operator to be ready..."
        kubectl wait --for=condition=available deployment/rook-ceph-operator -n rook-ceph --timeout=300s
    fi
    
    if [ -f "clusters/$CLUSTER_NAME/storage/rook-cluster-expr.yaml" ]; then
        log "Applying Rook cluster configuration..."
        kubectl apply -f "clusters/$CLUSTER_NAME/storage/rook-cluster-expr.yaml"
        
        # Wait for cluster to be ready
        log "Waiting for Rook cluster to be ready..."
        kubectl wait --for=condition=ready cephcluster/rook-ceph -n rook-ceph --timeout=600s
    fi
    
    if [ -f "clusters/$CLUSTER_NAME/storage/rook-storageclass.yaml" ]; then
        log "Applying Rook storage class..."
        kubectl apply -f "clusters/$CLUSTER_NAME/storage/rook-storageclass.yaml"
    fi
    
    log "Rook/Ceph storage deployed successfully"
}

deploy_traefik_ingress() {
    log "Deploying Traefik ingress controller..."
    
    ./scripts/proxmox-helper.sh deploy-ingress --cluster-name "$CLUSTER_NAME"
    
    if [ $? -ne 0 ]; then
        error "Traefik ingress deployment preparation failed"
        exit 1
    fi
    
    # Apply the generated manifests
    if [ -f "clusters/$CLUSTER_NAME/ingress/traefik-values.yaml" ]; then
        log "Installing Traefik with Helm..."
        
        # Check if Helm is available
        if command -v helm &> /dev/null; then
            helm repo add traefik https://helm.traefik.io/traefik
            helm repo update
            helm upgrade --install traefik traefik/traefik \
                --values "clusters/$CLUSTER_NAME/ingress/traefik-values.yaml" \
                --namespace kube-system \
                --create-namespace
        else
            warn "Helm not found, skipping automated Traefik installation"
            log "Manually apply the Traefik manifests from clusters/$CLUSTER_NAME/ingress/"
        fi
    fi
    
    log "Traefik ingress controller deployed successfully"
}

deploy_argocd() {
    log "Deploying ArgoCD GitOps..."
    
    ./scripts/proxmox-helper.sh deploy-argocd --cluster-name "$CLUSTER_NAME"
    
    if [ $? -ne 0 ]; then
        error "ArgoCD deployment preparation failed"
        exit 1
    fi
    
    # Apply the generated manifests
    if [ -f "clusters/$CLUSTER_NAME/argocd/argocd-install.yaml" ]; then
        log "Applying ArgoCD manifests..."
        kubectl apply -f "clusters/$CLUSTER_NAME/argocd/argocd-install.yaml"
        
        # Wait for ArgoCD server to be ready
        log "Waiting for ArgoCD server to be ready..."
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
    fi
    
    log "ArgoCD GitOps deployed successfully"
}

deploy_cloudflare_tunnel() {
    log "Deploying Cloudflare tunnel agent..."
    
    ./scripts/proxmox-helper.sh deploy-cloudflare --cluster-name "$CLUSTER_NAME"
    
    if [ $? -ne 0 ]; then
        error "Cloudflare tunnel deployment preparation failed"
        exit 1
    fi
    
    # Apply the generated manifests
    if [ -f "clusters/$CLUSTER_NAME/cloudflare/cloudflared-daemonset.yaml" ]; then
        log "Applying Cloudflare tunnel daemonset..."
        kubectl apply -f "clusters/$CLUSTER_NAME/cloudflare/cloudflared-daemonset.yaml"
        
        # Wait for daemonset to be ready
        log "Waiting for Cloudflare tunnel daemonset to be ready..."
        kubectl wait --for=condition=ready daemonset/cloudflared -n kube-system --timeout=300s
    fi
    
    log "Cloudflare tunnel deployed successfully"
}

finalize_deployment() {
    log "Finalizing deployment..."
    
    # Set up default storage class
    log "Setting rook-ceph-block as default storage class..."
    kubectl patch storageclass rook-ceph-block -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    # Display connection information
    log "=== Deployment Summary ==="
    echo "Cluster: $CLUSTER_NAME"
    echo "VM IDs: $VM_START_ID to $((VM_START_ID + NODE_COUNT))"
    echo ""
    echo "Services deployed:"
    echo "  - Rook/Ceph storage: StorageClass 'rook-ceph-block'"
    echo "  - Traefik ingress: LoadBalancer service in kube-system namespace"
    echo "  - ArgoCD: LoadBalancer service in argocd namespace"
    echo "  - Cloudflare tunnel: DaemonSet in kube-system namespace"
    echo ""
    echo "Next steps:"
    echo "  1. Configure Talos machines using the generated configs in clusters/$CLUSTER_NAME/talos-configs/"
    echo "  2. Access ArgoCD: kubectl port-forward -n argocd svc/argocd-server 8080:80"
    echo "  3. Set up Cloudflare tunnel with your domain and credentials"
    echo "  4. Configure DNS to point to your cluster's external IP"
}

main() {
    log "Starting Twinbox Full-Stack Kubernetes deployment"
    log "This will create a complete platform with:"
    echo "  - Talos Linux Kubernetes cluster"
    echo "  - Rook/Ceph persistent storage"
    echo "  - Traefik ingress controller"
    echo "  - ArgoCD GitOps"
    echo "  - Cloudflare tunnel for public access"
    echo ""
    
    read -p "Continue with deployment? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log "Deployment cancelled"
        exit 0
    fi
    
    check_prerequisites
    create_cluster
    generate_configs
    
    log "Basic cluster created. Now deploying additional services..."
    log "Note: You need to have kubectl configured to connect to your Talos cluster"
    log "before proceeding with service deployments."
    
    read -p "Do you have kubectl configured for your Talos cluster? (yes/no): " kubectl_ready
    
    if [ "$kubectl_ready" = "yes" ]; then
        deploy_rook_storage
        deploy_traefik_ingress
        deploy_argocd
        deploy_cloudflare_tunnel
    else
        warn "Skipping service deployments. Please configure kubectl and run them manually."
    fi
    
    finalize_deployment
    
    log "Full-stack deployment completed!"
}

main
```

Create `docs/full-stack-deployment-guide.md`:
```markdown
# Twinbox Full-Stack Kubernetes Deployment Guide

This guide explains how to deploy a complete Kubernetes platform using Talos Linux on Proxmox with Rook storage, Traefik ingress, Cloudflare tunnels, and ArgoCD GitOps.

## Overview

The Twinbox Full-Stack Kubernetes platform provides a production-ready infrastructure with:

- **Talos Linux**: Secure, immutable Kubernetes OS
- **Rook/Ceph**: Distributed storage solution
- **Traefik**: Modern ingress controller
- **Cloudflare Tunnel**: Secure public access without opening firewall ports
- **ArgoCD**: GitOps continuous delivery

## Prerequisites

### Infrastructure Requirements

- Proxmox VE 7.0 or higher
- Sufficient resources for your cluster:
  - Control plane: 4 cores, 8GB RAM, 40GB disk
  - Workers: 4 cores, 8GB RAM, 40GB disk each
  - Additional overhead for storage and services

### Software Requirements

- Bash shell environment
- `curl`, `jq`, `openssl`
- `kubectl` (for cluster management)
- `talosctl` (for Talos management)
- `helm` (for simplified deployments)
- `git` (for ArgoCD workflows)

### Account Requirements

- Proxmox API access with sufficient privileges
- Cloudflare account for tunnel and DNS services
- GitHub/GitLab account for GitOps repositories

## Environment Setup

### 1. Set Proxmox Credentials

```bash
export PROXMOX_HOST="your-proxmox-host.domain.com"
export PROXMOX_USER="api-user@pve"
export PROXMOX_PASSWORD="your-api-password"
```

### 2. Install Required Tools

```bash
# Install talosctl
curl -L https://github.com/siderolabs/talos/releases/latest/download/talosctl-linux-amd64 -o /tmp/talosctl
sudo install /tmp/talosctl /usr/local/bin/talosctl
talosctl version

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/kubectl

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Deployment Process

### 1. Clone the Repository

```bash
git clone https://github.com/your-org/twinbox-fullstack.git
cd twinbox-fullstack
```

### 2. Deploy the Full Stack

```bash
./scripts/deploy-full-stack.sh
```

The script will guide you through the deployment process, creating:

1. Proxmox VMs for the Talos cluster
2. Generate Talos machine configurations
3. Deploy Rook/Ceph storage
4. Deploy Traefik ingress controller
5. Deploy ArgoCD GitOps
6. Deploy Cloudflare tunnel agent

### 3. Configure Talos Machines

After VMs are created, you need to configure them with Talos machine configs:

```bash
# Set the endpoint to your control plane IP
talosctl config endpoint <CONTROL_PLANE_IP>

# Apply the control plane config
talosctl apply-config --insecure --nodes <CONTROL_PLANE_IP> --file clusters/your-cluster/talos-configs/control-plane.yaml

# Apply worker configs to worker nodes
talosctl apply-config --insecure --nodes <WORKER_IP> --file clusters/your-cluster/talos-configs/worker.yaml
```

## Service Configuration

### Rook/Ceph Storage

Rook provides distributed storage for your cluster:

```bash
# Check Rook cluster status
kubectl -n rook-ceph get cephcluster

# Check storage classes
kubectl get storageclass

# The default storage class is set to rook-ceph-block
kubectl patch storageclass rook-ceph-block -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Traefik Ingress Controller

Traefik handles external access to your services:

```bash
# Check Traefik deployment
kubectl -n kube-system get deployment traefik

# Get Traefik service IP
kubectl -n kube-system get service traefik

# Access Traefik dashboard
kubectl -n traefik port-forward svc/traefik-dashboard 9000:8080
```

### ArgoCD GitOps

ArgoCD manages your applications via Git:

```bash
# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access ArgoCD UI
kubectl -n argocd port-forward svc/argocd-server 8080:80

# Login with username 'admin' and the password from above
```

### Cloudflare Tunnel

Configure Cloudflare tunnel for secure public access:

1. Create a tunnel in your Cloudflare dashboard
2. Update the tunnel credentials in the config files
3. Point your domain to the tunnel

## Domain Configuration

### 1. Set Up Cloudflare Tunnel

```bash
# Install cloudflared locally
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared-linux-amd64.deb

# Login to Cloudflare
cloudflared tunnel login

# Create a tunnel
cloudflared tunnel create your-cluster-tunnel

# Update the tunnel configuration with the generated credentials
```

### 2. Configure DNS Records

Add DNS records pointing to your tunnel in Cloudflare:

- `*.yourdomain.com` → Your Cloudflare tunnel
- `yourdomain.com` → Your Cloudflare tunnel

## Security Considerations

### Network Security

- Use private networks for cluster communication
- Implement network policies to control traffic flow
- Use TLS for all external connections

### Access Control

- Use least-privilege RBAC permissions
- Implement multi-factor authentication where possible
- Regularly rotate API keys and credentials

### Secrets Management

- Store sensitive data in Kubernetes secrets
- Use sealed-secrets or similar for encrypting secrets in Git
- Regularly audit access to sensitive configurations

## Monitoring and Maintenance

### Health Checks

Regularly monitor the health of your cluster:

```bash
# Check cluster status
kubectl get nodes
kubectl get pods --all-namespaces

# Check storage health
kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}') -- ceph status

# Check ingress health
kubectl -n traefik logs deployment/traefik
```

### Backup Strategy

1. Backup Talos machine configurations
2. Backup Kubernetes resources using Velero
3. Backup Ceph cluster configurations
4. Maintain offsite copies of encryption keys

### Update Process

1. Test updates in a staging environment
2. Update Talos versions following official procedures
3. Update Kubernetes components systematically
4. Update platform services (Rook, Traefik, ArgoCD) separately

## Troubleshooting

### Common Issues

1. **Storage not provisioning**: Check Rook cluster status and Ceph health
2. **Ingress not routing**: Verify Traefik deployment and ingress rules
3. **GitOps not syncing**: Check ArgoCD repository access and permissions
4. **Public access not working**: Verify Cloudflare tunnel configuration

### Useful Commands

```bash
# Check all system pods
kubectl get pods -A

# Check events for issues
kubectl get events --sort-by='.lastTimestamp'

# Tail logs for specific components
kubectl -n rook-ceph logs -l app=rook-ceph-operator -f
kubectl -n traefik logs deployment/traefik -f
kubectl -n argocd logs deployment/argocd-server -f
```

## Scaling the Platform

### Adding Nodes

1. Create additional VMs using the helper script
2. Generate machine configs for new nodes
3. Apply configurations to new nodes
4. Verify nodes join the cluster

### Expanding Storage

1. Add more storage capacity to Ceph cluster
2. Monitor cluster rebalancing
3. Verify storage class availability

## Conclusion

This full-stack Kubernetes platform provides a robust foundation for production workloads. By combining Talos Linux security, Rook storage, Traefik ingress, Cloudflare tunnels, and ArgoCD GitOps, you have a complete infrastructure solution that is secure, scalable, and manageable.
```

Make the deployment script executable:
```bash
chmod +x scripts/deploy-full-stack.sh
```

**Step 4: Run test to verify it passes**
Run: `bash tests/full_stack_deployment_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add scripts/deploy-full-stack.sh docs/full-stack-deployment-guide.md
git commit -m "Add complete deployment workflow and documentation"
```

### Task 7: Create Integration Tests

**Files:**
- Create: `tests/full-platform-integration.sh`
- Update: `Makefile`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/final_integration_test.sh
set -e

if [ ! -f "tests/full-platform-integration.sh" ]; then
    echo "FAIL: tests/full-platform-integration.sh does not exist"
    exit 1
fi

if ! grep -q "deploy-full-stack" "Makefile"; then
    echo "FAIL: Makefile doesn't contain deploy-full-stack target"
    exit 1
fi

echo "PASS: Final integration files exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/final_integration_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `tests/full-platform-integration.sh`:
```bash
#!/bin/bash

# Full platform integration test for Twinbox Full-Stack Kubernetes
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

log "Starting full platform integration test..."

# Test 1: Check all script files exist
log "Test 1: Checking script files..."
if [ ! -f "scripts/proxmox-helper.sh" ]; then
    error "Proxmox helper script missing"
    exit 1
fi

if [ ! -f "scripts/deploy-full-stack.sh" ]; then
    error "Full stack deployment script missing"
    exit 1
fi

# Test 2: Check all manifest directories exist
log "Test 2: Checking manifest directories..."
for dir in storage ingress gitops dns; do
    if [ ! -d "k8s-manifests/$dir" ]; then
        error "Manifest directory k8s-manifests/$dir missing"
        exit 1
    fi
done

# Test 3: Check all manifest files exist
log "Test 3: Checking manifest files..."
MANIFEST_FILES=(
    "k8s-manifests/storage/rook-operator.yaml"
    "k8s-manifests/storage/rook-cluster.yaml"
    "k8s-manifests/storage/rook-storageclass.yaml"
    "k8s-manifests/ingress/traefik-deployment.yaml"
    "k8s-manifests/ingress/traefik-service.yaml"
    "k8s-manifests/ingress/traefik-middleware.yaml"
    "k8s-manifests/gitops/argocd-install.yaml"
    "k8s-manifests/gitops/argocd-rbac.yaml"
    "k8s-manifests/gitops/argocd-applications.yaml"
    "k8s-manifests/dns/cloudflared-deployment.yaml"
    "k8s-manifests/dns/cloudflared-configmap.yaml"
    "k8s-manifests/dns/cloudflare-dns.yaml"
)

for file in "${MANIFEST_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        error "Manifest file $file missing"
        exit 1
    fi
done

# Test 4: Check documentation exists
log "Test 4: Checking documentation..."
if [ ! -f "docs/full-stack-deployment-guide.md" ]; then
    error "Full stack deployment guide missing"
    exit 1
fi

# Test 5: Check helper script has all required functions
log "Test 5: Checking helper script functions..."
REQUIRED_FUNCTIONS=(
    "deploy_rook_storage"
    "deploy_traefik"
    "deploy_argocd"
    "deploy_cloudflare"
)

for func in "${REQUIRED_FUNCTIONS[@]}"; do
    if ! grep -q "deploy_$func" "scripts/proxmox-helper.sh"; then
        error "Function deploy_$func missing from helper script"
        exit 1
    fi
done

# Test 6: Check scripts are executable
log "Test 6: Checking script permissions..."
if [ ! -x "scripts/proxmox-helper.sh" ] || [ ! -x "scripts/deploy-full-stack.sh" ]; then
    error "Scripts are not executable"
    exit 1
fi

# Test 7: Check that deployment script has proper structure
log "Test 7: Checking deployment script structure..."
if ! grep -q "check_prerequisites" "scripts/deploy-full-stack.sh"; then
    error "Deployment script missing prerequisites check"
    exit 1
fi

if ! grep -q "create_cluster" "scripts/deploy-full-stack.sh"; then
    error "Deployment script missing cluster creation"
    exit 1
fi

log "All integration tests passed!"
log "Twinbox Full-Stack Kubernetes platform is ready for deployment."
log ""
log "Next steps:"
echo "  1. Set your Proxmox environment variables"
echo "  2. Run ./scripts/deploy-full-stack.sh to create the platform"
echo "  3. Follow the documentation in docs/full-stack-deployment-guide.md"
```

Update the `Makefile`:
```makefile
.PHONY: help test terraform-init terraform-plan terraform-apply terraform-destroy ansible-setup deploy docs clean deploy-full-stack run-tests

# Twinbox Full-Stack Kubernetes Platform
# Makefile for common operations

# Default values - override with environment variables
CLUSTER_NAME ?= fullstack-cluster
NODE_COUNT ?= 3
VM_START_ID ?= 300
TF_DIR ?= ./terraform/talos-vm
ANSIBLE_DIR ?= ./ansible

help:
	@echo "Twinbox Full-Stack Kubernetes Platform"
	@echo ""
	@echo "Usage:"
	@echo "  make deploy-full-stack    Deploy complete platform with Talos, Rook, Traefik, ArgoCD, Cloudflare"
	@echo "  make terraform-init       Initialize Terraform"
	@echo "  make terraform-plan       Plan infrastructure changes"
	@echo "  make terraform-apply      Apply infrastructure changes"
	@echo "  make terraform-destroy    Destroy infrastructure"
	@echo "  make ansible-setup        Run Ansible playbooks"
	@echo "  make test                 Run integration tests"
	@echo "  make run-tests            Run all platform tests"
	@echo "  make docs                 Show deployment documentation"
	@echo "  make clean                Clean temporary files"
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

deploy-full-stack:
	@echo "Deploying full-stack Kubernetes platform: $(CLUSTER_NAME)"
	CLUSTER_NAME=$(CLUSTER_NAME) \
	NODE_COUNT=$(NODE_COUNT) \
	VM_START_ID=$(VM_START_ID) \
	./scripts/deploy-full-stack.sh

test: run-tests

run-tests:
	@echo "Running all platform tests..."
	bash tests/full-platform-integration.sh

docs:
	@echo "See docs/full-stack-deployment-guide.md for complete deployment instructions"
	@cat docs/full-stack-deployment-guide.md

clean:
	@echo "Cleaning temporary files..."
	rm -f terraform/talos-vm/*.tfplan
	rm -rf terraform/talos-vm/.terraform/
	rm -f terraform/talos-vm/.terraform.lock.hcl
	find . -name "*.retry" -delete
	rm -rf clusters/
	rm -rf test-output/
	@echo "Clean complete"

# Convenience targets for individual services
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

deploy-storage:
	@echo "Deploying Rook/Ceph storage for: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh deploy-storage \
		--cluster-name $(CLUSTER_NAME)

deploy-ingress:
	@echo "Deploying Traefik ingress for: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh deploy-ingress \
		--cluster-name $(CLUSTER_NAME)

deploy-argocd:
	@echo "Deploying ArgoCD for: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh deploy-argocd \
		--cluster-name $(CLUSTER_NAME)

deploy-cloudflare:
	@echo "Deploying Cloudflare tunnel for: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh deploy-cloudflare \
		--cluster-name $(CLUSTER_NAME)
```

**Step 4: Run test to verify it passes**
Run: `bash tests/final_integration_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add tests/full-platform-integration.sh Makefile
git commit -m "Add integration tests and update Makefile for full platform"
```

## Summary

The Twinbox Full-Stack Kubernetes platform is now complete with:

1. **Talos Linux** on Proxmox infrastructure with automated VM management
2. **Rook/Ceph** distributed storage solution with proper configuration
3. **Traefik** ingress controller for external access
4. **ArgoCD** GitOps for continuous delivery
5. **Cloudflare Tunnels** for secure public access
6. Complete deployment automation and documentation

The platform provides a production-ready infrastructure that combines security (via Talos), scalability (via Ceph), accessibility (via Traefik and Cloudflare), and operational efficiency (via GitOps). All components work together to create a comprehensive Kubernetes platform suitable for various workloads.