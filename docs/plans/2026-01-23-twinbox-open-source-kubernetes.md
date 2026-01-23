# Twinbox Open Source Kubernetes on Proxmox Implementation Plan

**Goal:** Create a complete, open-source Kubernetes platform on Proxmox using only actively maintained projects, with Talos Linux, Rook storage, Traefik ingress, Cloudflare tunnels, ArgoCD GitOps, and Keycloak for user management.

**Architecture:** Talos Linux provides secure, immutable Kubernetes nodes on Proxmox infrastructure. Rook/Ceph provides persistent storage, Traefik handles ingress/load balancing, Cloudflare tunnels provide secure public access, ArgoCD manages GitOps workflows, and Keycloak provides centralized authentication and SSO for all applications.

**Tech Stack:** Talos Linux, Proxmox VE, Rook/Ceph, Traefik, Cloudflare Tunnel, ArgoCD, Keycloak, GitOps

---

### Task 1: Replace Authentik with Keycloak

**Files:**
- Modify: `scripts/proxmox-helper.sh:1000-1200`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/keycloak_helper_test.sh
set -e

# Check if the script contains Keycloak deployment function
if ! grep -q "deploy_keycloak" "scripts/proxmox-helper.sh"; then
    echo "FAIL: deploy_keycloak function not found"
    exit 1
fi

# Check if Authentik function is removed
if grep -q "deploy_authentik" "scripts/proxmox-helper.sh"; then
    echo "FAIL: deploy_authentik function still exists"
    exit 1
fi

echo "PASS: Keycloak helper function exists and Authentik removed"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/keycloak_helper_test.sh`
Expected: FAIL error indicating function doesn't exist

**Step 3: Write minimal implementation**

Update the `scripts/proxmox-helper.sh` to replace Authentik with Keycloak:

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
KEYCLOAK_VERSION="24.0.2"

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
    deploy-keycloak    Deploy Keycloak identity provider

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
    $(basename "$0") deploy-keycloak --cluster-name my-cluster
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

# Deploy Keycloak identity provider
deploy_keycloak() {
    local cluster_name=$1
    
    log "Deploying Keycloak identity provider for cluster: ${cluster_name}"
    
    # Create directory for Keycloak configs
    local keycloak_dir="clusters/${cluster_name}/keycloak"
    mkdir -p "$keycloak_dir"
    
    # Create Keycloak deployment with Helm
    cat > "${keycloak_dir}/keycloak-values.yaml" << EOF
---
# Keycloak configuration
auth:
  # Set the admin credentials
  adminUser: "admin"
  adminPassword: "insecure_default_password"  # Change this after deployment!

# PostgreSQL configuration
postgresql:
  enabled: true
  auth:
    postgresPassword: "keycloak-postgres-password"
    database: "keycloak"
  primary:
    persistence:
      enabled: true
      size: 10Gi
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 100m
        memory: 128Mi

# Service configuration
service:
  type: ClusterIP
  port: 8080

# Ingress configuration
ingress:
  enabled: true
  ingressClassName: "traefik"  # Use Traefik as ingress controller
  hostname: "keycloak.${cluster_name}.yourdomain.com"
  tls: true
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"

# Resources configuration
resources:
  limits:
    cpu: 1000m
    memory: 1024Mi
  requests:
    cpu: 500m
    memory: 512Mi

# Keycloak configuration
keycloak:
  # Additional Keycloak configuration
  extraEnv: |
    - name: JAVA_OPTS_APPEND
      value: >-
        -Dcom.redhat.fips=false
    - name: KC_HTTP_RELATIVE_PATH
      value: /realms

# Persistence configuration
persistence:
  enabled: true
  size: 10Gi
  accessMode: ReadWriteOnce
EOF
    
    # Create additional Keycloak configurations
    cat > "${keycloak_dir}/keycloak-additional.yaml" << EOF
---
# Keycloak ingress for Traefik with middleware
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: keycloak-web
  namespace: keycloak
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(\`keycloak.${cluster_name}.yourdomain.com\`)
      kind: Rule
      services:
        - name: keycloak-http
          port: 8080
      middlewares:
        - name: keycloak-headers
  tls:
    secretName: keycloak-tls
---
# Security headers middleware for Keycloak
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: keycloak-headers
  namespace: keycloak
spec:
  headers:
    frameDeny: true
    sslRedirect: true
    browserXssFilter: true
    contentTypeNosniff: true
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 15724800  # 6 months
    customFrameOptionsValue: SAMEORIGIN
    customRequestHeaders:
      X-Forwarded-Proto: https
---
# Keycloak realm configuration example
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-realm-config
  namespace: keycloak
data:
  realm.json: |
    {
      "id": "twinbox-realm",
      "realm": "twinbox",
      "enabled": true,
      "sslRequired": "external",
      "registrationAllowed": false,
      "loginWithEmailAllowed": true,
      "duplicateEmailsAllowed": false,
      "resetPasswordAllowed": true,
      "editUsernameAllowed": false,
      "bruteForceProtected": true,
      "permanentLockout": false,
      "maxFailureWaitSeconds": 900,
      "minimumQuickLoginWaitSeconds": 60,
      "waitIncrementSeconds": 60,
      "quickLoginCheckMilliSeconds": 1000,
      "maxDeltaTimeSeconds": 43200,
      "failureFactor": 30,
      "accessTokenLifespan": 300,
      "accessTokenLifespanForImplicitFlow": 900,
      "ssoSessionIdleTimeout": 1800,
      "ssoSessionMaxLifespan": 36000,
      "offlineSessionIdleTimeout": 2592000,
      "offlineSessionMaxLifespanEnabled": false,
      "offlineSessionMaxLifespan": 5184000,
      "accessCodeLifespan": 60,
      "accessCodeLifespanUserAction": 300,
      "accessCodeLifespanLogin": 1800,
      "actionTokenGeneratedByAdminLifespan": 43200,
      "actionTokenGeneratedByUserLifespan": 300,
      "oauth2DeviceCodeLifespan": 600,
      "oauth2DevicePollingInterval": 5,
      "enabledEventTypes": [],
      "adminEventsEnabled": false,
      "adminEventsDetailsEnabled": false,
      "identityProviders": [],
      "identityProviderMappers": [],
      "components": {
        "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy": [
          {
            "name": "Trusted Hosts",
            "providerId": "trusted-hosts",
            "subType": "anonymous",
            "config": {
              "host-sending-registration-request-must-match": ["true"],
              "client-uris-must-match": ["true"]
            }
          },
          {
            "name": "Consent Required",
            "providerId": "consent-required",
            "subType": "anonymous",
            "config": {}
          },
          {
            "name": "Max Clients Limit",
            "providerId": "max-clients",
            "subType": "anonymous",
            "config": {
              "max-clients": ["200"]
            }
          },
          {
            "name": "Allowed Client Scopes",
            "providerId": "allowed-client-templates",
            "subType": "anonymous",
            "config": {
              "allow-default-scopes": ["true"]
            }
          },
          {
            "name": "Allowed Protocol Mapper Types",
            "providerId": "allowed-protocol-mappers",
            "subType": "anonymous",
            "config": {
              "allowed-protocol-mapper-types": [
                "oidc-sha256-pairwise-sub-mapper",
                "oidc-full-name-mapper",
                "oidc-address-mapper",
                "oidc-usermodel-property-mapper",
                "oidc-usermodel-attribute-mapper",
                "oidc-role-name-mapper",
                "saml-role-list-mapper",
                "saml-user-property-mapper",
                "saml-user-attribute-mapper"
              ]
            }
          }
        ],
        "org.keycloak.keys.KeyProvider": [
          {
            "name": "rsa-generated",
            "providerId": "rsa-generated",
            "config": {
              "priority": ["100"]
            }
          },
          {
            "name": "aes-generated",
            "providerId": "aes-generated",
            "config": {
              "priority": ["100"]
            }
          },
          {
            "name": "rsa-enc-generated",
            "providerId": "rsa-enc-generated",
            "config": {
              "priority": ["100"],
              "algorithm": ["RSA-OAEP"]
            }
          }
        ]
      },
      "internationalizationEnabled": false,
      "supportedLocales": [],
      "authenticationFlows": [],
      "authenticatorConfig": [],
      "requiredActions": [],
      "browserFlow": "browser",
      "registrationFlow": "registration",
      "directGrantFlow": "direct grant",
      "resetCredentialsFlow": "reset credentials",
      "clientAuthenticationFlow": "clients",
      "dockerAuthenticationFlow": "docker auth",
      "attributes": {
        "cibaBackchannelTokenDeliveryMode": "poll",
        "cibaExpiresIn": "120",
        "cibaInterval": "5",
        "parRequestUriLifespan": "60",
        "oauth2DeviceCodeLifespan": "600",
        "oauth2DevicePollingInterval": "5"
      },
      "keycloakVersion": "24.0.2",
      "userManagedAccessAllowed": false,
      "clientScopeMappings": {},
      "clientScopes": [],
      "defaultDefaultClientScopes": [
        "web-origins",
        "acr",
        "profile",
        "roles",
        "email"
      ],
      "defaultOptionalClientScopes": [
        "address",
        "phone",
        "offline_access",
        "microprofile-jwt"
      ],
      "browserSecurityHeaders": {
        "contentSecurityPolicyReportOnly": "",
        "xContentTypeOptions": "nosniff",
        "xRobotsTag": "none",
        "xFrameOptions": "SAMEORIGIN",
        "contentSecurityPolicy": "frame-src 'self'; frame-ancestors 'self'; object-src 'none';",
        "xXSSProtection": "1; mode=block",
        "strictTransportSecurity": "max-age=31536000; includeSubDomains"
      },
      "smtpServer": {},
      "eventsEnabled": false,
      "eventsListeners": ["jboss-logging"],
      "enabledEventTypes": [],
      "adminEventsEnabled": false,
      "adminEventsDetailsEnabled": false,
      "identityProviders": [],
      "identityProviderMappers": [],
      "components": {},
      "internationalizationEnabled": false,
      "supportedLocales": [],
      "authenticationFlows": [],
      "authenticatorConfig": [],
      "requiredActions": [],
      "browserFlow": "browser",
      "registrationFlow": "registration",
      "directGrantFlow": "direct grant",
      "resetCredentialsFlow": "reset credentials",
      "clientAuthenticationFlow": "clients",
      "dockerAuthenticationFlow": "docker auth",
      "attributes": {},
      "keycloakVersion": "24.0.2",
      "userManagedAccessAllowed": false
    }
EOF
    
    log "Keycloak identity provider configuration generated in ${keycloak_dir}/"
    log "To deploy with Helm:"
    echo "  1. Add the Keycloak Helm repository: helm repo add bitnami https://charts.bitnami.com/bitnami"
    echo "  2. Update repositories: helm repo update"
    echo "  3. Create namespace: kubectl create namespace keycloak"
    echo "  4. Deploy: helm upgrade --install keycloak bitnami/keycloak --values ${keycloak_dir}/keycloak-values.yaml --namespace keycloak"
    log "After deployment, access Keycloak at https://keycloak.${cluster_name}.yourdomain.com"
    log "Default credentials: admin / insecure_default_password (change after first login!)"
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
        deploy-keycloak)
            deploy_keycloak "$CLUSTER_NAME"
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
Run: `bash tests/keycloak_helper_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add scripts/proxmox-helper.sh
git commit -m "Replace Authentik with Keycloak in helper script"
```

### Task 2: Create Keycloak Configuration Manifests

**Files:**
- Create: `k8s-manifests/keycloak/keycloak-helm-values.yaml`
- Create: `k8s-manifests/keycloak/keycloak-ingress.yaml`
- Create: `k8s-manifests/keycloak/keycloak-realm-config.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/keycloak_manifests_test.sh
set -e

if [ ! -f "k8s-manifests/keycloak/keycloak-helm-values.yaml" ]; then
    echo "FAIL: k8s-manifests/keycloak/keycloak-helm-values.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/keycloak/keycloak-ingress.yaml" ]; then
    echo "FAIL: k8s-manifests/keycloak/keycloak-ingress.yaml does not exist"
    exit 1
fi

if [ ! -f "k8s-manifests/keycloak/keycloak-realm-config.yaml" ]; then
    echo "FAIL: k8s-manifests/keycloak/keycloak-realm-config.yaml does not exist"
    exit 1
fi

echo "PASS: Keycloak manifests exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/keycloak_manifests_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p k8s-manifests/keycloak
```

Create `k8s-manifests/keycloak/keycloak-helm-values.yaml`:
```yaml
---
# Keycloak configuration
auth:
  # Set the admin credentials
  adminUser: "admin"
  adminPassword: "insecure_default_password"  # Change this after deployment!

# PostgreSQL configuration
postgresql:
  enabled: true
  auth:
    postgresPassword: "keycloak-postgres-password"
    database: "keycloak"
  primary:
    persistence:
      enabled: true
      size: 10Gi
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 100m
        memory: 128Mi

# Service configuration
service:
  type: ClusterIP
  port: 8080

# Ingress configuration
ingress:
  enabled: true
  ingressClassName: "traefik"  # Use Traefik as ingress controller
  hostname: "keycloak.yourdomain.com"
  tls: true
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"

# Resources configuration
resources:
  limits:
    cpu: 1000m
    memory: 1024Mi
  requests:
    cpu: 500m
    memory: 512Mi

# Keycloak configuration
keycloak:
  # Additional Keycloak configuration
  extraEnv: |
    - name: JAVA_OPTS_APPEND
      value: >-
        -Dcom.redhat.fips=false
    - name: KC_HTTP_RELATIVE_PATH
      value: /realms

# Persistence configuration
persistence:
  enabled: true
  size: 10Gi
  accessMode: ReadWriteOnce

# Network Policy
networkPolicy:
  enabled: true
  allowExternal: false
  additionalRules: []
```

Create `k8s-manifests/keycloak/keycloak-ingress.yaml`:
```yaml
---
# Keycloak ingress for Traefik with middleware
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: keycloak-web
  namespace: keycloak
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(`keycloak.yourdomain.com`)
      kind: Rule
      services:
        - name: keycloak-http
          namespace: keycloak
          port: 8080
      middlewares:
        - name: keycloak-headers
        - name: keycloak-compress
  tls:
    secretName: keycloak-tls
---
# Security headers middleware for Keycloak
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: keycloak-headers
  namespace: keycloak
spec:
  headers:
    frameDeny: true
    sslRedirect: true
    browserXssFilter: true
    contentTypeNosniff: true
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 15724800  # 6 months
    customFrameOptionsValue: SAMEORIGIN
    customRequestHeaders:
      X-Forwarded-Proto: https
---
# Compression middleware for Keycloak
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: keycloak-compress
  namespace: keycloak
spec:
  compress: {}
---
# Keycloak admin ingress (more restrictive)
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: keycloak-admin
  namespace: keycloak
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`admin.keycloak.yourdomain.com`)
      kind: Rule
      services:
        - name: keycloak-http
          namespace: keycloak
          port: 8080
      middlewares:
        - name: keycloak-headers
        - name: keycloak-ip-whitelist
  tls:
    secretName: keycloak-admin-tls
---
# IP whitelist middleware for admin access (customize with your IPs)
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: keycloak-ip-whitelist
  namespace: keycloak
spec:
  ipWhiteList:
    sourceRange:
      - "203.0.113.0/24"  # Replace with your trusted IPs
      - "198.51.100.0/24" # Replace with your trusted IPs
---
# Keycloak API ingress (if needed for external integrations)
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: keycloak-api
  namespace: keycloak
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`api.keycloak.yourdomain.com`)
      kind: Rule
      services:
        - name: keycloak-http
          namespace: keycloak
          port: 8080
      middlewares:
        - name: keycloak-headers
  tls:
    secretName: keycloak-api-tls
```

Create `k8s-manifests/keycloak/keycloak-realm-config.yaml`:
```yaml
---
# Keycloak realm configuration example
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-realm-config
  namespace: keycloak
data:
  realm.json: |
    {
      "id": "twinbox-realm",
      "realm": "twinbox",
      "enabled": true,
      "sslRequired": "external",
      "registrationAllowed": false,
      "loginWithEmailAllowed": true,
      "duplicateEmailsAllowed": false,
      "resetPasswordAllowed": true,
      "editUsernameAllowed": false,
      "bruteForceProtected": true,
      "permanentLockout": false,
      "maxFailureWaitSeconds": 900,
      "minimumQuickLoginWaitSeconds": 60,
      "waitIncrementSeconds": 60,
      "quickLoginCheckMilliSeconds": 1000,
      "maxDeltaTimeSeconds": 43200,
      "failureFactor": 30,
      "accessTokenLifespan": 300,
      "accessTokenLifespanForImplicitFlow": 900,
      "ssoSessionIdleTimeout": 1800,
      "ssoSessionMaxLifespan": 36000,
      "offlineSessionIdleTimeout": 2592000,
      "offlineSessionMaxLifespanEnabled": false,
      "offlineSessionMaxLifespan": 5184000,
      "accessCodeLifespan": 60,
      "accessCodeLifespanUserAction": 300,
      "accessCodeLifespanLogin": 1800,
      "actionTokenGeneratedByAdminLifespan": 43200,
      "actionTokenGeneratedByUserLifespan": 300,
      "oauth2DeviceCodeLifespan": 600,
      "oauth2DevicePollingInterval": 5,
      "enabledEventTypes": [],
      "adminEventsEnabled": false,
      "adminEventsDetailsEnabled": false,
      "identityProviders": [],
      "identityProviderMappers": [],
      "components": {
        "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy": [
          {
            "name": "Trusted Hosts",
            "providerId": "trusted-hosts",
            "subType": "anonymous",
            "config": {
              "host-sending-registration-request-must-match": ["true"],
              "client-uris-must-match": ["true"]
            }
          },
          {
            "name": "Consent Required",
            "providerId": "consent-required",
            "subType": "anonymous",
            "config": {}
          },
          {
            "name": "Max Clients Limit",
            "providerId": "max-clients",
            "subType": "anonymous",
            "config": {
              "max-clients": ["200"]
            }
          },
          {
            "name": "Allowed Client Scopes",
            "providerId": "allowed-client-templates",
            "subType": "anonymous",
            "config": {
              "allow-default-scopes": ["true"]
            }
          },
          {
            "name": "Allowed Protocol Mapper Types",
            "providerId": "allowed-protocol-mappers",
            "subType": "anonymous",
            "config": {
              "allowed-protocol-mapper-types": [
                "oidc-sha256-pairwise-sub-mapper",
                "oidc-full-name-mapper",
                "oidc-address-mapper",
                "oidc-usermodel-property-mapper",
                "oidc-usermodel-attribute-mapper",
                "oidc-role-name-mapper",
                "saml-role-list-mapper",
                "saml-user-property-mapper",
                "saml-user-attribute-mapper"
              ]
            }
          }
        ],
        "org.keycloak.keys.KeyProvider": [
          {
            "name": "rsa-generated",
            "providerId": "rsa-generated",
            "config": {
              "priority": ["100"]
            }
          },
          {
            "name": "aes-generated",
            "providerId": "aes-generated",
            "config": {
              "priority": ["100"]
            }
          },
          {
            "name": "rsa-enc-generated",
            "providerId": "rsa-enc-generated",
            "config": {
              "priority": ["100"],
              "algorithm": ["RSA-OAEP"]
            }
          }
        ]
      },
      "internationalizationEnabled": false,
      "supportedLocales": [],
      "authenticationFlows": [],
      "authenticatorConfig": [],
      "requiredActions": [],
      "browserFlow": "browser",
      "registrationFlow": "registration",
      "directGrantFlow": "direct grant",
      "resetCredentialsFlow": "reset credentials",
      "clientAuthenticationFlow": "clients",
      "dockerAuthenticationFlow": "docker auth",
      "attributes": {
        "cibaBackchannelTokenDeliveryMode": "poll",
        "cibaExpiresIn": "120",
        "cibaInterval": "5",
        "parRequestUriLifespan": "60",
        "oauth2DeviceCodeLifespan": "600",
        "oauth2DevicePollingInterval": "5"
      },
      "keycloakVersion": "24.0.2",
      "userManagedAccessAllowed": false,
      "clientScopeMappings": {},
      "clientScopes": [],
      "defaultDefaultClientScopes": [
        "web-origins",
        "acr",
        "profile",
        "roles",
        "email"
      ],
      "defaultOptionalClientScopes": [
        "address",
        "phone",
        "offline_access",
        "microprofile-jwt"
      ],
      "browserSecurityHeaders": {
        "contentSecurityPolicyReportOnly": "",
        "xContentTypeOptions": "nosniff",
        "xRobotsTag": "none",
        "xFrameOptions": "SAMEORIGIN",
        "contentSecurityPolicy": "frame-src 'self'; frame-ancestors 'self'; object-src 'none';",
        "xXSSProtection": "1; mode=block",
        "strictTransportSecurity": "max-age=31536000; includeSubDomains"
      },
      "smtpServer": {},
      "eventsEnabled": false,
      "eventsListeners": ["jboss-logging"],
      "enabledEventTypes": [],
      "adminEventsEnabled": false,
      "adminEventsDetailsEnabled": false,
      "identityProviders": [],
      "identityProviderMappers": [],
      "components": {},
      "internationalizationEnabled": false,
      "supportedLocales": [],
      "authenticationFlows": [],
      "authenticatorConfig": [],
      "requiredActions": [],
      "browserFlow": "browser",
      "registrationFlow": "registration",
      "directGrantFlow": "direct grant",
      "resetCredentialsFlow": "reset credentials",
      "clientAuthenticationFlow": "clients",
      "dockerAuthenticationFlow": "docker auth",
      "attributes": {},
      "keycloakVersion": "24.0.2",
      "userManagedAccessAllowed": false
    }
---
# Example application protected by Keycloak adapter
apiVersion: v1
kind: Service
metadata:
  name: protected-app
  namespace: default
spec:
  selector:
    app: protected-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: protected-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: protected-app
  template:
    metadata:
      labels:
        app: protected-app
    spec:
      containers:
      - name: protected-app
        image: nginx:latest
        ports:
        - containerPort: 8080
---
# Ingress route that goes through Keycloak (would require Keycloak adapter)
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: protected-app-with-keycloak
  namespace: default
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(`protected.yourdomain.com`)
      kind: Rule
      services:
        - name: protected-app
          port: 80
      middlewares:
        - name: keycloak-oauth
  tls:
    secretName: protected-app-tls
---
# OAuth middleware for Keycloak integration (example - implementation varies)
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: keycloak-oauth
  namespace: default
spec:
  forwardAuth:
    address: "http://keycloak-http.keycloak.svc.cluster.local:8080/realms/twinbox/protocol/openid-connect/auth"
    trustForwardHeader: true
    authResponseHeaders:
      - "X-Auth-Token"
      - "X-Auth-User"
```

**Step 4: Run test to verify it passes**
Run: `bash tests/keycloak_manifests_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add k8s-manifests/keycloak/
git commit -m "Add Keycloak configuration manifests"
```

### Task 3: Update Documentation for Keycloak Integration

**Files:**
- Modify: `docs/full-stack-deployment-guide.md:100-200`
- Create: `docs/keycloak-integration-guide.md`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/keycloak_docs_test.sh
set -e

if [ ! -f "docs/keycloak-integration-guide.md" ]; then
    echo "FAIL: docs/keycloak-integration-guide.md does not exist"
    exit 1
fi

if ! grep -q "Keycloak" "docs/full-stack-deployment-guide.md"; then
    echo "FAIL: Keycloak not mentioned in full stack guide"
    exit 1
fi

if grep -q "Authentik" "docs/full-stack-deployment-guide.md"; then
    echo "FAIL: Authentik still mentioned in full stack guide"
    exit 1
fi

echo "PASS: Keycloak documentation exists and Authentik removed"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/keycloak_docs_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Update the `docs/full-stack-deployment-guide.md` to include Keycloak section:

```markdown
# Twinbox Full-Stack Kubernetes Deployment Guide

This guide explains how to deploy a complete Kubernetes platform using Talos Linux on Proxmox with Rook storage, Traefik ingress, Cloudflare tunnels, ArgoCD GitOps, and Keycloak for user management.

## Overview

The Twinbox Full-Stack Kubernetes platform provides a production-ready infrastructure with:

- **Talos Linux**: Secure, immutable Kubernetes OS
- **Rook/Ceph**: Distributed storage solution
- **Traefik**: Modern ingress controller
- **Cloudflare Tunnel**: Secure public access without opening firewall ports
- **ArgoCD**: GitOps continuous delivery
- **Keycloak**: Identity and access management with SSO

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
- Domain name for Keycloak and other services

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
7. Deploy Keycloak identity provider

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

### Keycloak Identity Provider

Keycloak provides centralized authentication and SSO for all applications:

```bash
# Deploy Keycloak using the helper script
./scripts/proxmox-helper.sh deploy-keycloak --cluster-name your-cluster-name

# Or deploy manually using Helm:
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
kubectl create namespace keycloak
helm upgrade --install keycloak bitnami/keycloak --values k8s-manifests/keycloak/keycloak-helm-values.yaml --namespace keycloak

# Access Keycloak UI
# Default credentials: admin / insecure_default_password
# Change the password immediately after first login!
```

For detailed Keycloak configuration, see [Keycloak Integration Guide](keycloak-integration-guide.md).

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
- `keycloak.yourdomain.com` → Your Keycloak instance

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
4. Update platform services (Rook, Traefik, ArgoCD, Keycloak) separately

## Troubleshooting

### Common Issues

1. **Storage not provisioning**: Check Rook cluster status and Ceph health
2. **Ingress not routing**: Verify Traefik deployment and ingress rules
3. **GitOps not syncing**: Check ArgoCD repository access and permissions
4. **Keycloak not accessible**: Verify ingress configuration and certificates
5. **Public access not working**: Verify Cloudflare tunnel configuration

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
kubectl -n keycloak logs deployment/keycloak -f
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

This full-stack Kubernetes platform provides a robust foundation for production workloads. By combining Talos Linux security, Rook storage, Traefik ingress, Cloudflare tunnels, ArgoCD GitOps, and Keycloak identity management, you have a complete infrastructure solution that is secure, scalable, and manageable.
```

Create `docs/keycloak-integration-guide.md`:
```markdown
# Keycloak Integration Guide

This guide explains how to integrate Keycloak with your Twinbox Kubernetes platform for centralized authentication and SSO.

## Overview

Keycloak is an open-source Identity and Access Management solution that provides:

- Single Sign-On (SSO) for all applications
- Identity Brokering and Social Login
- User Federation
- Centralized User Management
- Fine-grained Authorization
- Comprehensive identity governance

Keycloak is actively maintained by Red Hat and is the recommended open-source solution for identity management.

## Prerequisites

Before integrating Keycloak, ensure you have:

- A deployed Twinbox Kubernetes cluster
- Access to kubectl
- A domain name for your Keycloak instance
- SSL certificate for your domain (or use Let's Encrypt)

## Installation

### 1. Deploy Keycloak

You can deploy Keycloak using the helper script:

```bash
./scripts/proxmox-helper.sh deploy-keycloak --cluster-name your-cluster-name
```

Or deploy manually using Helm:

```bash
# Add the Keycloak Helm repository
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create the namespace
kubectl create namespace keycloak

# Deploy Keycloak
helm upgrade --install keycloak bitnami/keycloak \
  --values k8s-manifests/keycloak/keycloak-helm-values.yaml \
  --namespace keycloak
```

### 2. Configure Ingress

Update the ingress configuration to match your domain:

```yaml
# In your keycloak-values.yaml
ingress:
  enabled: true
  ingressClassName: "traefik"
  hostname: "keycloak.yourdomain.com"
  tls: true
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"
```

### 3. Access Keycloak

After deployment, access Keycloak at `https://keycloak.yourdomain.com`. The default credentials are:

- Username: `admin`
- Password: `insecure_default_password`

**Important**: Change the default password immediately after first login!

## Configuration

### 1. Initial Setup

After accessing Keycloak for the first time:

1. Change the default administrator password
2. Create a realm for your organization
3. Configure the application branding
4. Set up themes if needed

### 2. Create Realms

Realms are isolated security domains in Keycloak:

1. Navigate to **Administration Console**
2. Click **Add Realm**
3. Enter a realm name (e.g., `twinbox`)
4. Click **Create**

### 3. Configure Users

To add users to your realm:

1. Select your realm
2. Go to **Users**
3. Click **Add user**
4. Fill in user details
5. Set credentials on the **Credentials** tab

### 4. Create Roles

To create roles for authorization:

1. Go to **Roles**
2. Click **Add Role**
3. Enter role name and description
4. Click **Save**

## Integrating with Applications

### 1. Protecting Internal Applications

To protect an internal application with Keycloak:

1. Create a new client in Keycloak:
   - Go to **Clients**
   - Click **Create**
   - Enter client ID (e.g., `protected-app`)
   - Select **openid-connect** as protocol
   - Click **Save**

2. Configure the client settings:
   - Set **Access Type** to `confidential`
   - Set **Valid Redirect URIs** to your application's callback URLs
   - Set **Web Origins** to your application's origins

3. Get the client credentials:
   - Go to the **Credentials** tab
   - Note the **Client Secret**

### 2. OpenID Connect Integration

For applications that support OpenID Connect:

1. Create an OpenID Connect client in Keycloak
2. Note the Client ID and Client Secret
3. Configure your application with these values
4. Set the callback URLs to match your application's redirect URIs

### 3. SAML Integration

For SAML-enabled applications:

1. Create a SAML client in Keycloak
2. Configure the entity ID and assertion consumer service URL
3. Download the SAML metadata
4. Upload the metadata to your application

## Advanced Configuration

### 1. User Federation

Configure user sources to import users from external systems:

- LDAP directories
- Active Directory
- Other identity providers

### 2. Authentication Flows

Implement adaptive authentication with custom flows:

- Username/password
- Two-factor authentication
- Social login
- Passwordless authentication

### 3. Identity Brokering

Connect to external identity providers:

- Google
- Facebook
- GitHub
- Other SAML/OIDC providers

## Securing the Stack

### 1. Protect ArgoCD with Keycloak

To secure ArgoCD with Keycloak:

1. Create an OpenID Connect client in Keycloak for ArgoCD
2. Configure ArgoCD with the OIDC settings
3. Update the ArgoCD config map with OIDC settings:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
data:
  oidc.config: |
    name: Keycloak
    issuer: https://keycloak.yourdomain.com/realms/twinbox
    clientID: argocd-client
    clientSecret: $oidc.argocd.clientSecret
    requestedScopes: ["openid", "profile", "email", "groups"]
```

### 2. Protect Grafana with Keycloak

To secure Grafana with Keycloak:

1. Create an OpenID Connect client in Keycloak for Grafana
2. Configure Grafana with OAuth settings in the config map:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-config
data:
  grafana.ini: |
    [auth.generic_oauth]
    enabled = true
    name = Keycloak
    client_id = grafana-client
    client_secret = your-client-secret
    scopes = openid profile email groups
    auth_url = https://keycloak.yourdomain.com/realms/twinbox/protocol/openid-connect/auth
    token_url = https://keycloak.yourdomain.com/realms/twinbox/protocol/openid-connect/token
    api_url = https://keycloak.yourdomain.com/realms/twinbox/protocol/openid-connect/userinfo
```

## Monitoring and Maintenance

### 1. Health Checks

Monitor Keycloak health through:

- Built-in health check endpoints
- Prometheus metrics (if enabled)
- Log analysis

### 2. Backup Strategy

Back up Keycloak configuration:

- Database backups (PostgreSQL)
- Realm configurations
- Certificates and secrets

### 3. Update Process

Keep Keycloak updated:

- Regularly update the Docker images
- Test updates in staging first
- Follow the migration guides for version upgrades

## Troubleshooting

### Common Issues

1. **SSL Certificate Issues**: Ensure certificates are valid and properly configured
2. **Application Connectivity**: Verify network connectivity between clients and Keycloak
3. **OIDC Redirect Errors**: Check that redirect URIs match exactly
4. **User Sync Problems**: Verify user federation configurations

### Diagnostic Commands

```bash
# Check Keycloak pods
kubectl -n keycloak get pods

# Check Keycloak logs
kubectl -n keycloak logs deployment/keycloak

# Access Keycloak shell
kubectl -n keycloak exec -it deployment/keycloak -- bash
```

## Security Best Practices

1. **Strong Passwords**: Enforce strong passwords for all accounts
2. **Multi-Factor Authentication**: Enable MFA for all users
3. **Regular Auditing**: Audit user access and activities regularly
4. **Certificate Management**: Rotate certificates regularly
5. **Network Segmentation**: Isolate Keycloak from other services where appropriate

## Comparison with Other Solutions

Keycloak vs alternatives:

- **Open Source**: Yes, with active community support
- **Active Development**: Yes, maintained by Red Hat
- **Standard Protocols**: Supports OIDC, SAML, OAuth 2.0
- **User Federation**: Extensive options
- **Authorization Services**: Fine-grained permissions
- **Community**: Large and active

## Conclusion

Keycloak provides a robust identity and access management solution for your Kubernetes platform. With proper configuration, it can centralize authentication for all your applications and provide strong security controls while maintaining open-source compliance and active maintenance.
```

**Step 4: Run test to verify it passes**
Run: `bash tests/keycloak_docs_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add docs/full-stack-deployment-guide.md docs/keycloak-integration-guide.md
git commit -m "Update documentation with Keycloak integration guide"
```

### Task 4: Update Deployment Scripts

**Files:**
- Modify: `scripts/deploy-full-stack.sh:150-200`
- Modify: `Makefile:50-100`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/updated_scripts_test.sh
set -e

if ! grep -q "deploy_keycloak" "scripts/deploy-full-stack.sh"; then
    echo "FAIL: deploy_keycloak function not found in deployment script"
    exit 1
fi

if grep -q "deploy_authentik" "scripts/deploy-full-stack.sh"; then
    echo "FAIL: deploy_authentik function still exists in deployment script"
    exit 1
fi

if ! grep -q "deploy-keycloak" "Makefile"; then
    echo "FAIL: deploy-keycloak target not found in Makefile"
    exit 1
fi

if grep -q "deploy-authentik" "Makefile"; then
    echo "FAIL: deploy-authentik target still exists in Makefile"
    exit 1
fi

echo "PASS: Updated scripts contain Keycloak functions and Authentik removed"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/updated_scripts_test.sh`
Expected: FAIL error indicating functions don't exist

**Step 3: Write minimal implementation**

Update the `scripts/deploy-full-stack.sh` to include Keycloak deployment:

```bash
#!/bin/bash

# Twinbox Full-Stack Kubernetes Deployment Script
# Deploys Talos Linux cluster with Rook storage, Traefik ingress, Cloudflare tunnel, ArgoCD, and Keycloak

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
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-24.0.2}"

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

deploy_keycloak() {
    log "Deploying Keycloak identity provider..."
    
    ./scripts/proxmox-helper.sh deploy-keycloak --cluster-name "$CLUSTER_NAME"
    
    if [ $? -ne 0 ]; then
        error "Keycloak deployment preparation failed"
        exit 1
    fi
    
    # Apply the generated manifests
    if [ -f "clusters/$CLUSTER_NAME/keycloak/keycloak-values.yaml" ]; then
        log "Installing Keycloak with Helm..."
        
        # Check if Helm is available
        if command -v helm &> /dev/null; then
            # Add Keycloak Helm repository
            helm repo add bitnami https://charts.bitnami.com/bitnami
            helm repo update
            
            # Create namespace
            kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
            
            # Install Keycloak
            helm upgrade --install keycloak bitnami/keycloak \
                --values "clusters/$CLUSTER_NAME/keycloak/keycloak-values.yaml" \
                --namespace keycloak
                
            # Wait for Keycloak to be ready
            log "Waiting for Keycloak to be ready..."
            kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak -n keycloak --timeout=600s
        else
            warn "Helm not found, skipping automated Keycloak installation"
            log "Manually install Keycloak using the values file: clusters/$CLUSTER_NAME/keycloak/keycloak-values.yaml"
        fi
    fi
    
    log "Keycloak identity provider deployed successfully"
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
    echo "  - Keycloak: Identity provider in keycloak namespace"
    echo ""
    echo "Access information:"
    echo "  - ArgoCD: kubectl port-forward -n argocd svc/argocd-server 8080:80"
    echo "  - Keycloak: https://keycloak.$CLUSTER_NAME.yourdomain.com"
    echo "  - Default Keycloak credentials: admin / insecure_default_password"
    echo ""
    echo "Next steps:"
    echo "  1. Configure Talos machines using the generated configs in clusters/$CLUSTER_NAME/talos-configs/"
    echo "  2. Set up Cloudflare tunnel with your domain and credentials"
    echo "  3. Configure DNS to point to your cluster's external IP"
    echo "  4. Access Keycloak and change the default password"
    echo "  5. Configure Keycloak realms and applications as needed"
}

main() {
    log "Starting Twinbox Full-Stack Kubernetes deployment with Keycloak"
    log "This will create a complete platform with:"
    echo "  - Talos Linux Kubernetes cluster"
    echo "  - Rook/Ceph persistent storage"
    echo "  - Traefik ingress controller"
    echo "  - ArgoCD GitOps"
    echo "  - Cloudflare tunnel for public access"
    echo "  - Keycloak identity provider"
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
        deploy_keycloak
    else
        warn "Skipping service deployments. Please configure kubectl and run them manually."
    fi
    
    finalize_deployment
    
    log "Full-stack deployment with Keycloak completed!"
}

main
```

Update the `Makefile` to include Keycloak targets:

```makefile
.PHONY: help test terraform-init terraform-plan terraform-apply terraform-destroy ansible-setup deploy docs clean deploy-full-stack run-tests deploy-keycloak

# Twinbox Full-Stack Kubernetes Platform with Keycloak
# Makefile for common operations

# Default values - override with environment variables
CLUSTER_NAME ?= fullstack-cluster
NODE_COUNT ?= 3
VM_START_ID ?= 300
TF_DIR ?= ./terraform/talos-vm
ANSIBLE_DIR ?= ./ansible

help:
	@echo "Twinbox Full-Stack Kubernetes Platform with Keycloak"
	@echo ""
	@echo "Usage:"
	@echo "  make deploy-full-stack    Deploy complete platform with Talos, Rook, Traefik, ArgoCD, Cloudflare, Keycloak"
	@echo "  make deploy-keycloak      Deploy only Keycloak identity provider"
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

deploy-keycloak:
	@echo "Deploying Keycloak identity provider for: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh deploy-keycloak \
		--cluster-name $(CLUSTER_NAME)

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

deploy-keycloak:
	@echo "Deploying Keycloak identity provider for: $(CLUSTER_NAME)"
	./scripts/proxmox-helper.sh deploy-keycloak \
		--cluster-name $(CLUSTER_NAME)
```

**Step 4: Run test to verify it passes**
Run: `bash tests/updated_scripts_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add scripts/deploy-full-stack.sh Makefile
git commit -m "Update deployment scripts with Keycloak integration"
```

### Task 5: Create Integration Tests

**Files:**
- Create: `tests/keycloak-integration-test.sh`
- Update: `tests/run-all-tests.sh`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/final_keycloak_test.sh
set -e

if [ ! -f "tests/keycloak-integration-test.sh" ]; then
    echo "FAIL: tests/keycloak-integration-test.sh does not exist"
    exit 1
fi

if ! grep -q "keycloak" "tests/run-all-tests.sh"; then
    echo "FAIL: keycloak test not included in run-all-tests.sh"
    exit 1
fi

if grep -q "authentik" "tests/run-all-tests.sh"; then
    echo "FAIL: authentik still mentioned in run-all-tests.sh"
    exit 1
fi

echo "PASS: Keycloak integration tests exist and Authentik removed"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/final_keycloak_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `tests/keycloak-integration-test.sh`:
```bash
#!/bin/bash

# Keycloak integration test for Twinbox Full-Stack Kubernetes
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

log "Starting Keycloak integration test..."

# Test 1: Check if Keycloak manifests exist
log "Test 1: Checking Keycloak manifests..."
KEYCLOAK_MANIFESTS=(
    "k8s-manifests/keycloak/keycloak-helm-values.yaml"
    "k8s-manifests/keycloak/keycloak-ingress.yaml"
    "k8s-manifests/keycloak/keycloak-realm-config.yaml"
)

for manifest in "${KEYCLOAK_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "Keycloak manifest $manifest missing"
        exit 1
    fi
done

# Test 2: Check if helper script has Keycloak function
log "Test 2: Checking helper script Keycloak function..."
if ! grep -q "deploy_keycloak" "scripts/proxmox-helper.sh"; then
    error "deploy_keycloak function missing from helper script"
    exit 1
fi

# Check that Authentik function is removed
if grep -q "deploy_authentik" "scripts/proxmox-helper.sh"; then
    error "deploy_authentik function still exists in helper script"
    exit 1
fi

# Test 3: Check if deployment script has Keycloak function
log "Test 3: Checking deployment script Keycloak function..."
if ! grep -q "deploy_keycloak" "scripts/deploy-full-stack.sh"; then
    error "deploy_keycloak function missing from deployment script"
    exit 1
fi

# Check that Authentik function is removed
if grep -q "deploy_authentik" "scripts/deploy-full-stack.sh"; then
    error "deploy_authentik function still exists in deployment script"
    exit 1
fi

# Test 4: Check if Keycloak documentation exists
log "Test 4: Checking Keycloak documentation..."
if [ ! -f "docs/keycloak-integration-guide.md" ]; then
    error "Keycloak integration guide missing"
    exit 1
fi

# Test 5: Check if Keycloak is mentioned in main documentation
log "Test 5: Checking Keycloak mention in main guide..."
if ! grep -q "Keycloak" "docs/full-stack-deployment-guide.md"; then
    error "Keycloak not mentioned in main deployment guide"
    exit 1
fi

# Check that Authentik is not mentioned
if grep -q "Authentik" "docs/full-stack-deployment-guide.md"; then
    error "Authentik still mentioned in main deployment guide"
    exit 1
fi

# Test 6: Check if Makefile has Keycloak targets
log "Test 6: Checking Makefile Keycloak targets..."
if ! grep -q "deploy-keycloak" "Makefile"; then
    error "deploy-keycloak target missing from Makefile"
    exit 1
fi

if grep -q "deploy-authentik" "Makefile"; then
    error "deploy-authentik target still exists in Makefile"
    exit 1
fi

# Test 7: Check if Keycloak values file has correct structure
log "Test 7: Checking Keycloak values file structure..."
if ! grep -q "auth:" "k8s-manifests/keycloak/keycloak-helm-values.yaml"; then
    error "Keycloak values file doesn't have auth section"
    exit 1
fi

if ! grep -q "postgresql:" "k8s-manifests/keycloak/keycloak-helm-values.yaml"; then
    error "Keycloak values file doesn't have postgresql section"
    exit 1
fi

if ! grep -q "service:" "k8s-manifests/keycloak/keycloak-helm-values.yaml"; then
    error "Keycloak values file doesn't have service section"
    exit 1
fi

log "All Keycloak integration tests passed!"
log "Keycloak is properly integrated into the Twinbox platform."
```

Update the `tests/run-all-tests.sh` to include Keycloak and remove Authentik:
```bash
#!/bin/bash

# Run all tests for Twinbox Full-Stack Kubernetes with Keycloak
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

log "Starting all tests for Twinbox Full-Stack Kubernetes with Keycloak..."

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

# Test 5: Storage manifests exist
log "Test 5: Checking storage manifests..."
STORAGE_MANIFESTS=(
    "k8s-manifests/storage/rook-operator.yaml"
    "k8s-manifests/storage/rook-cluster.yaml"
    "k8s-manifests/storage/rook-storageclass.yaml"
)

for manifest in "${STORAGE_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "Storage manifest $manifest missing"
        exit 1
    fi
done

# Test 6: Ingress manifests exist
log "Test 6: Checking ingress manifests..."
INGRESS_MANIFESTS=(
    "k8s-manifests/ingress/traefik-deployment.yaml"
    "k8s-manifests/ingress/traefik-service.yaml"
    "k8s-manifests/ingress/traefik-middleware.yaml"
)

for manifest in "${INGRESS_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "Ingress manifest $manifest missing"
        exit 1
    fi
done

# Test 7: GitOps manifests exist
log "Test 7: Checking GitOps manifests..."
GITOPS_MANIFESTS=(
    "k8s-manifests/gitops/argocd-install.yaml"
    "k8s-manifests/gitops/argocd-rbac.yaml"
    "k8s-manifests/gitops/argocd-applications.yaml"
)

for manifest in "${GITOPS_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "GitOps manifest $manifest missing"
        exit 1
    fi
done

# Test 8: DNS/Cloudflare manifests exist
log "Test 8: Checking DNS/Cloudflare manifests..."
DNS_MANIFESTS=(
    "k8s-manifests/dns/cloudflared-deployment.yaml"
    "k8s-manifests/dns/cloudflared-configmap.yaml"
    "k8s-manifests/dns/cloudflare-dns.yaml"
)

for manifest in "${DNS_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "DNS manifest $manifest missing"
        exit 1
    fi
done

# Test 9: Keycloak manifests exist
log "Test 9: Checking Keycloak manifests..."
KEYCLOAK_MANIFESTS=(
    "k8s-manifests/keycloak/keycloak-helm-values.yaml"
    "k8s-manifests/keycloak/keycloak-ingress.yaml"
    "k8s-manifests/keycloak/keycloak-realm-config.yaml"
)

for manifest in "${KEYCLOAK_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "Keycloak manifest $manifest missing"
        exit 1
    fi
done

# Test 10: Documentation exists
log "Test 10: Checking documentation..."
if [ ! -f "docs/full-stack-deployment-guide.md" ] || 
   [ ! -f "docs/keycloak-integration-guide.md" ]; then
    error "Documentation incomplete"
    exit 1
fi

# Test 11: Examples exist
log "Test 11: Checking examples..."
if [ ! -f "examples/simple-cluster.sh" ]; then
    error "Examples incomplete"
    exit 1
fi

# Test 12: All test scripts exist
log "Test 12: Checking test scripts..."
for test_script in tests/*_test.sh; do
    if [ ! -f "$test_script" ]; then
        error "Test script missing: $test_script"
        exit 1
    fi
done

# Test 13: Run Keycloak-specific tests
log "Test 13: Running Keycloak-specific tests..."
bash tests/keycloak-integration-test.sh

log "All tests passed!"
log "Twinbox Full-Stack Kubernetes with Keycloak is ready for deployment."
```

**Step 4: Run test to verify it passes**
Run: `bash tests/final_keycloak_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add tests/keycloak-integration-test.sh tests/run-all-tests.sh
git commit -m "Add Keycloak integration tests and update test runner"
```

## Summary

The Twinbox Open Source Kubernetes platform is now complete with Keycloak integration:

1. **Talos Linux** on Proxmox infrastructure with automated VM management
2. **Rook/Ceph** distributed storage solution with proper configuration
3. **Traefik** ingress controller for external access
4. **ArgoCD** GitOps for continuous delivery
5. **Cloudflare Tunnels** for secure public access
6. **Keycloak** for centralized user management and SSO (open source alternative to Authentik)
7. Complete deployment automation and documentation

The platform provides a production-ready infrastructure that combines security (via Talos), scalability (via Ceph), accessibility (via Traefik and Cloudflare), operational efficiency (via GitOps), and centralized identity management (via Keycloak). All components are open source and actively maintained projects. All components work together to create a comprehensive Kubernetes platform suitable for various workloads with enterprise-grade identity and access management.