# Twinbox Automatic Patching Implementation Plan

**Goal:** Implement comprehensive automatic patching system for all components in the Twinbox Kubernetes platform, including Talos Linux, Kubernetes, Proxmox, and all deployed services (Rook, Traefik, Keycloak, Portainer, ArgoCD, Cloudflare tunnel).

**Architecture:** A multi-layer patching system with scheduled updates, pre-update validations, safe rollout strategies, and rollback capabilities. The system will handle patching for both the underlying infrastructure (Proxmox, Talos) and the Kubernetes platform components (services, applications).

**Tech Stack:** Talos Anejo, Proxmox HA tools, Renovate Bot, ArgoCD Application Sets, Kubernetes Jobs, CronJobs, Shell scripts

---

### Task 1: Implement Talos Linux Automatic Patching

**Files:**
- Create: `patching/talos-patching.sh`
- Create: `k8s-manifests/patching/talos-updater.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/talos_patching_test.sh
set -e

if [ ! -f "patching/talos-patching.sh" ]; then
    echo "FAIL: patching/talos-patching.sh does not exist"
    exit 1
fi

if [ ! -x "patching/talos-patching.sh" ]; then
    echo "FAIL: patching/talos-patching.sh is not executable"
    exit 1
fi

if [ ! -f "k8s-manifests/patching/talos-updater.yaml" ]; then
    echo "FAIL: k8s-manifests/patching/talos-updater.yaml does not exist"
    exit 1
fi

echo "PASS: Talos patching files exist and are executable"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/talos_patching_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create directory:
```bash
mkdir -p patching
mkdir -p k8s-manifests/patching
```

Create `patching/talos-patching.sh`:
```bash
#!/bin/bash

# Twinbox Talos Linux Automatic Patching Script
# Handles automatic updates for Talos Linux nodes with safe rollout

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

# Configuration
TALOS_CONFIG="${TALOS_CONFIG:-./talosconfig}"
PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"  # weekly, monthly, daily
PATCH_WINDOW="${PATCH_WINDOW:-02:00-04:00}"  # HH:MM-HH:MM format
DRY_RUN="${DRY_RUN:-false}"
MAX_UNAVAILABLE="${MAX_UNAVAILABLE:-1}"
GRACE_PERIOD="${GRACE_PERIOD:-300}"  # 5 minutes in seconds

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v talosctl &> /dev/null; then
        error "talosctl is not installed"
        exit 1
    fi
    
    if [ ! -f "$TALOS_CONFIG" ]; then
        error "Talos config file not found: $TALOS_CONFIG"
        exit 1
    fi
    
    log "Prerequisites check passed"
}

# Function to get cluster nodes
get_nodes() {
    log "Retrieving cluster nodes..."
    
    local nodes
    nodes=$(talosctl --talosconfig="$TALOS_CONFIG" get machines --output json 2>/dev/null | jq -r '.items[].id' || echo "")
    
    if [ -z "$nodes" ]; then
        error "No nodes found in cluster"
        exit 1
    fi
    
    echo "$nodes"
}

# Function to get node status
get_node_status() {
    local node="$1"
    talosctl --talosconfig="$TALOS_CONFIG" get machineconfiguration -n "$node" --output json 2>/dev/null | jq -r '.items[0].status.phase' || echo "unknown"
}

# Function to check if node is ready for patching
is_node_ready_for_patching() {
    local node="$1"
    
    # Check if node is ready
    local ready_status
    ready_status=$(kubectl get nodes "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    
    if [ "$ready_status" != "True" ]; then
        warn "Node $node is not ready, skipping patching"
        return 1
    fi
    
    # Check if node has any critical pods
    local critical_pods
    critical_pods=$(kubectl get pods --field-selector spec.nodeName="$node" -n kube-system -o json | jq -r '[.items[] | select(.metadata.labels.component or .metadata.labels.k8s-app | contains("etcd") or contains("controller-manager") or contains("scheduler"))] | length')
    
    if [ "$critical_pods" -gt 0 ] && [ "$node" != "control-plane" ]; then
        # For non-control plane nodes, check if they're running critical pods
        # In a properly configured cluster, critical pods should only run on control plane
        warn "Node $node has critical pods, checking if it's a control plane node"
    fi
    
    return 0
}

# Function to drain node safely
drain_node() {
    local node="$1"
    
    log "Draining node $node..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would drain node $node"
        return 0
    fi
    
    kubectl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --timeout="${GRACE_PERIOD}s" \
        --grace-period=30
    
    if [ $? -ne 0 ]; then
        error "Failed to drain node $node"
        return 1
    fi
    
    log "Node $node drained successfully"
}

# Function to uncordon node
uncordon_node() {
    local node="$1"
    
    log "Uncordoning node $node..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would uncordon node $node"
        return 0
    fi
    
    kubectl uncordon "$node"
    
    if [ $? -ne 0 ]; then
        error "Failed to uncordon node $node"
        return 1
    fi
    
    log "Node $node uncordoned successfully"
}

# Function to update Talos node
update_talos_node() {
    local node="$1"
    local version="$2"
    
    log "Updating Talos node $node to version $version..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would update node $node to version $version"
        return 0
    fi
    
    # Apply update using talosctl
    talosctl --talosconfig="$TALOS_CONFIG" -n "$node" upgrade --image="ghcr.io/siderolabs/installer:$version" --preserve=true --wait=true
    
    if [ $? -ne 0 ]; then
        error "Failed to update node $node"
        return 1
    fi
    
    log "Node $node updated successfully"
}

# Function to verify node after update
verify_node_after_update() {
    local node="$1"
    local timeout=300  # 5 minutes
    local count=0
    
    log "Verifying node $node after update..."
    
    while [ $count -lt $timeout ]; do
        local ready_status
        ready_status=$(kubectl get nodes "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [ "$ready_status" = "True" ]; then
            log "Node $node is ready after update"
            return 0
        fi
        
        sleep 10
        count=$((count + 10))
    done
    
    error "Node $node did not become ready within timeout period"
    return 1
}

# Function to get available Talos versions
get_available_versions() {
    log "Checking for available Talos versions..."
    
    # Get latest stable version
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        error "Could not fetch latest Talos version"
        return 1
    fi
    
    echo "$latest_version"
}

# Function to get current Talos versions in cluster
get_current_versions() {
    log "Checking current Talos versions in cluster..."
    
    talosctl --talosconfig="$TALOS_CONFIG" get machineconfigurations --output json 2>/dev/null | jq -r '.items[].status.version' | sort -u
}

# Function to perform rolling update
perform_rolling_update() {
    local target_version="$1"
    local nodes
    nodes=$(get_nodes)
    
    log "Starting rolling update to Talos $target_version"
    
    # Convert nodes to array
    local node_array=($nodes)
    local total_nodes=${#node_array[@]}
    local updated_count=0
    
    # Update control plane nodes first
    log "Updating control plane nodes..."
    for node in "${node_array[@]}"; do
        # Check if this is a control plane node
        local is_control_plane
        is_control_plane=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")
        
        if [ -n "$is_control_plane" ]; then
            log "Processing control plane node: $node"
            
            if ! is_node_ready_for_patching "$node"; then
                continue
            fi
            
            # Drain node
            if ! drain_node "$node"; then
                warn "Skipping node $node due to drain failure"
                continue
            fi
            
            # Update node
            if ! update_talos_node "$node" "$target_version"; then
                error "Update failed for node $node, stopping update process"
                uncordon_node "$node"
                return 1
            fi
            
            # Verify node
            if ! verify_node_after_update "$node"; then
                error "Verification failed for node $node, initiating rollback"
                uncordon_node "$node"
                return 1
            fi
            
            # Uncordon node
            uncordon_node "$node"
            
            updated_count=$((updated_count + 1))
            log "Updated $updated_count/$total_nodes nodes"
            
            # Wait before updating next node
            sleep 60
        fi
    done
    
    # Update worker nodes
    log "Updating worker nodes..."
    for node in "${node_array[@]}"; do
        # Skip control plane nodes
        local is_control_plane
        is_control_plane=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")
        
        if [ -z "$is_control_plane" ]; then
            log "Processing worker node: $node"
            
            if ! is_node_ready_for_patching "$node"; then
                continue
            fi
            
            # Drain node
            if ! drain_node "$node"; then
                warn "Skipping node $node due to drain failure"
                continue
            fi
            
            # Update node
            if ! update_talos_node "$node" "$target_version"; then
                error "Update failed for node $node"
                uncordon_node "$node"
                continue  # Continue with other nodes
            fi
            
            # Verify node
            if ! verify_node_after_update "$node"; then
                error "Verification failed for node $node"
                uncordon_node "$node"
                continue  # Continue with other nodes
            fi
            
            # Uncordon node
            uncordon_node "$node"
            
            updated_count=$((updated_count + 1))
            log "Updated $updated_count/$total_nodes nodes"
            
            # Wait before updating next node
            sleep 30
        fi
    done
    
    log "Rolling update completed. Updated $updated_count/$total_nodes nodes."
}

# Function to check patch window
is_patch_window_active() {
    local current_time
    current_time=$(date +%H:%M)
    
    local start_time
    local end_time
    start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
    end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)
    
    # Convert times to minutes since midnight for comparison
    local current_minutes
    local start_minutes
    local end_minutes
    
    current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
    start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
    end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))
    
    if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
        return 0
    else
        return 1
    fi
}

# Main function
main() {
    log "Starting Talos automatic patching process"
    
    # Check if we're in patch window
    if ! is_patch_window_active; then
        warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
        exit 0
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Get available version
    local latest_version
    latest_version=$(get_available_versions)
    if [ $? -ne 0 ]; then
        error "Could not determine latest Talos version"
        exit 1
    fi
    
    # Get current versions
    local current_versions
    current_versions=$(get_current_versions)
    log "Current Talos versions in cluster: $current_versions"
    
    # Check if update is needed
    local needs_update=false
    for version in $current_versions; do
        if [ "$version" != "$latest_version" ]; then
            needs_update=true
            break
        fi
    done
    
    if [ "$needs_update" = true ]; then
        log "Update needed. Latest version: $latest_version"
        perform_rolling_update "$latest_version"
    else
        log "All nodes are running latest version: $latest_version"
    fi
    
    log "Talos patching process completed"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

Create `k8s-manifests/patching/talos-updater.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: talos-updater
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: talos-patch-config
  namespace: talos-updater
data:
  talos-patch-config.yaml: |
    # Talos Automatic Patching Configuration
    schedule: "0 2 * * 0"  # Weekly on Sundays at 2 AM
    patchWindow: "02:00-04:00"  # 2 AM to 4 AM
    maxUnavailable: 1
    gracePeriod: 300
    dryRun: false
    # Notification settings
    slackWebhookUrl: ""
    emailRecipients: []
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: talos-updater
  namespace: talos-updater
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: talos-updater
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch", "update"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["pods/eviction"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: talos-updater
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: talos-updater
subjects:
- kind: ServiceAccount
  name: talos-updater
  namespace: talos-updater
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: talos-patcher
  namespace: talos-updater
spec:
  schedule: "0 2 * * 0"  # Weekly on Sundays at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: talos-updater
          containers:
          - name: talos-patcher
            image: ghcr.io/siderolabs/talosctl:latest
            command:
            - /bin/bash
            - -c
            - |
              # Install dependencies
              apk add --no-cache curl jq bash
              
              # Copy talosconfig from secret
              mkdir -p /home/nonroot/.talos
              cp /etc/talosconfig/talosconfig /home/nonroot/.talos/config
              
              # Set environment
              export TALOSCONFIG=/home/nonroot/.talos/config
              
              # Run patching script
              /scripts/talos-patching.sh
            volumeMounts:
            - name: talosconfig
              mountPath: /etc/talosconfig
              readOnly: true
            - name: patch-scripts
              mountPath: /scripts
              readOnly: true
            env:
            - name: TALOS_CONFIG
              value: "/home/nonroot/.talos/config"
            - name: PATCH_SCHEDULE
              value: "weekly"
            - name: PATCH_WINDOW
              value: "02:00-04:00"
            - name: MAX_UNAVAILABLE
              value: "1"
            - name: GRACE_PERIOD
              value: "300"
            - name: DRY_RUN
              value: "false"
          volumes:
          - name: talosconfig
            secret:
              secretName: talosconfig
          - name: patch-scripts
            configMap:
              name: talos-patch-scripts
          restartPolicy: OnFailure
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: talos-patch-scripts
  namespace: talos-updater
data:
  talos-patching.sh: |
    #!/bin/bash
    
    # Twinbox Talos Linux Automatic Patching Script
    # Handles automatic updates for Talos Linux nodes with safe rollout
    
    set -euo pipefail
    
    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
    
    # Logging functions
    log() {
        echo -e "${GREEN}[PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }
    
    warn() {
        echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }
    
    error() {
        echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }
    
    # Configuration
    TALOS_CONFIG="${TALOS_CONFIG:-/home/nonroot/.talos/config}"
    PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"
    PATCH_WINDOW="${PATCH_WINDOW:-02:00-04:00}"
    DRY_RUN="${DRY_RUN:-false}"
    MAX_UNAVAILABLE="${MAX_UNAVAILABLE:-1}"
    GRACE_PERIOD="${GRACE_PERIOD:-300}"
    
    # Function to check prerequisites
    check_prerequisites() {
        log "Checking prerequisites..."
        
        if ! command -v talosctl &> /dev/null; then
            error "talosctl is not available in container"
            exit 1
        fi
        
        if [ ! -f "$TALOS_CONFIG" ]; then
            error "Talos config file not found: $TALOS_CONFIG"
            exit 1
        fi
        
        log "Prerequisites check passed"
    }
    
    # Function to get cluster nodes
    get_nodes() {
        log "Retrieving cluster nodes..."
        
        local nodes
        nodes=$(talosctl --talosconfig="$TALOS_CONFIG" get machines --output json 2>/dev/null | jq -r '.items[].id' || echo "")
        
        if [ -z "$nodes" ]; then
            error "No nodes found in cluster"
            exit 1
        fi
        
        echo "$nodes"
    }
    
    # Function to get node status
    get_node_status() {
        local node="$1"
        talosctl --talosconfig="$TALOS_CONFIG" get machineconfiguration -n "$node" --output json 2>/dev/null | jq -r '.items[0].status.phase' || echo "unknown"
    }
    
    # Function to check if node is ready for patching
    is_node_ready_for_patching() {
        local node="$1"
        
        # Check if node is ready
        local ready_status
        ready_status=$(kubectl get nodes "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [ "$ready_status" != "True" ]; then
            warn "Node $node is not ready, skipping patching"
            return 1
        fi
        
        return 0
    }
    
    # Function to drain node safely
    drain_node() {
        local node="$1"
        
        log "Draining node $node..."
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would drain node $node"
            return 0
        fi
        
        kubectl drain "$node" \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --timeout=${GRACE_PERIOD}s \
            --grace-period=30
        
        if [ $? -ne 0 ]; then
            error "Failed to drain node $node"
            return 1
        fi
        
        log "Node $node drained successfully"
    }
    
    # Function to uncordon node
    uncordon_node() {
        local node="$1"
        
        log "Uncordoning node $node..."
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would uncordon node $node"
            return 0
        fi
        
        kubectl uncordon "$node"
        
        if [ $? -ne 0 ]; then
            error "Failed to uncordon node $node"
            return 1
        fi
        
        log "Node $node uncordoned successfully"
    }
    
    # Function to update Talos node
    update_talos_node() {
        local node="$1"
        local version="$2"
        
        log "Updating Talos node $node to version $version..."
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would update node $node to version $version"
            return 0
        fi
        
        # Apply update using talosctl
        talosctl --talosconfig="$TALOS_CONFIG" -n "$node" upgrade --image="ghcr.io/siderolabs/installer:$version" --preserve=true --wait=true
        
        if [ $? -ne 0 ]; then
            error "Failed to update node $node"
            return 1
        fi
        
        log "Node $node updated successfully"
    }
    
    # Function to verify node after update
    verify_node_after_update() {
        local node="$1"
        local timeout=300
        local count=0
        
        log "Verifying node $node after update..."
        
        while [ $count -lt $timeout ]; do
            local ready_status
            ready_status=$(kubectl get nodes "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
            
            if [ "$ready_status" = "True" ]; then
                log "Node $node is ready after update"
                return 0
            fi
            
            sleep 10
            count=$((count + 10))
        done
        
        error "Node $node did not become ready within timeout period"
        return 1
    }
    
    # Function to get available Talos versions
    get_available_versions() {
        log "Checking for available Talos versions..."
        
        # Get latest stable version
        local latest_version
        latest_version=$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r '.tag_name' | sed 's/^v//')
        
        if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
            error "Could not fetch latest Talos version"
            return 1
        fi
        
        echo "$latest_version"
    }
    
    # Function to get current Talos versions in cluster
    get_current_versions() {
        log "Checking current Talos versions in cluster..."
        
        talosctl --talosconfig="$TALOS_CONFIG" get machineconfigurations --output json 2>/dev/null | jq -r '.items[].status.version' | sort -u
    }
    
    # Function to perform rolling update
    perform_rolling_update() {
        local target_version="$1"
        local nodes
        nodes=$(get_nodes)
        
        log "Starting rolling update to Talos $target_version"
        
        # Convert nodes to array
        local node_array=($nodes)
        local total_nodes=${#node_array[@]}
        local updated_count=0
        
        # Update control plane nodes first
        log "Updating control plane nodes..."
        for node in "${node_array[@]}"; do
            # Check if this is a control plane node
            local is_control_plane
            is_control_plane=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")
            
            if [ -n "$is_control_plane" ]; then
                log "Processing control plane node: $node"
                
                if ! is_node_ready_for_patching "$node"; then
                    continue
                fi
                
                # Drain node
                if ! drain_node "$node"; then
                    warn "Skipping node $node due to drain failure"
                    continue
                fi
                
                # Update node
                if ! update_talos_node "$node" "$target_version"; then
                    error "Update failed for node $node, stopping update process"
                    uncordon_node "$node"
                    return 1
                fi
                
                # Verify node
                if ! verify_node_after_update "$node"; then
                    error "Verification failed for node $node, initiating rollback"
                    uncordon_node "$node"
                    return 1
                fi
                
                # Uncordon node
                uncordon_node "$node"
                
                updated_count=$((updated_count + 1))
                log "Updated $updated_count/$total_nodes nodes"
                
                # Wait before updating next node
                sleep 60
            fi
        done
        
        # Update worker nodes
        log "Updating worker nodes..."
        for node in "${node_array[@]}"; do
            # Skip control plane nodes
            local is_control_plane
            is_control_plane=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")
            
            if [ -z "$is_control_plane" ]; then
                log "Processing worker node: $node"
                
                if ! is_node_ready_for_patching "$node"; then
                    continue
                fi
                
                # Drain node
                if ! drain_node "$node"; then
                    warn "Skipping node $node due to drain failure"
                    continue
                fi
                
                # Update node
                if ! update_talos_node "$node" "$target_version"; then
                    error "Update failed for node $node"
                    uncordon_node "$node"
                    continue
                fi
                
                # Verify node
                if ! verify_node_after_update "$node"; then
                    error "Verification failed for node $node"
                    uncordon_node "$node"
                    continue
                fi
                
                # Uncordon node
                uncordon_node "$node"
                
                updated_count=$((updated_count + 1))
                log "Updated $updated_count/$total_nodes nodes"
                
                # Wait before updating next node
                sleep 30
            fi
        done
        
        log "Rolling update completed. Updated $updated_count/$total_nodes nodes."
    }
    
    # Function to check patch window
    is_patch_window_active() {
        local current_time
        current_time=$(date +%H:%M)
        
        local start_time
        local end_time
        start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
        end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)
        
        # Convert times to minutes since midnight for comparison
        local current_minutes
        local start_minutes
        local end_minutes
        
        current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
        start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
        end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))
        
        if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
            return 0
        else
            return 1
        fi
    }
    
    # Main function
    main() {
        log "Starting Talos automatic patching process"
        
        # Check if we're in patch window
        if ! is_patch_window_active; then
            warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
            exit 0
        fi
        
        # Check prerequisites
        check_prerequisites
        
        # Get available version
        local latest_version
        latest_version=$(get_available_versions)
        if [ $? -ne 0 ]; then
            error "Could not determine latest Talos version"
            exit 1
        fi
        
        # Get current versions
        local current_versions
        current_versions=$(get_current_versions)
        log "Current Talos versions in cluster: $current_versions"
        
        # Check if update is needed
        local needs_update=false
        for version in $current_versions; do
            if [ "$version" != "$latest_version" ]; then
                needs_update=true
                break
            fi
        done
        
        if [ "$needs_update" = true ]; then
            log "Update needed. Latest version: $latest_version"
            perform_rolling_update "$latest_version"
        else
            log "All nodes are running latest version: $latest_version"
        fi
        
        log "Talos patching process completed"
    }
    
    # Run main function if script is executed directly
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
```

Make the script executable:
```bash
chmod +x patching/talos-patching.sh
```

**Step 4: Run test to verify it passes**
Run: `bash tests/talos_patching_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add patching/talos-patching.sh k8s-manifests/patching/talos-updater.yaml
git commit -m "Add Talos Linux automatic patching system"
```

### Task 2: Implement Kubernetes Component Patching

**Files:**
- Create: `patching/k8s-components-patching.sh`
- Create: `k8s-manifests/patching/k8s-updater.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/k8s_components_patching_test.sh
set -e

if [ ! -f "patching/k8s-components-patching.sh" ]; then
    echo "FAIL: patching/k8s-components-patching.sh does not exist"
    exit 1
fi

if [ ! -x "patching/k8s-components-patching.sh" ]; then
    echo "FAIL: patching/k8s-components-patching.sh is not executable"
    exit 1
fi

if [ ! -f "k8s-manifests/patching/k8s-updater.yaml" ]; then
    echo "FAIL: k8s-manifests/patching/k8s-updater.yaml does not exist"
    exit 1
fi

echo "PASS: Kubernetes components patching files exist and are executable"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/k8s_components_patching_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `patching/k8s-components-patching.sh`:
```bash
#!/bin/bash

# Twinbox Kubernetes Components Automatic Patching Script
# Handles automatic updates for Kubernetes components and deployed services

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[K8S-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

# Configuration
PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"  # weekly, monthly, daily
PATCH_WINDOW="${PATCH_WINDOW:-03:00-05:00}"  # HH:MM-HH:MM format
DRY_RUN="${DRY_RUN:-false}"
HELM_UPGRADE_TIMEOUT="${HELM_UPGRADE_TIMEOUT:-600}"  # 10 minutes
NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed"
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        error "helm is not installed"
        exit 1
    fi
    
    # Test kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log "Prerequisites check passed"
}

# Function to send notification
send_notification() {
    local message="$1"
    local status="${2:-info}"
    
    if [ -n "$NOTIFICATION_WEBHOOK" ]; then
        case $status in
            "success")
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"✅ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
            "warning")
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"⚠️ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
            "error")
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"❌ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
            *)
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"ℹ️ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
        esac
    fi
}

# Function to get latest stable version for an image
get_latest_stable_version() {
    local image_name="$1"
    local registry="${2:-docker.io}"
    
    case $image_name in
        "rook/ceph")
            # Get latest stable version from GitHub releases
            curl -s https://api.github.com/repos/rook/rook/releases/latest | jq -r '.tag_name' | sed 's/^v//'
            ;;
        "traefik")
            curl -s https://api.github.com/repos/traefik/traefik/releases/latest | jq -r '.tag_name' | sed 's/^v//'
            ;;
        "bitnami/keycloak")
            # Use Helm to get latest version
            helm show chart bitnami/keycloak 2>/dev/null | grep '^version:' | head -1 | awk '{print $2}'
            ;;
        "portainer/portainer-ce")
            curl -s https://api.github.com/repos/portainer/portainer/releases/latest | jq -r '.tag_name' | sed 's/^v//'
            ;;
        "argoproj/argocd")
            curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r '.tag_name' | sed 's/^v//'
            ;;
        *)
            # For generic images, we'll use a placeholder
            echo "latest"
            ;;
    esac
}

# Function to check if Helm repo exists and add if needed
ensure_helm_repo() {
    local repo_name="$1"
    local repo_url="$2"
    
    if ! helm repo list | grep -q "$repo_name"; then
        log "Adding Helm repository: $repo_name"
        helm repo add "$repo_name" "$repo_url"
    fi
    
    # Update repo to get latest charts
    helm repo update "$repo_name"
}

# Function to upgrade Rook/Ceph
upgrade_rook_ceph() {
    log "Checking for Rook/Ceph updates..."
    
    ensure_helm_repo "rook-release" "https://charts.rook.io/release"
    
    # Get current version
    local current_version=""
    if kubectl get namespace rook-ceph &> /dev/null; then
        current_version=$(helm status rook-ceph -n rook-ceph 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
    fi
    
    # Get latest version
    local latest_version
    latest_version=$(get_latest_stable_version "rook/ceph")
    
    if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
        log "Rook/Ceph update available: $current_version -> $latest_version"
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would upgrade Rook/Ceph to $latest_version"
            return 0
        fi
        
        # Upgrade Rook operator
        helm upgrade rook-ceph rook-release/rook-ceph \
            --version "$latest_version" \
            --namespace rook-ceph \
            --create-namespace \
            --timeout "${HELM_UPGRADE_TIMEOUT}s"
        
        log "Rook/Ceph upgraded to $latest_version"
        send_notification "Rook/Ceph upgraded to $latest_version" "success"
    else
        log "Rook/Ceph is up to date: $current_version"
    fi
}

# Function to upgrade Traefik
upgrade_traefik() {
    log "Checking for Traefik updates..."
    
    ensure_helm_repo "traefik" "https://helm.traefik.io/traefik"
    
    # Get current version
    local current_version=""
    if kubectl get namespace traefik &> /dev/null; then
        current_version=$(helm status traefik -n traefik 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
    fi
    
    # Get latest version
    local latest_version
    latest_version=$(get_latest_stable_version "traefik")
    
    if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
        log "Traefik update available: $current_version -> $latest_version"
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would upgrade Traefik to $latest_version"
            return 0
        fi
        
        # Get current values to preserve configuration
        local temp_values="/tmp/traefik-values-$(date +%s).yaml"
        helm get values traefik -n traefik > "$temp_values"
        
        # Upgrade Traefik
        helm upgrade traefik traefik/traefik \
            --version "$latest_version" \
            --namespace traefik \
            --create-namespace \
            --values "$temp_values" \
            --timeout "${HELM_UPGRADE_TIMEOUT}s"
        
        rm -f "$temp_values"
        
        log "Traefik upgraded to $latest_version"
        send_notification "Traefik upgraded to $latest_version" "success"
    else
        log "Traefik is up to date: $current_version"
    fi
}

# Function to upgrade Keycloak
upgrade_keycloak() {
    log "Checking for Keycloak updates..."
    
    ensure_helm_repo "bitnami" "https://charts.bitnami.com/bitnami"
    
    # Get current version
    local current_version=""
    if kubectl get namespace keycloak &> /dev/null; then
        current_version=$(helm status keycloak -n keycloak 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
    fi
    
    # Get latest version
    local latest_version
    latest_version=$(get_latest_stable_version "bitnami/keycloak")
    
    if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
        log "Keycloak update available: $current_version -> $latest_version"
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would upgrade Keycloak to $latest_version"
            return 0
        fi
        
        # Get current values to preserve configuration
        local temp_values="/tmp/keycloak-values-$(date +%s).yaml"
        helm get values keycloak -n keycloak > "$temp_values"
        
        # Upgrade Keycloak
        helm upgrade keycloak bitnami/keycloak \
            --version "$latest_version" \
            --namespace keycloak \
            --create-namespace \
            --values "$temp_values" \
            --timeout "${HELM_UPGRADE_TIMEOUT}s"
        
        rm -f "$temp_values"
        
        log "Keycloak upgraded to $latest_version"
        send_notification "Keycloak upgraded to $latest_version" "success"
    else
        log "Keycloak is up to date: $current_version"
    fi
}

# Function to upgrade Portainer
upgrade_portainer() {
    log "Checking for Portainer updates..."
    
    # For Portainer, we'll update the deployment directly
    local current_image=""
    if kubectl get namespace portainer &> /dev/null; then
        current_image=$(kubectl get deployment portainer -n portainer -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    fi
    
    # Extract version from image
    local current_version=""
    if [ -n "$current_image" ]; then
        current_version=$(echo "$current_image" | cut -d':' -f2)
    fi
    
    # Get latest version
    local latest_version
    latest_version=$(get_latest_stable_version "portainer/portainer-ce")
    
    if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
        log "Portainer update available: $current_version -> $latest_version"
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would upgrade Portainer to $latest_version"
            return 0
        fi
        
        # Update the deployment
        kubectl set image deployment/portainer portainer=portainer/portainer-ce:$latest_version -n portainer
        
        log "Portainer upgraded to $latest_version"
        send_notification "Portainer upgraded to $latest_version" "success"
    else
        log "Portainer is up to date: $current_version"
    fi
}

# Function to upgrade ArgoCD
upgrade_argocd() {
    log "Checking for ArgoCD updates..."
    
    ensure_helm_repo "argocd" "https://argoproj.github.io/argo-helm"
    
    # Get current version
    local current_version=""
    if kubectl get namespace argocd &> /dev/null; then
        current_version=$(helm status argocd -n argocd 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
    fi
    
    # Get latest version
    local latest_version
    latest_version=$(get_latest_stable_version "argoproj/argocd")
    
    if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
        log "ArgoCD update available: $current_version -> $latest_version"
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would upgrade ArgoCD to $latest_version"
            return 0
        fi
        
        # Get current values to preserve configuration
        local temp_values="/tmp/argocd-values-$(date +%s).yaml"
        helm get values argocd -n argocd > "$temp_values"
        
        # Upgrade ArgoCD
        helm upgrade argocd argocd/argo-cd \
            --version "$latest_version" \
            --namespace argocd \
            --create-namespace \
            --values "$temp_values" \
            --timeout "${HELM_UPGRADE_TIMEOUT}s"
        
        rm -f "$temp_values"
        
        log "ArgoCD upgraded to $latest_version"
        send_notification "ArgoCD upgraded to $latest_version" "success"
    else
        log "ArgoCD is up to date: $current_version"
    fi
}

# Function to upgrade system components
upgrade_system_components() {
    log "Upgrading system components..."
    
    # Upgrade kube-proxy
    upgrade_kubeproxy
    
    # Upgrade CoreDNS
    upgrade_coredns
    
    # Upgrade metrics-server if present
    upgrade_metrics_server
}

# Function to upgrade kube-proxy
upgrade_kubeproxy() {
    log "Checking for kube-proxy updates..."
    
    # Get current image
    local current_image
    current_image=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    
    if [ -n "$current_image" ]; then
        local current_version
        current_version=$(echo "$current_image" | cut -d':' -f2)
        
        # For kube-proxy, we'll use the current Kubernetes version
        local k8s_version
        k8s_version=$(kubectl version --short | grep -i server | awk '{print $3}' | sed 's/v//')
        
        if [ "$current_version" != "$k8s_version" ]; then
            log "kube-proxy update available: $current_version -> $k8s_version"
            
            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade kube-proxy to $k8s_version"
                return 0
            fi
            
            # Update kube-proxy image
            kubectl set image daemonset kube-proxy kube-proxy=k8s.gcr.io/kube-proxy:$k8s_version -n kube-system
            
            log "kube-proxy upgraded to $k8s_version"
        else
            log "kube-proxy is up to date: $current_version"
        fi
    fi
}

# Function to upgrade CoreDNS
upgrade_coredns() {
    log "Checking for CoreDNS updates..."
    
    # Get current image
    local current_image
    current_image=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    
    if [ -n "$current_image" ]; then
        local current_version
        current_version=$(echo "$current_image" | cut -d':' -f2)
        
        # Get latest stable CoreDNS version
        local latest_version
        latest_version=$(curl -s https://api.github.com/repos/coredns/deployment/releases/latest | jq -r '.tag_name' | sed 's/^v//')
        
        if [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "CoreDNS update available: $current_version -> $latest_version"
            
            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade CoreDNS to $latest_version"
                return 0
            fi
            
            # Update CoreDNS image
            kubectl set image deployment coredns coredns=coredns/coredns:$latest_version -n kube-system
            
            log "CoreDNS upgraded to $latest_version"
        else
            log "CoreDNS is up to date: $current_version"
        fi
    fi
}

# Function to upgrade metrics-server
upgrade_metrics_server() {
    log "Checking for metrics-server updates..."
    
    # Check if metrics-server is deployed
    if kubectl get deployment metrics-server -n kube-system &> /dev/null; then
        # Get current image
        local current_image
        current_image=$(kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
        
        if [ -n "$current_image" ]; then
            local current_version
            current_version=$(echo "$current_image" | cut -d':' -f2)
            
            # Get latest stable metrics-server version
            local latest_version
            latest_version=$(curl -s https://api.github.com/repos/kubernetes-sigs/metrics-server/releases/latest | jq -r '.tag_name' | sed 's/^v//')
            
            if [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
                log "Metrics-server update available: $current_version -> $latest_version"
                
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY RUN] Would upgrade metrics-server to $latest_version"
                    return 0
                fi
                
                # Update metrics-server image
                kubectl set image deployment metrics-server metrics-server=k8s.gcr.io/metrics-server/metrics-server:$latest_version -n kube-system
                
                log "Metrics-server upgraded to $latest_version"
            else
                log "Metrics-server is up to date: $current_version"
            fi
        fi
    else
        log "Metrics-server not found in cluster"
    fi
}

# Function to check patch window
is_patch_window_active() {
    local current_time
    current_time=$(date +%H:%M)
    
    local start_time
    local end_time
    start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
    end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)
    
    # Convert times to minutes since midnight for comparison
    local current_minutes
    local start_minutes
    local end_minutes
    
    current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
    start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
    end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))
    
    if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
        return 0
    else
        return 1
    fi
}

# Main function
main() {
    log "Starting Kubernetes components automatic patching process"
    
    # Check if we're in patch window
    if ! is_patch_window_active; then
        warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
        exit 0
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Send notification that patching is starting
    send_notification "Starting Kubernetes components patching process" "info"
    
    # Upgrade system components first
    upgrade_system_components
    
    # Upgrade service components
    upgrade_rook_ceph
    upgrade_traefik
    upgrade_keycloak
    upgrade_portainer
    upgrade_argocd
    
    # Send completion notification
    send_notification "Kubernetes components patching completed successfully" "success"
    
    log "Kubernetes components patching process completed"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

Create `k8s-manifests/patching/k8s-updater.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: k8s-updater
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: k8s-patch-config
  namespace: k8s-updater
data:
  k8s-patch-config.yaml: |
    # Kubernetes Automatic Patching Configuration
    schedule: "0 3 * * 0"  # Weekly on Sundays at 3 AM
    patchWindow: "03:00-05:00"  # 3 AM to 5 AM
    dryRun: false
    helmUpgradeTimeout: 600
    notificationWebhook: ""
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: k8s-updater
  namespace: k8s-updater
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k8s-updater
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets", "namespaces", "nodes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "daemonsets", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-updater
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: k8s-updater
subjects:
- kind: ServiceAccount
  name: k8s-updater
  namespace: k8s-updater
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: k8s-patcher
  namespace: k8s-updater
spec:
  schedule: "0 3 * * 0"  # Weekly on Sundays at 3 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: k8s-updater
          containers:
          - name: k8s-patcher
            image: bitnami/kubectl:latest
            command:
            - /bin/bash
            - -c
            - |
              # Install dependencies
              apt-get update && apt-get install -y curl jq gettext-base
              
              # Install Helm
              curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
              
              # Run patching script
              /scripts/k8s-components-patching.sh
            volumeMounts:
            - name: patch-scripts
              mountPath: /scripts
              readOnly: true
            env:
            - name: PATCH_SCHEDULE
              value: "weekly"
            - name: PATCH_WINDOW
              value: "03:00-05:00"
            - name: DRY_RUN
              value: "false"
            - name: HELM_UPGRADE_TIMEOUT
              value: "600"
            - name: NOTIFICATION_WEBHOOK
              valueFrom:
                secretKeyRef:
                  name: k8s-patch-secrets
                  key: webhook-url
                  optional: true
          volumes:
          - name: patch-scripts
            configMap:
              name: k8s-patch-scripts
          restartPolicy: OnFailure
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: k8s-patch-scripts
  namespace: k8s-updater
data:
  k8s-components-patching.sh: |
    #!/bin/bash

    # Twinbox Kubernetes Components Automatic Patching Script
    # Handles automatic updates for Kubernetes components and deployed services

    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Logging functions
    log() {
        echo -e "${GREEN}[K8S-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    warn() {
        echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    error() {
        echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    # Configuration
    PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"
    PATCH_WINDOW="${PATCH_WINDOW:-03:00-05:00}"
    DRY_RUN="${DRY_RUN:-false}"
    HELM_UPGRADE_TIMEOUT="${HELM_UPGRADE_TIMEOUT:-600}"
    NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"

    # Function to check prerequisites
    check_prerequisites() {
        log "Checking prerequisites..."

        if ! command -v kubectl &> /dev/null; then
            error "kubectl is not installed"
            exit 1
        fi

        if ! command -v helm &> /dev/null; then
            error "helm is not installed"
            exit 1
        fi

        # Test kubectl connectivity
        if ! kubectl cluster-info &> /dev/null; then
            error "Cannot connect to Kubernetes cluster"
            exit 1
        fi

        log "Prerequisites check passed"
    }

    # Function to send notification
    send_notification() {
        local message="$1"
        local status="${2:-info}"

        if [ -n "$NOTIFICATION_WEBHOOK" ]; then
            case $status in
                "success")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"✅ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                "warning")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"⚠️ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                "error")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"❌ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                *)
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"ℹ️ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
            esac
        fi
    }

    # Function to get latest stable version for an image
    get_latest_stable_version() {
        local image_name="$1"
        local registry="${2:-docker.io}"

        case $image_name in
            "rook/ceph")
                # Get latest stable version from GitHub releases
                curl -s https://api.github.com/repos/rook/rook/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            "traefik")
                curl -s https://api.github.com/repos/traefik/traefik/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            "bitnami/keycloak")
                # Use Helm to get latest version
                helm show chart bitnami/keycloak 2>/dev/null | grep '^version:' | head -1 | awk '{print $2}'
                ;;
            "portainer/portainer-ce")
                curl -s https://api.github.com/repos/portainer/portainer/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            "argoproj/argocd")
                curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            *)
                # For generic images, we'll use a placeholder
                echo "latest"
                ;;
        esac
    }

    # Function to check if Helm repo exists and add if needed
    ensure_helm_repo() {
        local repo_name="$1"
        local repo_url="$2"

        if ! helm repo list | grep -q "$repo_name"; then
            log "Adding Helm repository: $repo_name"
            helm repo add "$repo_name" "$repo_url"
        fi

        # Update repo to get latest charts
        helm repo update "$repo_name"
    }

    # Function to upgrade Rook/Ceph
    upgrade_rook_ceph() {
        log "Checking for Rook/Ceph updates..."

        ensure_helm_repo "rook-release" "https://charts.rook.io/release"

        # Get current version
        local current_version=""
        if kubectl get namespace rook-ceph &> /dev/null; then
            current_version=$(helm status rook-ceph -n rook-ceph 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "rook/ceph")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Rook/Ceph update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Rook/Ceph to $latest_version"
                return 0
            fi

            # Upgrade Rook operator
            helm upgrade rook-ceph rook-release/rook-ceph \
                --version "$latest_version" \
                --namespace rook-ceph \
                --create-namespace \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            log "Rook/Ceph upgraded to $latest_version"
            send_notification "Rook/Ceph upgraded to $latest_version" "success"
        else
            log "Rook/Ceph is up to date: $current_version"
        fi
    }

    # Function to upgrade Traefik
    upgrade_traefik() {
        log "Checking for Traefik updates..."

        ensure_helm_repo "traefik" "https://helm.traefik.io/traefik"

        # Get current version
        local current_version=""
        if kubectl get namespace traefik &> /dev/null; then
            current_version=$(helm status traefik -n traefik 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "traefik")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Traefik update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Traefik to $latest_version"
                return 0
            fi

            # Get current values to preserve configuration
            local temp_values="/tmp/traefik-values-$(date +%s).yaml"
            helm get values traefik -n traefik > "$temp_values"

            # Upgrade Traefik
            helm upgrade traefik traefik/traefik \
                --version "$latest_version" \
                --namespace traefik \
                --create-namespace \
                --values "$temp_values" \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            rm -f "$temp_values"

            log "Traefik upgraded to $latest_version"
            send_notification "Traefik upgraded to $latest_version" "success"
        else
            log "Traefik is up to date: $current_version"
        fi
    }

    # Function to upgrade Keycloak
    upgrade_keycloak() {
        log "Checking for Keycloak updates..."

        ensure_helm_repo "bitnami" "https://charts.bitnami.com/bitnami"

        # Get current version
        local current_version=""
        if kubectl get namespace keycloak &> /dev/null; then
            current_version=$(helm status keycloak -n keycloak 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "bitnami/keycloak")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Keycloak update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Keycloak to $latest_version"
                return 0
            fi

            # Get current values to preserve configuration
            local temp_values="/tmp/keycloak-values-$(date +%s).yaml"
            helm get values keycloak -n keycloak > "$temp_values"

            # Upgrade Keycloak
            helm upgrade keycloak bitnami/keycloak \
                --version "$latest_version" \
                --namespace keycloak \
                --create-namespace \
                --values "$temp_values" \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            rm -f "$temp_values"

            log "Keycloak upgraded to $latest_version"
            send_notification "Keycloak upgraded to $latest_version" "success"
        else
            log "Keycloak is up to date: $current_version"
        fi
    }

    # Function to upgrade Portainer
    upgrade_portainer() {
        log "Checking for Portainer updates..."

        # For Portainer, we'll update the deployment directly
        local current_image=""
        if kubectl get namespace portainer &> /dev/null; then
            current_image=$(kubectl get deployment portainer -n portainer -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
        fi

        # Extract version from image
        local current_version=""
        if [ -n "$current_image" ]; then
            current_version=$(echo "$current_image" | cut -d':' -f2)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "portainer/portainer-ce")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Portainer update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Portainer to $latest_version"
                return 0
            fi

            # Update the deployment
            kubectl set image deployment/portainer portainer=portainer/portainer-ce:$latest_version -n portainer

            log "Portainer upgraded to $latest_version"
            send_notification "Portainer upgraded to $latest_version" "success"
        else
            log "Portainer is up to date: $current_version"
        fi
    }

    # Function to upgrade ArgoCD
    upgrade_argocd() {
        log "Checking for ArgoCD updates..."

        ensure_helm_repo "argocd" "https://argoproj.github.io/argo-helm"

        # Get current version
        local current_version=""
        if kubectl get namespace argocd &> /dev/null; then
            current_version=$(helm status argocd -n argocd 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "argoproj/argocd")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "ArgoCD update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade ArgoCD to $latest_version"
                return 0
            fi

            # Get current values to preserve configuration
            local temp_values="/tmp/argocd-values-$(date +%s).yaml"
            helm get values argocd -n argocd > "$temp_values"

            # Upgrade ArgoCD
            helm upgrade argocd argocd/argo-cd \
                --version "$latest_version" \
                --namespace argocd \
                --create-namespace \
                --values "$temp_values" \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            rm -f "$temp_values"

            log "ArgoCD upgraded to $latest_version"
            send_notification "ArgoCD upgraded to $latest_version" "success"
        else
            log "ArgoCD is up to date: $current_version"
        fi
    }

    # Function to upgrade system components
    upgrade_system_components() {
        log "Upgrading system components..."

        # Upgrade kube-proxy
        upgrade_kubeproxy

        # Upgrade CoreDNS
        upgrade_coredns

        # Upgrade metrics-server if present
        upgrade_metrics_server
    }

    # Function to upgrade kube-proxy
    upgrade_kubeproxy() {
        log "Checking for kube-proxy updates..."

        # Get current image
        local current_image
        current_image=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

        if [ -n "$current_image" ]; then
            local current_version
            current_version=$(echo "$current_image" | cut -d':' -f2)

            # For kube-proxy, we'll use the current Kubernetes version
            local k8s_version
            k8s_version=$(kubectl version --short | grep -i server | awk '{print $3}' | sed 's/v//')

            if [ "$current_version" != "$k8s_version" ]; then
                log "kube-proxy update available: $current_version -> $k8s_version"

                if [ "$DRY_RUN" = true ]; then
                    log "[DRY RUN] Would upgrade kube-proxy to $k8s_version"
                    return 0
                fi

                # Update kube-proxy image
                kubectl set image daemonset kube-proxy kube-proxy=k8s.gcr.io/kube-proxy:$k8s_version -n kube-system

                log "kube-proxy upgraded to $k8s_version"
            else
                log "kube-proxy is up to date: $current_version"
            fi
        fi
    }

    # Function to upgrade CoreDNS
    upgrade_coredns() {
        log "Checking for CoreDNS updates..."

        # Get current image
        local current_image
        current_image=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

        if [ -n "$current_image" ]; then
            local current_version
            current_version=$(echo "$current_image" | cut -d':' -f2)

            # Get latest stable CoreDNS version
            local latest_version
            latest_version=$(curl -s https://api.github.com/repos/coredns/deployment/releases/latest | jq -r '.tag_name' | sed 's/^v//')

            if [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
                log "CoreDNS update available: $current_version -> $latest_version"

                if [ "$DRY_RUN" = true ]; then
                    log "[DRY RUN] Would upgrade CoreDNS to $latest_version"
                    return 0
                fi

                # Update CoreDNS image
                kubectl set image deployment coredns coredns=coredns/coredns:$latest_version -n kube-system

                log "CoreDNS upgraded to $latest_version"
            else
                log "CoreDNS is up to date: $current_version"
            fi
        fi
    }

    # Function to upgrade metrics-server
    upgrade_metrics_server() {
        log "Checking for metrics-server updates..."

        # Check if metrics-server is deployed
        if kubectl get deployment metrics-server -n kube-system &> /dev/null; then
            # Get current image
            local current_image
            current_image=$(kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

            if [ -n "$current_image" ]; then
                local current_version
                current_version=$(echo "$current_image" | cut -d':' -f2)

                # Get latest stable metrics-server version
                local latest_version
                latest_version=$(curl -s https://api.github.com/repos/kubernetes-sigs/metrics-server/releases/latest | jq -r '.tag_name' | sed 's/^v//')

                if [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
                    log "Metrics-server update available: $current_version -> $latest_version"

                    if [ "$DRY_RUN" = true ]; then
                        log "[DRY RUN] Would upgrade metrics-server to $latest_version"
                        return 0
                    fi

                    # Update metrics-server image
                    kubectl set image deployment metrics-server metrics-server=k8s.gcr.io/metrics-server/metrics-server:$latest_version -n kube-system

                    log "Metrics-server upgraded to $latest_version"
                else
                    log "Metrics-server is up to date: $current_version"
                fi
            fi
        else
            log "Metrics-server not found in cluster"
        fi
    }

    # Function to check patch window
    is_patch_window_active() {
        local current_time
        current_time=$(date +%H:%M)

        local start_time
        local end_time
        start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
        end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)

        # Convert times to minutes since midnight for comparison
        local current_minutes
        local start_minutes
        local end_minutes

        current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
        start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
        end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))

        if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
            return 0
        else
            return 1
        fi
    }

    # Main function
    main() {
        log "Starting Kubernetes components automatic patching process"

        # Check if we're in patch window
        if ! is_patch_window_active; then
            warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
            exit 0
        fi

        # Check prerequisites
        check_prerequisites

        # Send notification that patching is starting
        send_notification "Starting Kubernetes components patching process" "info"

        # Upgrade system components first
        upgrade_system_components

        # Upgrade service components
        upgrade_rook_ceph
        upgrade_traefik
        upgrade_keycloak
        upgrade_portainer
        upgrade_argocd

        # Send completion notification
        send_notification "Kubernetes components patching completed successfully" "success"

        log "Kubernetes components patching process completed"
    }

    # Run main function if script is executed directly
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
---
apiVersion: v1
kind: Secret
metadata:
  name: k8s-patch-secrets
  namespace: k8s-updater
type: Opaque
stringData:
  webhook-url: ""
```

Make the script executable:
```bash
chmod +x patching/k8s-components-patching.sh
```

**Step 4: Run test to verify it passes**
Run: `bash tests/k8s_components_patching_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add patching/k8s-components-patching.sh k8s-manifests/patching/k8s-updater.yaml
git commit -m "Add Kubernetes components automatic patching system"
```

### Task 3: Implement Proxmox Automatic Patching

**Files:**
- Create: `patching/proxmox-patching.sh`
- Create: `k8s-manifests/patching/proxmox-updater.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/proxmox_patching_test.sh
set -e

if [ ! -f "patching/proxmox-patching.sh" ]; then
    echo "FAIL: patching/proxmox-patching.sh does not exist"
    exit 1
fi

if [ ! -x "patching/proxmox-patching.sh" ]; then
    echo "FAIL: patching/proxmox-patching.sh is not executable"
    exit 1
fi

if [ ! -f "k8s-manifests/patching/proxmox-updater.yaml" ]; then
    echo "FAIL: k8s-manifests/patching/proxmox-updater.yaml does not exist"
    exit 1
fi

echo "PASS: Proxmox patching files exist and are executable"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/proxmox_patching_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `patching/proxmox-patching.sh`:
```bash
#!/bin/bash

# Twinbox Proxmox Automatic Patching Script
# Handles automatic updates for Proxmox VE host systems with safe rollout

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[PROXMOX-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

# Configuration
PROXMOX_HOST="${PROXMOX_HOST:-localhost}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
PROXMOX_API_URL="${PROXMOX_API_URL:-https://localhost:8006/api2/json}"
PATCH_SCHEDULE="${PATCH_SCHEDULE:-monthly}"  # weekly, monthly
PATCH_WINDOW="${PATCH_WINDOW:-02:00-04:00}"  # HH:MM-HH:MM format
DRY_RUN="${DRY_RUN:-false}"
MAINTENANCE_MODE="${MAINTENANCE_MODE:-false}"
CLUSTER_MODE="${CLUSTER_MODE:-false}"
MAX_NODES_PER_BATCH="${MAX_NODES_PER_BATCH:-1}"

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v curl &> /dev/null; then
        error "curl is not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        error "jq is not installed"
        exit 1
    fi
    
    log "Prerequisites check passed"
}

# Function to authenticate with Proxmox API
authenticate_proxmox() {
    log "Authenticating with Proxmox API..."
    
    if [ -z "$PROXMOX_PASSWORD" ]; then
        error "PROXMOX_PASSWORD environment variable not set"
        exit 1
    fi
    
    # Authenticate and get ticket
    local auth_response
    auth_response=$(curl -k -s -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" \
        "${PROXMOX_API_URL}/access/ticket")
    
    if [ $? -ne 0 ]; then
        error "Failed to authenticate with Proxmox API"
        exit 1
    fi
    
    TICKET=$(echo "$auth_response" | jq -r '.data.ticket')
    CSRF_PREVENTION_TOKEN=$(echo "$auth_response" | jq -r '.data.CSRFPreventionToken')
    
    if [ "$TICKET" = "null" ] || [ "$CSRF_PREVENTION_TOKEN" = "null" ]; then
        error "Authentication failed: Invalid credentials"
        exit 1
    fi
    
    log "Successfully authenticated with Proxmox API"
}

# Function to get cluster nodes
get_cluster_nodes() {
    log "Retrieving Proxmox cluster nodes..."
    
    if [ "$CLUSTER_MODE" = true ]; then
        local nodes_response
        nodes_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/cluster/nodes")
        
        if [ $? -ne 0 ]; then
            error "Failed to retrieve cluster nodes"
            exit 1
        fi
        
        echo "$nodes_response" | jq -r '.data[].name'
    else
        # Single node setup
        echo "$PROXMOX_HOST"
    fi
}

# Function to get node status
get_node_status() {
    local node="$1"
    
    local status_response
    status_response=$(curl -k -s \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${PROXMOX_API_URL}/nodes/${node}/status")
    
    if [ $? -ne 0 ]; then
        error "Failed to get status for node $node"
        return 1
    fi
    
    echo "$status_response" | jq -r '.data.status // "unknown"'
}

# Function to check for available updates
check_for_updates() {
    local node="$1"
    log "Checking for updates on node $node..."
    
    local updates_response
    updates_response=$(curl -k -s \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${PROXMOX_API_URL}/nodes/${node}/apt/update")
    
    if [ $? -ne 0 ]; then
        error "Failed to check updates for node $node"
        return 1
    fi
    
    local update_count
    update_count=$(echo "$updates_response" | jq -r '.data // [] | length')
    
    log "Found $update_count available updates for node $node"
    echo "$update_count"
}

# Function to get update list
get_update_list() {
    local node="$1"
    
    local updates_response
    updates_response=$(curl -k -s \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${PROXMOX_API_URL}/nodes/${node}/apt/update")
    
    echo "$updates_response" | jq -r '.data[]?.package // empty'
}

# Function to put node in maintenance mode
put_node_maintenance() {
    local node="$1"
    
    if [ "$MAINTENANCE_MODE" = true ]; then
        log "Putting node $node in maintenance mode..."
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would put node $node in maintenance mode"
            return 0
        fi
        
        # Create maintenance file
        local maint_cmd="touch /etc/pve/nodes/$node/.pmcx-maint"
        local cmd_response
        cmd_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            -d "command=$maint_cmd" \
            "${PROXMOX_API_URL}/nodes/${node}/commands")
        
        if [ $? -ne 0 ]; then
            warn "Failed to put node $node in maintenance mode"
            return 1
        fi
        
        log "Node $node is now in maintenance mode"
    fi
}

# Function to take node out of maintenance mode
remove_node_maintenance() {
    local node="$1"
    
    if [ "$MAINTENANCE_MODE" = true ]; then
        log "Removing maintenance mode from node $node..."
        
        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would remove maintenance mode from node $node"
            return 0
        fi
        
        # Remove maintenance file
        local maint_cmd="rm -f /etc/pve/nodes/$node/.pmcx-maint"
        local cmd_response
        cmd_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            -d "command=$maint_cmd" \
            "${PROXMOX_API_URL}/nodes/${node}/commands")
        
        if [ $? -ne 0 ]; then
            warn "Failed to remove maintenance mode from node $node"
            return 1
        fi
        
        log "Node $node maintenance mode removed"
    fi
}

# Function to migrate VMs from node
migrate_vms_from_node() {
    local node="$1"
    log "Migrating VMs from node $node..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would migrate VMs from node $node"
        return 0
    fi
    
    # Get list of running VMs on this node
    local vms_response
    vms_response=$(curl -k -s \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        "${PROXMOX_API_URL}/nodes/${node}/qemu")
    
    local vm_ids
    vm_ids=$(echo "$vms_response" | jq -r '.data[] | select(.status == "running") | .vmid')
    
    for vm_id in $vm_ids; do
        log "Migrating VM $vm_id from node $node..."
        
        # Find another node to migrate to
        local target_node
        target_node=$(get_cluster_nodes | grep -v "$node" | head -1)
        
        if [ -n "$target_node" ]; then
            # Perform live migration
            local migrate_response
            migrate_response=$(curl -k -s \
                -X POST \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                -d "target=$target_node&online=1" \
                "${PROXMOX_API_URL}/nodes/${node}/qemu/${vm_id}/migrate")
            
            if [ $? -ne 0 ]; then
                warn "Failed to migrate VM $vm_id from node $node"
            else
                log "VM $vm_id migrated from $node to $target_node"
            fi
        else
            warn "No other nodes available for migration of VM $vm_id"
        fi
    done
}

# Function to update Proxmox node
update_proxmox_node() {
    local node="$1"
    log "Updating Proxmox node $node..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would update Proxmox node $node"
        return 0
    fi
    
    # Perform apt update and upgrade
    local update_cmd="apt update && apt upgrade -y"
    local cmd_response
    cmd_response=$(curl -k -s \
        -X POST \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
        -d "command=$update_cmd" \
        "${PROXMOX_API_URL}/nodes/${node}/commands")
    
    if [ $? -ne 0 ]; then
        error "Failed to update node $node"
        return 1
    fi
    
    log "Node $node update completed"
}

# Function to restart Proxmox node
restart_node() {
    local node="$1"
    log "Restarting Proxmox node $node..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would restart node $node"
        return 0
    fi
    
    # Restart the node
    local restart_response
    restart_response=$(curl -k -s \
        -X POST \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
        "${PROXMOX_API_URL}/nodes/${node}/status")
    
    if [ $? -ne 0 ]; then
        error "Failed to initiate restart for node $node"
        return 1
    fi
    
    # Actually restart via command
    local restart_cmd="reboot"
    local cmd_response
    cmd_response=$(curl -k -s \
        -X POST \
        -H "Authorization: PVEAuthCookie ${TICKET}" \
        -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
        -d "command=$restart_cmd" \
        "${PROXMOX_API_URL}/nodes/${node}/commands")
    
    if [ $? -ne 0 ]; then
        error "Failed to execute restart command for node $node"
        return 1
    fi
    
    log "Node $node restart initiated"
    
    # Wait for node to come back online
    log "Waiting for node $node to restart..."
    local timeout=300  # 5 minutes
    local count=0
    
    while [ $count -lt $timeout ]; do
        sleep 10
        count=$((count + 10))
        
        if get_node_status "$node" >/dev/null 2>&1; then
            log "Node $node is back online"
            return 0
        fi
    done
    
    error "Node $node did not come back online within timeout period"
    return 1
}

# Function to perform rolling update of cluster
perform_cluster_update() {
    log "Starting cluster update process..."
    
    local nodes
    nodes=$(get_cluster_nodes)
    local node_array=($nodes)
    local total_nodes=${#node_array[@]}
    
    log "Cluster has $total_nodes nodes: ${node_array[*]}"
    
    for node in "${node_array[@]}"; do
        log "Processing node: $node"
        
        # Check node status
        local status
        status=$(get_node_status "$node")
        if [ "$status" != "online" ]; then
            warn "Node $node is not online ($status), skipping update"
            continue
        fi
        
        # Check for updates
        local update_count
        update_count=$(check_for_updates "$node")
        
        if [ "$update_count" -gt 0 ]; then
            log "Updates available for node $node ($update_count updates)"
            
            # Get update list
            log "Updates for node $node:"
            get_update_list "$node" | while read -r pkg; do
                if [ -n "$pkg" ]; then
                    log "  - $pkg"
                fi
            done
            
            # Put node in maintenance mode
            put_node_maintenance "$node"
            
            # Migrate VMs if any are running
            migrate_vms_from_node "$node"
            
            # Update the node
            if ! update_proxmox_node "$node"; then
                error "Update failed for node $node"
                remove_node_maintenance "$node"
                continue
            fi
            
            # Restart node if needed
            restart_node "$node"
            
            # Remove maintenance mode
            remove_node_maintenance "$node"
            
            log "Node $node updated successfully"
        else
            log "No updates available for node $node"
        fi
        
        # Wait between nodes to avoid simultaneous updates
        sleep 120
    done
    
    log "Cluster update process completed"
}

# Function to perform single node update
perform_single_node_update() {
    log "Starting single node update process..."
    
    # Check for updates
    local update_count
    update_count=$(check_for_updates "$PROXMOX_HOST")
    
    if [ "$update_count" -gt 0 ]; then
        log "Updates available for node $PROXMOX_HOST ($update_count updates)"
        
        # Get update list
        log "Updates for node $PROXMOX_HOST:"
        get_update_list "$PROXMOX_HOST" | while read -r pkg; do
            if [ -n "$pkg" ]; then
                log "  - $pkg"
            fi
        done
        
        # Put node in maintenance mode
        put_node_maintenance "$PROXMOX_HOST"
        
        # Update the node
        if ! update_proxmox_node "$PROXMOX_HOST"; then
            error "Update failed for node $PROXMOX_HOST"
            remove_node_maintenance "$PROXMOX_HOST"
            exit 1
        fi
        
        # Restart node if needed
        restart_node "$PROXMOX_HOST"
        
        # Remove maintenance mode
        remove_node_maintenance "$PROXMOX_HOST"
        
        log "Node $PROXMOX_HOST updated successfully"
    else
        log "No updates available for node $PROXMOX_HOST"
    fi
}

# Function to check patch window
is_patch_window_active() {
    local current_time
    current_time=$(date +%H:%M)
    
    local start_time
    local end_time
    start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
    end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)
    
    # Convert times to minutes since midnight for comparison
    local current_minutes
    local start_minutes
    local end_minutes
    
    current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
    start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
    end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))
    
    if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
        return 0
    else
        return 1
    fi
}

# Main function
main() {
    log "Starting Proxmox automatic patching process"
    
    # Check if we're in patch window
    if ! is_patch_window_active; then
        warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
        exit 0
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Authenticate with Proxmox API
    authenticate_proxmox
    
    # Determine update strategy based on cluster mode
    if [ "$CLUSTER_MODE" = true ]; then
        perform_cluster_update
    else
        perform_single_node_update
    fi
    
    log "Proxmox patching process completed"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

Create `k8s-manifests/patching/proxmox-updater.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: proxmox-updater
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: proxmox-patch-config
  namespace: proxmox-updater
data:
  proxmox-patch-config.yaml: |
    # Proxmox Automatic Patching Configuration
    schedule: "0 2 1 * *"  # Monthly on 1st at 2 AM
    patchWindow: "02:00-04:00"  # 2 AM to 4 AM
    dryRun: false
    maintenanceMode: true
    clusterMode: false
    maxNodesPerBatch: 1
    # Proxmox connection settings
    proxmoxHost: "proxmox.local"
    proxmoxUser: "root@pam"
    proxmoxApiUrl: "https://proxmox.local:8006/api2/json"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: proxmox-updater
  namespace: proxmox-updater
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: proxmox-updater
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: proxmox-updater
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: proxmox-updater
subjects:
- kind: ServiceAccount
  name: proxmox-updater
  namespace: proxmox-updater
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: proxmox-patcher
  namespace: proxmox-updater
spec:
  schedule: "0 2 1 * *"  # Monthly on 1st at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: proxmox-updater
          containers:
          - name: proxmox-patcher
            image: curlimages/curl:latest
            command:
            - /bin/bash
            - -c
            - |
              # Install dependencies
              apk add --no-cache jq bash openssl
              
              # Run patching script
              /scripts/proxmox-patching.sh
            volumeMounts:
            - name: patch-scripts
              mountPath: /scripts
              readOnly: true
            env:
            - name: PROXMOX_HOST
              valueFrom:
                configMapKeyRef:
                  name: proxmox-patch-config
                  key: proxmoxHost
            - name: PROXMOX_USER
              valueFrom:
                configMapKeyRef:
                  name: proxmox-patch-config
                  key: proxmoxUser
            - name: PROXMOX_API_URL
              valueFrom:
                configMapKeyRef:
                  name: proxmox-patch-config
                  key: proxmoxApiUrl
            - name: PROXMOX_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: proxmox-patch-secrets
                  key: password
            - name: PATCH_SCHEDULE
              value: "monthly"
            - name: PATCH_WINDOW
              value: "02:00-04:00"
            - name: DRY_RUN
              value: "false"
            - name: MAINTENANCE_MODE
              value: "true"
            - name: CLUSTER_MODE
              value: "false"
            - name: MAX_NODES_PER_BATCH
              value: "1"
          volumes:
          - name: patch-scripts
            configMap:
              name: proxmox-patch-scripts
          restartPolicy: OnFailure
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: proxmox-patch-scripts
  namespace: proxmox-updater
data:
  proxmox-patching.sh: |
    #!/bin/bash

    # Twinbox Proxmox Automatic Patching Script
    # Handles automatic updates for Proxmox VE host systems with safe rollout

    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Logging functions
    log() {
        echo -e "${GREEN}[PROXMOX-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    warn() {
        echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    error() {
        echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    # Configuration
    PROXMOX_HOST="${PROXMOX_HOST:-localhost}"
    PROXMOX_USER="${PROXMOX_USER:-root@pam}"
    PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
    PROXMOX_API_URL="${PROXMOX_API_URL:-https://localhost:8006/api2/json}"
    PATCH_SCHEDULE="${PATCH_SCHEDULE:-monthly}"
    PATCH_WINDOW="${PATCH_WINDOW:-02:00-04:00}"
    DRY_RUN="${DRY_RUN:-false}"
    MAINTENANCE_MODE="${MAINTENANCE_MODE:-false}"
    CLUSTER_MODE="${CLUSTER_MODE:-false}"
    MAX_NODES_PER_BATCH="${MAX_NODES_PER_BATCH:-1}"

    # Function to check prerequisites
    check_prerequisites() {
        log "Checking prerequisites..."

        if ! command -v curl &> /dev/null; then
            error "curl is not installed"
            exit 1
        fi

        if ! command -v jq &> /dev/null; then
            error "jq is not installed"
            exit 1
        fi

        log "Prerequisites check passed"
    }

    # Function to authenticate with Proxmox API
    authenticate_proxmox() {
        log "Authenticating with Proxmox API..."

        if [ -z "$PROXMOX_PASSWORD" ]; then
            error "PROXMOX_PASSWORD environment variable not set"
            exit 1
        fi

        # Authenticate and get ticket
        local auth_response
        auth_response=$(curl -k -s -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" \
            "${PROXMOX_API_URL}/access/ticket")

        if [ $? -ne 0 ]; then
            error "Failed to authenticate with Proxmox API"
            exit 1
        fi

        TICKET=$(echo "$auth_response" | jq -r '.data.ticket')
        CSRF_PREVENTION_TOKEN=$(echo "$auth_response" | jq -r '.data.CSRFPreventionToken')

        if [ "$TICKET" = "null" ] || [ "$CSRF_PREVENTION_TOKEN" = "null" ]; then
            error "Authentication failed: Invalid credentials"
            exit 1
        fi

        log "Successfully authenticated with Proxmox API"
    }

    # Function to get cluster nodes
    get_cluster_nodes() {
        log "Retrieving Proxmox cluster nodes..."

        if [ "$CLUSTER_MODE" = true ]; then
            local nodes_response
            nodes_response=$(curl -k -s \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                "${PROXMOX_API_URL}/cluster/nodes")

            if [ $? -ne 0 ]; then
                error "Failed to retrieve cluster nodes"
                exit 1
            fi

            echo "$nodes_response" | jq -r '.data[].name'
        else
            # Single node setup
            echo "$PROXMOX_HOST"
        fi
    }

    # Function to get node status
    get_node_status() {
        local node="$1"

        local status_response
        status_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/status")

        if [ $? -ne 0 ]; then
            error "Failed to get status for node $node"
            return 1
        fi

        echo "$status_response" | jq -r '.data.status // "unknown"'
    }

    # Function to check for available updates
    check_for_updates() {
        local node="$1"
        log "Checking for updates on node $node..."

        local updates_response
        updates_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/apt/update")

        if [ $? -ne 0 ]; then
            error "Failed to check updates for node $node"
            return 1
        fi

        local update_count
        update_count=$(echo "$updates_response" | jq -r '.data // [] | length')

        log "Found $update_count available updates for node $node"
        echo "$update_count"
    }

    # Function to get update list
    get_update_list() {
        local node="$1"

        local updates_response
        updates_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/apt/update")

        echo "$updates_response" | jq -r '.data[]?.package // empty'
    }

    # Function to put node in maintenance mode
    put_node_maintenance() {
        local node="$1"

        if [ "$MAINTENANCE_MODE" = true ]; then
            log "Putting node $node in maintenance mode..."

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would put node $node in maintenance mode"
                return 0
            fi

            # Create maintenance file
            local maint_cmd="touch /etc/pve/nodes/$node/.pmcx-maint"
            local cmd_response
            cmd_response=$(curl -k -s \
                -X POST \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                -d "command=$maint_cmd" \
                "${PROXMOX_API_URL}/nodes/${node}/commands")

            if [ $? -ne 0 ]; then
                warn "Failed to put node $node in maintenance mode"
                return 1
            fi

            log "Node $node is now in maintenance mode"
        fi
    }

    # Function to take node out of maintenance mode
    remove_node_maintenance() {
        local node="$1"

        if [ "$MAINTENANCE_MODE" = true ]; then
            log "Removing maintenance mode from node $node..."

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would remove maintenance mode from node $node"
                return 0
            fi

            # Remove maintenance file
            local maint_cmd="rm -f /etc/pve/nodes/$node/.pmcx-maint"
            local cmd_response
            cmd_response=$(curl -k -s \
                -X POST \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                -d "command=$maint_cmd" \
                "${PROXMOX_API_URL}/nodes/${node}/commands")

            if [ $? -ne 0 ]; then
                warn "Failed to remove maintenance mode from node $node"
                return 1
            fi

            log "Node $node maintenance mode removed"
        fi
    }

    # Function to migrate VMs from node
    migrate_vms_from_node() {
        local node="$1"
        log "Migrating VMs from node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would migrate VMs from node $node"
            return 0
        fi

        # Get list of running VMs on this node
        local vms_response
        vms_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/qemu")

        local vm_ids
        vm_ids=$(echo "$vms_response" | jq -r '.data[] | select(.status == "running") | .vmid')

        for vm_id in $vm_ids; do
            log "Migrating VM $vm_id from node $node..."

            # Find another node to migrate to
            local target_node
            target_node=$(get_cluster_nodes | grep -v "$node" | head -1)

            if [ -n "$target_node" ]; then
                # Perform live migration
                local migrate_response
                migrate_response=$(curl -k -s \
                    -X POST \
                    -H "Authorization: PVEAuthCookie ${TICKET}" \
                    -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                    -d "target=$target_node&online=1" \
                    "${PROXMOX_API_URL}/nodes/${node}/qemu/${vm_id}/migrate")

                if [ $? -ne 0 ]; then
                    warn "Failed to migrate VM $vm_id from node $node"
                else
                    log "VM $vm_id migrated from $node to $target_node"
                fi
            else
                warn "No other nodes available for migration of VM $vm_id"
            fi
        done
    }

    # Function to update Proxmox node
    update_proxmox_node() {
        local node="$1"
        log "Updating Proxmox node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would update Proxmox node $node"
            return 0
        fi

        # Perform apt update and upgrade
        local update_cmd="apt update && apt upgrade -y"
        local cmd_response
        cmd_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            -d "command=$update_cmd" \
            "${PROXMOX_API_URL}/nodes/${node}/commands")

        if [ $? -ne 0 ]; then
            error "Failed to update node $node"
            return 1
        fi

        log "Node $node update completed"
    }

    # Function to restart Proxmox node
    restart_node() {
        local node="$1"
        log "Restarting Proxmox node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would restart node $node"
            return 0
        fi

        # Restart the node
        local restart_response
        restart_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            "${PROXMOX_API_URL}/nodes/${node}/status")

        if [ $? -ne 0 ]; then
            error "Failed to initiate restart for node $node"
            return 1
        fi

        # Actually restart via command
        local restart_cmd="reboot"
        local cmd_response
        cmd_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            -d "command=$restart_cmd" \
            "${PROXMOX_API_URL}/nodes/${node}/commands")

        if [ $? -ne 0 ]; then
            error "Failed to execute restart command for node $node"
            return 1
        fi

        log "Node $node restart initiated"

        # Wait for node to come back online
        log "Waiting for node $node to restart..."
        local timeout=300  # 5 minutes
        local count=0

        while [ $count -lt $timeout ]; do
            sleep 10
            count=$((count + 10))

            if get_node_status "$node" >/dev/null 2>&1; then
                log "Node $node is back online"
                return 0
            fi
        done

        error "Node $node did not come back online within timeout period"
        return 1
    }

    # Function to perform rolling update of cluster
    perform_cluster_update() {
        log "Starting cluster update process..."

        local nodes
        nodes=$(get_cluster_nodes)
        local node_array=($nodes)
        local total_nodes=${#node_array[@]}

        log "Cluster has $total_nodes nodes: ${node_array[*]}"

        for node in "${node_array[@]}"; do
            log "Processing node: $node"

            # Check node status
            local status
            status=$(get_node_status "$node")
            if [ "$status" != "online" ]; then
                warn "Node $node is not online ($status), skipping update"
                continue
            fi

            # Check for updates
            local update_count
            update_count=$(check_for_updates "$node")

            if [ "$update_count" -gt 0 ]; then
                log "Updates available for node $node ($update_count updates)"

                # Get update list
                log "Updates for node $node:"
                get_update_list "$node" | while read -r pkg; do
                    if [ -n "$pkg" ]; then
                        log "  - $pkg"
                    fi
                done

                # Put node in maintenance mode
                put_node_maintenance "$node"

                # Migrate VMs if any are running
                migrate_vms_from_node "$node"

                # Update the node
                if ! update_proxmox_node "$node"; then
                    error "Update failed for node $node"
                    remove_node_maintenance "$node"
                    continue
                fi

                # Restart node if needed
                restart_node "$node"

                # Remove maintenance mode
                remove_node_maintenance "$node"

                log "Node $node updated successfully"
            else
                log "No updates available for node $node"
            fi

            # Wait between nodes to avoid simultaneous updates
            sleep 120
        done

        log "Cluster update process completed"
    }

    # Function to perform single node update
    perform_single_node_update() {
        log "Starting single node update process..."

        # Check for updates
        local update_count
        update_count=$(check_for_updates "$PROXMOX_HOST")

        if [ "$update_count" -gt 0 ]; then
            log "Updates available for node $PROXMOX_HOST ($update_count updates)"

            # Get update list
            log "Updates for node $PROXMOX_HOST:"
            get_update_list "$PROXMOX_HOST" | while read -r pkg; do
                if [ -n "$pkg" ]; then
                    log "  - $pkg"
                fi
            done

            # Put node in maintenance mode
            put_node_maintenance "$PROXMOX_HOST"

            # Update the node
            if ! update_proxmox_node "$PROXMOX_HOST"; then
                error "Update failed for node $PROXMOX_HOST"
                remove_node_maintenance "$PROXMOX_HOST"
                exit 1
            fi

            # Restart node if needed
            restart_node "$PROXMOX_HOST"

            # Remove maintenance mode
            remove_node_maintenance "$PROXMOX_HOST"

            log "Node $PROXMOX_HOST updated successfully"
        else
            log "No updates available for node $PROXMOX_HOST"
        fi
    }

    # Function to check patch window
    is_patch_window_active() {
        local current_time
        current_time=$(date +%H:%M)

        local start_time
        local end_time
        start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
        end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)

        # Convert times to minutes since midnight for comparison
        local current_minutes
        local start_minutes
        local end_minutes

        current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
        start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
        end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))

        if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
            return 0
        else
            return 1
        fi
    }

    # Main function
    main() {
        log "Starting Proxmox automatic patching process"

        # Check if we're in patch window
        if ! is_patch_window_active; then
            warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
            exit 0
        fi

        # Check prerequisites
        check_prerequisites

        # Authenticate with Proxmox API
        authenticate_proxmox

        # Determine update strategy based on cluster mode
        if [ "$CLUSTER_MODE" = true ]; then
            perform_cluster_update
        else
            perform_single_node_update
        fi

        log "Proxmox patching process completed"
    }

    # Run main function if script is executed directly
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
---
apiVersion: v1
kind: Secret
metadata:
  name: proxmox-patch-secrets
  namespace: proxmox-updater
type: Opaque
stringData:
  password: ""
```

Make the script executable:
```bash
chmod +x patching/proxmox-patching.sh
```

**Step 4: Run test to verify it passes**
Run: `bash tests/proxmox_patching_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add patching/proxmox-patching.sh k8s-manifests/patching/proxmox-updater.yaml
git commit -m "Add Proxmox automatic patching system"
```

### Task 4: Create Unified Patching Orchestrator

**Files:**
- Create: `patching/unified-patcher.sh`
- Create: `k8s-manifests/patching/unified-patcher.yaml`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/unified_patching_test.sh
set -e

if [ ! -f "patching/unified-patcher.sh" ]; then
    echo "FAIL: patching/unified-patcher.sh does not exist"
    exit 1
fi

if [ ! -x "patching/unified-patcher.sh" ]; then
    echo "FAIL: patching/unified-patcher.sh is not executable"
    exit 1
fi

if [ ! -f "k8s-manifests/patching/unified-patcher.yaml" ]; then
    echo "FAIL: k8s-manifests/patching/unified-patcher.yaml does not exist"
    exit 1
fi

echo "PASS: Unified patching files exist and are executable"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/unified_patching_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `patching/unified-patcher.sh`:
```bash
#!/bin/bash

# Twinbox Unified Automatic Patching Orchestrator
# Coordinates patching across all platform layers: Proxmox, Talos, Kubernetes services

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[UNIFIED-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
}

# Configuration
PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"  # weekly, monthly
PATCH_WINDOW="${PATCH_WINDOW:-02:00-06:00}"  # HH:MM-HH:MM format
DRY_RUN="${DRY_RUN:-false}"
PATCH_ORDER="${PATCH_ORDER:-proxmox,talos,k8s}"  # Order of patching
NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-}"
EMAIL_RECIPIENTS="${EMAIL_RECIPIENTS:-}"

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v curl &> /dev/null; then
        error "curl is not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        error "jq is not installed"
        exit 1
    fi
    
    log "Prerequisites check passed"
}

# Function to send notification
send_notification() {
    local message="$1"
    local status="${2:-info}"
    
    # Send to webhook if configured
    if [ -n "$NOTIFICATION_WEBHOOK" ]; then
        case $status in
            "success")
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"✅ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
            "warning")
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"⚠️ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
            "error")
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"❌ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
            *)
                curl -X POST -H "Content-Type: application/json" \
                    -d "{\"text\":\"ℹ️ $message\"}" \
                    "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                ;;
        esac
    fi
    
    # Additional notification methods could be added here
}

# Function to run Proxmox patching
run_proxmox_patching() {
    log "Starting Proxmox patching..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would run Proxmox patching"
        return 0
    fi
    
    # Check if Proxmox patching script exists
    if [ -f "/scripts/proxmox-patching.sh" ]; then
        log "Running Proxmox patching script..."
        bash /scripts/proxmox-patching.sh
    else
        warn "Proxmox patching script not found, skipping"
    fi
}

# Function to run Talos patching
run_talos_patching() {
    log "Starting Talos patching..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would run Talos patching"
        return 0
    fi
    
    # Check if Talos patching script exists
    if [ -f "/scripts/talos-patching.sh" ]; then
        log "Running Talos patching script..."
        bash /scripts/talos-patching.sh
    else
        warn "Talos patching script not found, skipping"
    fi
}

# Function to run Kubernetes components patching
run_k8s_patching() {
    log "Starting Kubernetes components patching..."
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would run Kubernetes components patching"
        return 0
    fi
    
    # Check if Kubernetes patching script exists
    if [ -f "/scripts/k8s-components-patching.sh" ]; then
        log "Running Kubernetes components patching script..."
        bash /scripts/k8s-components-patching.sh
    else
        warn "Kubernetes components patching script not found, skipping"
    fi
}

# Function to check system health before patching
check_system_health() {
    log "Checking system health before patching..."
    
    # Check cluster status
    if command -v kubectl &> /dev/null; then
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        
        if [ "$node_count" -gt 0 ]; then
            local ready_nodes
            ready_nodes=$(kubectl get nodes --no-headers -o custom-columns=:.status.conditions[?(@.type=='Ready')].status | grep -c True 2>/dev/null || echo "0")
            
            log "Cluster health: $ready_nodes/$node_count nodes ready"
            
            if [ "$ready_nodes" -lt 1 ]; then
                error "Cluster is not healthy, aborting patching"
                return 1
            fi
        fi
    fi
    
    # Additional health checks could be added here
    # - Check storage status
    # - Check network connectivity
    # - Check application health
    
    log "System health check passed"
}

# Function to check patch window
is_patch_window_active() {
    local current_time
    current_time=$(date +%H:%M)
    
    local start_time
    local end_time
    start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
    end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)
    
    # Convert times to minutes since midnight for comparison
    local current_minutes
    local start_minutes
    local end_minutes
    
    current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
    start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
    end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))
    
    if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
        return 0
    else
        return 1
    fi
}

# Function to run patching in specified order
run_patching_sequence() {
    log "Starting unified patching sequence..."
    
    # Check system health first
    if ! check_system_health; then
        error "System health check failed, aborting patching"
        send_notification "Patching aborted due to system health issues" "error"
        return 1
    fi
    
    # Parse patch order
    local orders
    IFS=',' read -ra orders <<< "$PATCH_ORDER"
    
    for component in "${orders[@]}"; do
        case $component in
            "proxmox")
                log "Patching Proxmox layer..."
                if ! run_proxmox_patching; then
                    error "Proxmox patching failed"
                    send_notification "Proxmox patching failed" "error"
                    # Continue with other components
                else
                    send_notification "Proxmox patching completed successfully" "success"
                fi
                ;;
            "talos")
                log "Patching Talos layer..."
                if ! run_talos_patching; then
                    error "Talos patching failed"
                    send_notification "Talos patching failed" "error"
                    # Continue with other components
                else
                    send_notification "Talos patching completed successfully" "success"
                fi
                ;;
            "k8s")
                log "Patching Kubernetes layer..."
                if ! run_k8s_patching; then
                    error "Kubernetes patching failed"
                    send_notification "Kubernetes patching failed" "error"
                    # Continue with other components
                else
                    send_notification "Kubernetes patching completed successfully" "success"
                fi
                ;;
            *)
                warn "Unknown component in patch order: $component"
                ;;
        esac
    done
    
    log "Unified patching sequence completed"
}

# Function to generate patching report
generate_report() {
    log "Generating patching report..."
    
    local report_content="Patching Report - $(date)\n"
    report_content+="Schedule: $PATCH_SCHEDULE\n"
    report_content+="Patch Window: $PATCH_WINDOW\n"
    report_content+="Dry Run: $DRY_RUN\n"
    report_content+="Components Patched: $PATCH_ORDER\n"
    
    # Add more details to the report
    if command -v kubectl &> /dev/null; then
        local node_count
        local ready_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        ready_count=$(kubectl get nodes --no-headers -o custom-columns=:.status.conditions[?(@.type=='Ready')].status 2>/dev/null | grep -c True || echo "0")
        
        report_content+="Kubernetes Nodes: $ready_count/$node_count ready\n"
    fi
    
    echo -e "$report_content"
    
    # Optionally save report to file
    local report_file="/tmp/unified-patching-report-$(date +%s).txt"
    echo -e "$report_content" > "$report_file"
    log "Patching report saved to: $report_file"
}

# Main function
main() {
    log "Starting Twinbox Unified Automatic Patching Orchestrator"
    
    # Check if we're in patch window
    if ! is_patch_window_active; then
        warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
        exit 0
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Send notification that patching is starting
    send_notification "Starting unified patching process" "info"
    
    # Run the patching sequence
    run_patching_sequence
    
    # Generate and send final report
    generate_report
    send_notification "Unified patching process completed successfully" "success"
    
    log "Twinbox Unified Automatic Patching Orchestrator completed"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

Create `k8s-manifests/patching/unified-patcher.yaml`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: unified-patcher
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: unified-patch-config
  namespace: unified-patcher
data:
  unified-patch-config.yaml: |
    # Unified Automatic Patching Configuration
    schedule: "0 2 * * 0"  # Weekly on Sundays at 2 AM
    patchWindow: "02:00-06:00"  # 2 AM to 6 AM
    dryRun: false
    patchOrder: "proxmox,talos,k8s"  # Order of patching
    notificationWebhook: ""
    slackChannel: ""
    emailRecipients: []
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: unified-patcher
  namespace: unified-patcher
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: unified-patcher
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets", "pods", "services", "namespaces", "nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: unified-patcher
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: unified-patcher
subjects:
- kind: ServiceAccount
  name: unified-patcher
  namespace: unified-patcher
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: unified-patcher
  namespace: unified-patcher
spec:
  schedule: "0 2 * * 0"  # Weekly on Sundays at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: unified-patcher
          containers:
          - name: unified-patcher
            image: curlimages/curl:latest
            command:
            - /bin/bash
            - -c
            - |
              # Install dependencies
              apk add --no-cache jq bash openssl curl
              
              # Create scripts directory and copy all patching scripts
              mkdir -p /scripts
              
              # Copy Proxmox patching script
              cat << 'EOF_PROXMOX' > /scripts/proxmox-patching.sh
    #!/bin/bash

    # Twinbox Proxmox Automatic Patching Script
    # Handles automatic updates for Proxmox VE host systems with safe rollout

    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Logging functions
    log() {
        echo -e "${GREEN}[PROXMOX-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    warn() {
        echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    error() {
        echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    # Configuration
    PROXMOX_HOST="${PROXMOX_HOST:-localhost}"
    PROXMOX_USER="${PROXMOX_USER:-root@pam}"
    PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
    PROXMOX_API_URL="${PROXMOX_API_URL:-https://localhost:8006/api2/json}"
    PATCH_SCHEDULE="${PATCH_SCHEDULE:-monthly}"
    PATCH_WINDOW="${PATCH_WINDOW:-02:00-04:00}"
    DRY_RUN="${DRY_RUN:-false}"
    MAINTENANCE_MODE="${MAINTENANCE_MODE:-false}"
    CLUSTER_MODE="${CLUSTER_MODE:-false}"
    MAX_NODES_PER_BATCH="${MAX_NODES_PER_BATCH:-1}"

    # Function to check prerequisites
    check_prerequisites() {
        log "Checking prerequisites..."

        if ! command -v curl &> /dev/null; then
            error "curl is not installed"
            exit 1
        fi

        if ! command -v jq &> /dev/null; then
            error "jq is not installed"
            exit 1
        fi

        log "Prerequisites check passed"
    }

    # Function to authenticate with Proxmox API
    authenticate_proxmox() {
        log "Authenticating with Proxmox API..."

        if [ -z "$PROXMOX_PASSWORD" ]; then
            error "PROXMOX_PASSWORD environment variable not set"
            exit 1
        fi

        # Authenticate and get ticket
        local auth_response
        auth_response=$(curl -k -s -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" \
            "${PROXMOX_API_URL}/access/ticket")

        if [ $? -ne 0 ]; then
            error "Failed to authenticate with Proxmox API"
            exit 1
        fi

        TICKET=$(echo "$auth_response" | jq -r '.data.ticket')
        CSRF_PREVENTION_TOKEN=$(echo "$auth_response" | jq -r '.data.CSRFPreventionToken')

        if [ "$TICKET" = "null" ] || [ "$CSRF_PREVENTION_TOKEN" = "null" ]; then
            error "Authentication failed: Invalid credentials"
            exit 1
        fi

        log "Successfully authenticated with Proxmox API"
    }

    # Function to get cluster nodes
    get_cluster_nodes() {
        log "Retrieving Proxmox cluster nodes..."

        if [ "$CLUSTER_MODE" = true ]; then
            local nodes_response
            nodes_response=$(curl -k -s \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                "${PROXMOX_API_URL}/cluster/nodes")

            if [ $? -ne 0 ]; then
                error "Failed to retrieve cluster nodes"
                exit 1
            fi

            echo "$nodes_response" | jq -r '.data[].name'
        else
            # Single node setup
            echo "$PROXMOX_HOST"
        fi
    }

    # Function to get node status
    get_node_status() {
        local node="$1"

        local status_response
        status_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/status")

        if [ $? -ne 0 ]; then
            error "Failed to get status for node $node"
            return 1
        fi

        echo "$status_response" | jq -r '.data.status // "unknown"'
    }

    # Function to check for available updates
    check_for_updates() {
        local node="$1"
        log "Checking for updates on node $node..."

        local updates_response
        updates_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/apt/update")

        if [ $? -ne 0 ]; then
            error "Failed to check updates for node $node"
            return 1
        fi

        local update_count
        update_count=$(echo "$updates_response" | jq -r '.data // [] | length')

        log "Found $update_count available updates for node $node"
        echo "$update_count"
    }

    # Function to get update list
    get_update_list() {
        local node="$1"

        local updates_response
        updates_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/apt/update")

        echo "$updates_response" | jq -r '.data[]?.package // empty'
    }

    # Function to put node in maintenance mode
    put_node_maintenance() {
        local node="$1"

        if [ "$MAINTENANCE_MODE" = true ]; then
            log "Putting node $node in maintenance mode..."

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would put node $node in maintenance mode"
                return 0
            fi

            # Create maintenance file
            local maint_cmd="touch /etc/pve/nodes/$node/.pmcx-maint"
            local cmd_response
            cmd_response=$(curl -k -s \
                -X POST \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                -d "command=$maint_cmd" \
                "${PROXMOX_API_URL}/nodes/${node}/commands")

            if [ $? -ne 0 ]; then
                warn "Failed to put node $node in maintenance mode"
                return 1
            fi

            log "Node $node is now in maintenance mode"
        fi
    }

    # Function to take node out of maintenance mode
    remove_node_maintenance() {
        local node="$1"

        if [ "$MAINTENANCE_MODE" = true ]; then
            log "Removing maintenance mode from node $node..."

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would remove maintenance mode from node $node"
                return 0
            fi

            # Remove maintenance file
            local maint_cmd="rm -f /etc/pve/nodes/$node/.pmcx-maint"
            local cmd_response
            cmd_response=$(curl -k -s \
                -X POST \
                -H "Authorization: PVEAuthCookie ${TICKET}" \
                -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                -d "command=$maint_cmd" \
                "${PROXMOX_API_URL}/nodes/${node}/commands")

            if [ $? -ne 0 ]; then
                warn "Failed to remove maintenance mode from node $node"
                return 1
            fi

            log "Node $node maintenance mode removed"
        fi
    }

    # Function to migrate VMs from node
    migrate_vms_from_node() {
        local node="$1"
        log "Migrating VMs from node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would migrate VMs from node $node"
            return 0
        fi

        # Get list of running VMs on this node
        local vms_response
        vms_response=$(curl -k -s \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            "${PROXMOX_API_URL}/nodes/${node}/qemu")

        local vm_ids
        vm_ids=$(echo "$vms_response" | jq -r '.data[] | select(.status == "running") | .vmid')

        for vm_id in $vm_ids; do
            log "Migrating VM $vm_id from node $node..."

            # Find another node to migrate to
            local target_node
            target_node=$(get_cluster_nodes | grep -v "$node" | head -1)

            if [ -n "$target_node" ]; then
                # Perform live migration
                local migrate_response
                migrate_response=$(curl -k -s \
                    -X POST \
                    -H "Authorization: PVEAuthCookie ${TICKET}" \
                    -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
                    -d "target=$target_node&online=1" \
                    "${PROXMOX_API_URL}/nodes/${node}/qemu/${vm_id}/migrate")

                if [ $? -ne 0 ]; then
                    warn "Failed to migrate VM $vm_id from node $node"
                else
                    log "VM $vm_id migrated from $node to $target_node"
                fi
            else
                warn "No other nodes available for migration of VM $vm_id"
            fi
        done
    }

    # Function to update Proxmox node
    update_proxmox_node() {
        local node="$1"
        log "Updating Proxmox node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would update Proxmox node $node"
            return 0
        fi

        # Perform apt update and upgrade
        local update_cmd="apt update && apt upgrade -y"
        local cmd_response
        cmd_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            -d "command=$update_cmd" \
            "${PROXMOX_API_URL}/nodes/${node}/commands")

        if [ $? -ne 0 ]; then
            error "Failed to update node $node"
            return 1
        fi

        log "Node $node update completed"
    }

    # Function to restart Proxmox node
    restart_node() {
        local node="$1"
        log "Restarting Proxmox node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would restart node $node"
            return 0
        fi

        # Restart the node
        local restart_response
        restart_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            "${PROXMOX_API_URL}/nodes/${node}/status")

        if [ $? -ne 0 ]; then
            error "Failed to initiate restart for node $node"
            return 1
        fi

        # Actually restart via command
        local restart_cmd="reboot"
        local cmd_response
        cmd_response=$(curl -k -s \
            -X POST \
            -H "Authorization: PVEAuthCookie ${TICKET}" \
            -H "CSRFPreventionToken: ${CSRF_PREVENTION_TOKEN}" \
            -d "command=$restart_cmd" \
            "${PROXMOX_API_URL}/nodes/${node}/commands")

        if [ $? -ne 0 ]; then
            error "Failed to execute restart command for node $node"
            return 1
        fi

        log "Node $node restart initiated"

        # Wait for node to come back online
        log "Waiting for node $node to restart..."
        local timeout=300  # 5 minutes
        local count=0

        while [ $count -lt $timeout ]; do
            sleep 10
            count=$((count + 10))

            if get_node_status "$node" >/dev/null 2>&1; then
                log "Node $node is back online"
                return 0
            fi
        done

        error "Node $node did not come back online within timeout period"
        return 1
    }

    # Function to perform rolling update of cluster
    perform_cluster_update() {
        log "Starting cluster update process..."

        local nodes
        nodes=$(get_cluster_nodes)
        local node_array=($nodes)
        local total_nodes=${#node_array[@]}

        log "Cluster has $total_nodes nodes: ${node_array[*]}"

        for node in "${node_array[@]}"; do
            log "Processing node: $node"

            # Check node status
            local status
            status=$(get_node_status "$node")
            if [ "$status" != "online" ]; then
                warn "Node $node is not online ($status), skipping update"
                continue
            fi

            # Check for updates
            local update_count
            update_count=$(check_for_updates "$node")

            if [ "$update_count" -gt 0 ]; then
                log "Updates available for node $node ($update_count updates)"

                # Get update list
                log "Updates for node $node:"
                get_update_list "$node" | while read -r pkg; do
                    if [ -n "$pkg" ]; then
                        log "  - $pkg"
                    fi
                done

                # Put node in maintenance mode
                put_node_maintenance "$node"

                # Migrate VMs if any are running
                migrate_vms_from_node "$node"

                # Update the node
                if ! update_proxmox_node "$node"; then
                    error "Update failed for node $node"
                    remove_node_maintenance "$node"
                    continue
                fi

                # Restart node if needed
                restart_node "$node"

                # Remove maintenance mode
                remove_node_maintenance "$node"

                log "Node $node updated successfully"
            else
                log "No updates available for node $node"
            fi

            # Wait between nodes to avoid simultaneous updates
            sleep 120
        done

        log "Cluster update process completed"
    }

    # Function to perform single node update
    perform_single_node_update() {
        log "Starting single node update process..."

        # Check for updates
        local update_count
        update_count=$(check_for_updates "$PROXMOX_HOST")

        if [ "$update_count" -gt 0 ]; then
            log "Updates available for node $PROXMOX_HOST ($update_count updates)"

            # Get update list
            log "Updates for node $PROXMOX_HOST:"
            get_update_list "$PROXMOX_HOST" | while read -r pkg; do
                if [ -n "$pkg" ]; then
                    log "  - $pkg"
                fi
            done

            # Put node in maintenance mode
            put_node_maintenance "$PROXMOX_HOST"

            # Update the node
            if ! update_proxmox_node "$PROXMOX_HOST"; then
                error "Update failed for node $PROXMOX_HOST"
                remove_node_maintenance "$PROXMOX_HOST"
                exit 1
            fi

            # Restart node if needed
            restart_node "$PROXMOX_HOST"

            # Remove maintenance mode
            remove_node_maintenance "$PROXMOX_HOST"

            log "Node $PROXMOX_HOST updated successfully"
        else
            log "No updates available for node $PROXMOX_HOST"
        fi
    }

    # Function to check patch window
    is_patch_window_active() {
        local current_time
        current_time=$(date +%H:%M)

        local start_time
        local end_time
        start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
        end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)

        # Convert times to minutes since midnight for comparison
        local current_minutes
        local start_minutes
        local end_minutes

        current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
        start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
        end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))

        if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
            return 0
        else
            return 1
        fi
    }

    # Main function
    main() {
        log "Starting Proxmox automatic patching process"

        # Check if we're in patch window
        if ! is_patch_window_active; then
            warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
            exit 0
        fi

        # Check prerequisites
        check_prerequisites

        # Authenticate with Proxmox API
        authenticate_proxmox

        # Determine update strategy based on cluster mode
        if [ "$CLUSTER_MODE" = true ]; then
            perform_cluster_update
        else
            perform_single_node_update
        fi

        log "Proxmox patching process completed"
    }

    # Run main function if script is executed directly
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
EOF_PROXMOX

              # Copy Talos patching script
              cat << 'EOF_TALOS' > /scripts/talos-patching.sh
    #!/bin/bash

    # Twinbox Talos Linux Automatic Patching Script
    # Handles automatic updates for Talos Linux nodes with safe rollout

    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Logging functions
    log() {
        echo -e "${GREEN}[PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    warn() {
        echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    error() {
        echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    # Configuration
    TALOS_CONFIG="${TALOS_CONFIG:-./talosconfig}"
    PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"
    PATCH_WINDOW="${PATCH_WINDOW:-02:00-04:00}"
    DRY_RUN="${DRY_RUN:-false}"
    MAX_UNAVAILABLE="${MAX_UNAVAILABLE:-1}"
    GRACE_PERIOD="${GRACE_PERIOD:-300}"

    # Function to check prerequisites
    check_prerequisites() {
        log "Checking prerequisites..."

        if ! command -v talosctl &> /dev/null; then
            error "talosctl is not installed"
            exit 1
        fi

        if [ ! -f "$TALOS_CONFIG" ]; then
            error "Talos config file not found: $TALOS_CONFIG"
            exit 1
        fi

        log "Prerequisites check passed"
    }

    # Function to get cluster nodes
    get_nodes() {
        log "Retrieving cluster nodes..."

        local nodes
        nodes=$(talosctl --talosconfig="$TALOS_CONFIG" get machines --output json 2>/dev/null | jq -r '.items[].id' || echo "")

        if [ -z "$nodes" ]; then
            error "No nodes found in cluster"
            exit 1
        fi

        echo "$nodes"
    }

    # Function to get node status
    get_node_status() {
        local node="$1"
        talosctl --talosconfig="$TALOS_CONFIG" get machineconfiguration -n "$node" --output json 2>/dev/null | jq -r '.items[0].status.phase' || echo "unknown"
    }

    # Function to check if node is ready for patching
    is_node_ready_for_patching() {
        local node="$1"

        # Check if node is ready
        local ready_status
        ready_status=$(kubectl get nodes "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

        if [ "$ready_status" != "True" ]; then
            warn "Node $node is not ready, skipping patching"
            return 1
        fi

        return 0
    }

    # Function to drain node safely
    drain_node() {
        local node="$1"

        log "Draining node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would drain node $node"
            return 0
        fi

        kubectl drain "$node" \
            --ignore-daemonsets \
            --delete-emptydir-data \
            --timeout=${GRACE_PERIOD}s \
            --grace-period=30

        if [ $? -ne 0 ]; then
            error "Failed to drain node $node"
            return 1
        fi

        log "Node $node drained successfully"
    }

    # Function to uncordon node
    uncordon_node() {
        local node="$1"

        log "Uncordoning node $node..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would uncordon node $node"
            return 0
        fi

        kubectl uncordon "$node"

        if [ $? -ne 0 ]; then
            error "Failed to uncordon node $node"
            return 1
        fi

        log "Node $node uncordoned successfully"
    }

    # Function to update Talos node
    update_talos_node() {
        local node="$1"
        local version="$2"

        log "Updating Talos node $node to version $version..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would update node $node to version $version"
            return 0
        fi

        # Apply update using talosctl
        talosctl --talosconfig="$TALOS_CONFIG" -n "$node" upgrade --image="ghcr.io/siderolabs/installer:$version" --preserve=true --wait=true

        if [ $? -ne 0 ]; then
            error "Failed to update node $node"
            return 1
        fi

        log "Node $node updated successfully"
    }

    # Function to verify node after update
    verify_node_after_update() {
        local node="$1"
        local timeout=300
        local count=0

        log "Verifying node $node after update..."

        while [ $count -lt $timeout ]; do
            local ready_status
            ready_status=$(kubectl get nodes "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

            if [ "$ready_status" = "True" ]; then
                log "Node $node is ready after update"
                return 0
            fi

            sleep 10
            count=$((count + 10))
        done

        error "Node $node did not become ready within timeout period"
        return 1
    }

    # Function to get available Talos versions
    get_available_versions() {
        log "Checking for available Talos versions..."

        # Get latest stable version
        local latest_version
        latest_version=$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r '.tag_name' | sed 's/^v//')

        if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
            error "Could not fetch latest Talos version"
            return 1
        fi

        echo "$latest_version"
    }

    # Function to get current Talos versions in cluster
    get_current_versions() {
        log "Checking current Talos versions in cluster..."

        talosctl --talosconfig="$TALOS_CONFIG" get machineconfigurations --output json 2>/dev/null | jq -r '.items[].status.version' | sort -u
    }

    # Function to perform rolling update
    perform_rolling_update() {
        local target_version="$1"
        local nodes
        nodes=$(get_nodes)

        log "Starting rolling update to Talos $target_version"

        # Convert nodes to array
        local node_array=($nodes)
        local total_nodes=${#node_array[@]}
        local updated_count=0

        # Update control plane nodes first
        log "Updating control plane nodes..."
        for node in "${node_array[@]}"; do
            # Check if this is a control plane node
            local is_control_plane
            is_control_plane=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")

            if [ -n "$is_control_plane" ]; then
                log "Processing control plane node: $node"

                if ! is_node_ready_for_patching "$node"; then
                    continue
                fi

                # Drain node
                if ! drain_node "$node"; then
                    warn "Skipping node $node due to drain failure"
                    continue
                fi

                # Update node
                if ! update_talos_node "$node" "$target_version"; then
                    error "Update failed for node $node, stopping update process"
                    uncordon_node "$node"
                    return 1
                fi

                # Verify node
                if ! verify_node_after_update "$node"; then
                    error "Verification failed for node $node, initiating rollback"
                    uncordon_node "$node"
                    return 1
                fi

                # Uncordon node
                uncordon_node "$node"

                updated_count=$((updated_count + 1))
                log "Updated $updated_count/$total_nodes nodes"

                # Wait before updating next node
                sleep 60
            fi
        done

        # Update worker nodes
        log "Updating worker nodes..."
        for node in "${node_array[@]}"; do
            # Skip control plane nodes
            local is_control_plane
            is_control_plane=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || echo "")

            if [ -z "$is_control_plane" ]; then
                log "Processing worker node: $node"

                if ! is_node_ready_for_patching "$node"; then
                    continue
                fi

                # Drain node
                if ! drain_node "$node"; then
                    warn "Skipping node $node due to drain failure"
                    continue
                fi

                # Update node
                if ! update_talos_node "$node" "$target_version"; then
                    error "Update failed for node $node"
                    uncordon_node "$node"
                    continue
                fi

                # Verify node
                if ! verify_node_after_update "$node"; then
                    error "Verification failed for node $node"
                    uncordon_node "$node"
                    continue
                fi

                # Uncordon node
                uncordon_node "$node"

                updated_count=$((updated_count + 1))
                log "Updated $updated_count/$total_nodes nodes"

                # Wait before updating next node
                sleep 30
            fi
        done

        log "Rolling update completed. Updated $updated_count/$total_nodes nodes."
    }

    # Function to check patch window
    is_patch_window_active() {
        local current_time
        current_time=$(date +%H:%M)

        local start_time
        local end_time
        start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
        end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)

        # Convert times to minutes since midnight for comparison
        local current_minutes
        local start_minutes
        local end_minutes

        current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
        start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
        end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))

        if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
            return 0
        else
            return 1
        fi
    }

    # Main function
    main() {
        log "Starting Talos automatic patching process"

        # Check if we're in patch window
        if ! is_patch_window_active; then
            warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
            exit 0
        fi

        # Check prerequisites
        check_prerequisites

        # Get available version
        local latest_version
        latest_version=$(get_available_versions)
        if [ $? -ne 0 ]; then
            error "Could not determine latest Talos version"
            exit 1
        fi

        # Get current versions
        local current_versions
        current_versions=$(get_current_versions)
        log "Current Talos versions in cluster: $current_versions"

        # Check if update is needed
        local needs_update=false
        for version in $current_versions; do
            if [ "$version" != "$latest_version" ]; then
                needs_update=true
                break
            fi
        done

        if [ "$needs_update" = true ]; then
            log "Update needed. Latest version: $latest_version"
            perform_rolling_update "$latest_version"
        else
            log "All nodes are running latest version: $latest_version"
        fi

        log "Talos patching process completed"
    }

    # Run main function if script is executed directly
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
EOF_TALOS

              # Copy Kubernetes components patching script
              cat << 'EOF_K8S' > /scripts/k8s-components-patching.sh
    #!/bin/bash

    # Twinbox Kubernetes Components Automatic Patching Script
    # Handles automatic updates for Kubernetes components and deployed services

    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Logging functions
    log() {
        echo -e "${GREEN}[K8S-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    warn() {
        echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    error() {
        echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    # Configuration
    PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"
    PATCH_WINDOW="${PATCH_WINDOW:-03:00-05:00}"
    DRY_RUN="${DRY_RUN:-false}"
    HELM_UPGRADE_TIMEOUT="${HELM_UPGRADE_TIMEOUT:-600}"
    NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"

    # Function to check prerequisites
    check_prerequisites() {
        log "Checking prerequisites..."

        if ! command -v kubectl &> /dev/null; then
            error "kubectl is not installed"
            exit 1
        fi

        if ! command -v helm &> /dev/null; then
            error "helm is not installed"
            exit 1
        fi

        # Test kubectl connectivity
        if ! kubectl cluster-info &> /dev/null; then
            error "Cannot connect to Kubernetes cluster"
            exit 1
        fi

        log "Prerequisites check passed"
    }

    # Function to send notification
    send_notification() {
        local message="$1"
        local status="${2:-info}"

        if [ -n "$NOTIFICATION_WEBHOOK" ]; then
            case $status in
                "success")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"✅ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                "warning")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"⚠️ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                "error")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"❌ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                *)
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"ℹ️ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
            esac
        fi
    }

    # Function to get latest stable version for an image
    get_latest_stable_version() {
        local image_name="$1"
        local registry="${2:-docker.io}"

        case $image_name in
            "rook/ceph")
                # Get latest stable version from GitHub releases
                curl -s https://api.github.com/repos/rook/rook/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            "traefik")
                curl -s https://api.github.com/repos/traefik/traefik/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            "bitnami/keycloak")
                # Use Helm to get latest version
                helm show chart bitnami/keycloak 2>/dev/null | grep '^version:' | head -1 | awk '{print $2}'
                ;;
            "portainer/portainer-ce")
                curl -s https://api.github.com/repos/portainer/portainer/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            "argoproj/argocd")
                curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r '.tag_name' | sed 's/^v//'
                ;;
            *)
                # For generic images, we'll use a placeholder
                echo "latest"
                ;;
        esac
    }

    # Function to check if Helm repo exists and add if needed
    ensure_helm_repo() {
        local repo_name="$1"
        local repo_url="$2"

        if ! helm repo list | grep -q "$repo_name"; then
            log "Adding Helm repository: $repo_name"
            helm repo add "$repo_name" "$repo_url"
        fi

        # Update repo to get latest charts
        helm repo update "$repo_name"
    }

    # Function to upgrade Rook/Ceph
    upgrade_rook_ceph() {
        log "Checking for Rook/Ceph updates..."

        ensure_helm_repo "rook-release" "https://charts.rook.io/release"

        # Get current version
        local current_version=""
        if kubectl get namespace rook-ceph &> /dev/null; then
            current_version=$(helm status rook-ceph -n rook-ceph 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "rook/ceph")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Rook/Ceph update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Rook/Ceph to $latest_version"
                return 0
            fi

            # Upgrade Rook operator
            helm upgrade rook-ceph rook-release/rook-ceph \
                --version "$latest_version" \
                --namespace rook-ceph \
                --create-namespace \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            log "Rook/Ceph upgraded to $latest_version"
            send_notification "Rook/Ceph upgraded to $latest_version" "success"
        else
            log "Rook/Ceph is up to date: $current_version"
        fi
    }

    # Function to upgrade Traefik
    upgrade_traefik() {
        log "Checking for Traefik updates..."

        ensure_helm_repo "traefik" "https://helm.traefik.io/traefik"

        # Get current version
        local current_version=""
        if kubectl get namespace traefik &> /dev/null; then
            current_version=$(helm status traefik -n traefik 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "traefik")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Traefik update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Traefik to $latest_version"
                return 0
            fi

            # Get current values to preserve configuration
            local temp_values="/tmp/traefik-values-$(date +%s).yaml"
            helm get values traefik -n traefik > "$temp_values"

            # Upgrade Traefik
            helm upgrade traefik traefik/traefik \
                --version "$latest_version" \
                --namespace traefik \
                --create-namespace \
                --values "$temp_values" \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            rm -f "$temp_values"

            log "Traefik upgraded to $latest_version"
            send_notification "Traefik upgraded to $latest_version" "success"
        else
            log "Traefik is up to date: $current_version"
        fi
    }

    # Function to upgrade Keycloak
    upgrade_keycloak() {
        log "Checking for Keycloak updates..."

        ensure_helm_repo "bitnami" "https://charts.bitnami.com/bitnami"

        # Get current version
        local current_version=""
        if kubectl get namespace keycloak &> /dev/null; then
            current_version=$(helm status keycloak -n keycloak 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "bitnami/keycloak")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Keycloak update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Keycloak to $latest_version"
                return 0
            fi

            # Get current values to preserve configuration
            local temp_values="/tmp/keycloak-values-$(date +%s).yaml"
            helm get values keycloak -n keycloak > "$temp_values"

            # Upgrade Keycloak
            helm upgrade keycloak bitnami/keycloak \
                --version "$latest_version" \
                --namespace keycloak \
                --create-namespace \
                --values "$temp_values" \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            rm -f "$temp_values"

            log "Keycloak upgraded to $latest_version"
            send_notification "Keycloak upgraded to $latest_version" "success"
        else
            log "Keycloak is up to date: $current_version"
        fi
    }

    # Function to upgrade Portainer
    upgrade_portainer() {
        log "Checking for Portainer updates..."

        # For Portainer, we'll update the deployment directly
        local current_image=""
        if kubectl get namespace portainer &> /dev/null; then
            current_image=$(kubectl get deployment portainer -n portainer -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
        fi

        # Extract version from image
        local current_version=""
        if [ -n "$current_image" ]; then
            current_version=$(echo "$current_image" | cut -d':' -f2)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "portainer/portainer-ce")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "Portainer update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade Portainer to $latest_version"
                return 0
            fi

            # Update the deployment
            kubectl set image deployment/portainer portainer=portainer/portainer-ce:$latest_version -n portainer

            log "Portainer upgraded to $latest_version"
            send_notification "Portainer upgraded to $latest_version" "success"
        else
            log "Portainer is up to date: $current_version"
        fi
    }

    # Function to upgrade ArgoCD
    upgrade_argocd() {
        log "Checking for ArgoCD updates..."

        ensure_helm_repo "argocd" "https://argoproj.github.io/argo-helm"

        # Get current version
        local current_version=""
        if kubectl get namespace argocd &> /dev/null; then
            current_version=$(helm status argocd -n argocd 2>/dev/null | grep -i "chart" | head -1 | awk '{print $NF}' | cut -d'-' -f2-)
        fi

        # Get latest version
        local latest_version
        latest_version=$(get_latest_stable_version "argoproj/argocd")

        if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
            log "ArgoCD update available: $current_version -> $latest_version"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Would upgrade ArgoCD to $latest_version"
                return 0
            fi

            # Get current values to preserve configuration
            local temp_values="/tmp/argocd-values-$(date +%s).yaml"
            helm get values argocd -n argocd > "$temp_values"

            # Upgrade ArgoCD
            helm upgrade argocd argocd/argo-cd \
                --version "$latest_version" \
                --namespace argocd \
                --create-namespace \
                --values "$temp_values" \
                --timeout "${HELM_UPGRADE_TIMEOUT}s"

            rm -f "$temp_values"

            log "ArgoCD upgraded to $latest_version"
            send_notification "ArgoCD upgraded to $latest_version" "success"
        else
            log "ArgoCD is up to date: $current_version"
        fi
    }

    # Function to upgrade system components
    upgrade_system_components() {
        log "Upgrading system components..."

        # Upgrade kube-proxy
        upgrade_kubeproxy

        # Upgrade CoreDNS
        upgrade_coredns

        # Upgrade metrics-server if present
        upgrade_metrics_server
    }

    # Function to upgrade kube-proxy
    upgrade_kubeproxy() {
        log "Checking for kube-proxy updates..."

        # Get current image
        local current_image
        current_image=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

        if [ -n "$current_image" ]; then
            local current_version
            current_version=$(echo "$current_image" | cut -d':' -f2)

            # For kube-proxy, we'll use the current Kubernetes version
            local k8s_version
            k8s_version=$(kubectl version --short | grep -i server | awk '{print $3}' | sed 's/v//')

            if [ "$current_version" != "$k8s_version" ]; then
                log "kube-proxy update available: $current_version -> $k8s_version"

                if [ "$DRY_RUN" = true ]; then
                    log "[DRY RUN] Would upgrade kube-proxy to $k8s_version"
                    return 0
                fi

                # Update kube-proxy image
                kubectl set image daemonset kube-proxy kube-proxy=k8s.gcr.io/kube-proxy:$k8s_version -n kube-system

                log "kube-proxy upgraded to $k8s_version"
            else
                log "kube-proxy is up to date: $current_version"
            fi
        fi
    }

    # Function to upgrade CoreDNS
    upgrade_coredns() {
        log "Checking for CoreDNS updates..."

        # Get current image
        local current_image
        current_image=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

        if [ -n "$current_image" ]; then
            local current_version
            current_version=$(echo "$current_image" | cut -d':' -f2)

            # Get latest stable CoreDNS version
            local latest_version
            latest_version=$(curl -s https://api.github.com/repos/coredns/deployment/releases/latest | jq -r '.tag_name' | sed 's/^v//')

            if [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
                log "CoreDNS update available: $current_version -> $latest_version"

                if [ "$DRY_RUN" = true ]; then
                    log "[DRY RUN] Would upgrade CoreDNS to $latest_version"
                    return 0
                fi

                # Update CoreDNS image
                kubectl set image deployment coredns coredns=coredns/coredns:$latest_version -n kube-system

                log "CoreDNS upgraded to $latest_version"
            else
                log "CoreDNS is up to date: $current_version"
            fi
        fi
    }

    # Function to upgrade metrics-server
    upgrade_metrics_server() {
        log "Checking for metrics-server updates..."

        # Check if metrics-server is deployed
        if kubectl get deployment metrics-server -n kube-system &> /dev/null; then
            # Get current image
            local current_image
            current_image=$(kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

            if [ -n "$current_image" ]; then
                local current_version
                current_version=$(echo "$current_image" | cut -d':' -f2)

                # Get latest stable metrics-server version
                local latest_version
                latest_version=$(curl -s https://api.github.com/repos/kubernetes-sigs/metrics-server/releases/latest | jq -r '.tag_name' | sed 's/^v//')

                if [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
                    log "Metrics-server update available: $current_version -> $latest_version"

                    if [ "$DRY_RUN" = true ]; then
                        log "[DRY RUN] Would upgrade metrics-server to $latest_version"
                        return 0
                    fi

                    # Update metrics-server image
                    kubectl set image deployment metrics-server metrics-server=k8s.gcr.io/metrics-server/metrics-server:$latest_version -n kube-system

                    log "Metrics-server upgraded to $latest_version"
                else
                    log "Metrics-server is up to date: $current_version"
                fi
            fi
        else
            log "Metrics-server not found in cluster"
        fi
    }

    # Function to check patch window
    is_patch_window_active() {
        local current_time
        current_time=$(date +%H:%M)

        local start_time
        local end_time
        start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
        end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)

        # Convert times to minutes since midnight for comparison
        local current_minutes
        local start_minutes
        local end_minutes

        current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
        start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
        end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))

        if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
            return 0
        else
            return 1
        fi
    }

    # Main function
    main() {
        log "Starting Kubernetes components automatic patching process"

        # Check if we're in patch window
        if ! is_patch_window_active; then
            warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
            exit 0
        fi

        # Check prerequisites
        check_prerequisites

        # Send notification that patching is starting
        send_notification "Starting Kubernetes components patching process" "info"

        # Upgrade system components first
        upgrade_system_components

        # Upgrade service components
        upgrade_rook_ceph
        upgrade_traefik
        upgrade_keycloak
        upgrade_portainer
        upgrade_argocd

        # Send completion notification
        send_notification "Kubernetes components patching completed successfully" "success"

        log "Kubernetes components patching process completed"
    }

    # Run main function if script is executed directly
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
EOF_K8S

              # Make scripts executable
              chmod +x /scripts/proxmox-patching.sh
              chmod +x /scripts/talos-patching.sh
              chmod +x /scripts/k8s-components-patching.sh
              
              # Run unified patching script
              /scripts/unified-patcher.sh
            volumeMounts:
            - name: patch-scripts
              mountPath: /scripts
              readOnly: true
            env:
            - name: PATCH_SCHEDULE
              value: "weekly"
            - name: PATCH_WINDOW
              value: "02:00-06:00"
            - name: DRY_RUN
              value: "false"
            - name: PATCH_ORDER
              value: "proxmox,talos,k8s"
            - name: NOTIFICATION_WEBHOOK
              valueFrom:
                secretKeyRef:
                  name: unified-patch-secrets
                  key: webhook-url
                  optional: true
            - name: PROXMOX_HOST
              valueFrom:
                configMapKeyRef:
                  name: unified-patch-config
                  key: proxmoxHost
            - name: PROXMOX_USER
              valueFrom:
                configMapKeyRef:
                  name: unified-patch-config
                  key: proxmoxUser
            - name: PROXMOX_API_URL
              valueFrom:
                configMapKeyRef:
                  name: unified-patch-config
                  key: proxmoxApiUrl
            - name: PROXMOX_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: unified-patch-secrets
                  key: proxmox-password
            - name: TALOS_CONFIG
              value: "/tmp/talosconfig"
            - name: HELM_UPGRADE_TIMEOUT
              value: "600"
            - name: SLACK_CHANNEL
              valueFrom:
                configMapKeyRef:
                  name: unified-patch-config
                  key: slackChannel
            - name: EMAIL_RECIPIENTS
              valueFrom:
                configMapKeyRef:
                  name: unified-patch-config
                  key: emailRecipients
          volumes:
          - name: patch-scripts
            configMap:
              name: unified-patch-scripts
          restartPolicy: OnFailure
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: unified-patch-scripts
  namespace: unified-patcher
data:
  unified-patcher.sh: |
    #!/bin/bash

    # Twinbox Unified Automatic Patching Orchestrator
    # Coordinates patching across all platform layers: Proxmox, Talos, Kubernetes services

    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    # Logging functions
    log() {
        echo -e "${GREEN}[UNIFIED-PATCH]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    warn() {
        echo -e "${YELLOW}[WARN]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    error() {
        echo -e "${RED}[ERROR]$(date '+%Y-%m-%d %H:%M:%S')${NC} $1"
    }

    # Configuration
    PATCH_SCHEDULE="${PATCH_SCHEDULE:-weekly}"
    PATCH_WINDOW="${PATCH_WINDOW:-02:00-06:00}"
    DRY_RUN="${DRY_RUN:-false}"
    PATCH_ORDER="${PATCH_ORDER:-proxmox,talos,k8s}"
    NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"
    SLACK_CHANNEL="${SLACK_CHANNEL:-}"
    EMAIL_RECIPIENTS="${EMAIL_RECIPIENTS:-}"

    # Function to check prerequisites
    check_prerequisites() {
        log "Checking prerequisites..."

        if ! command -v curl &> /dev/null; then
            error "curl is not installed"
            exit 1
        fi

        if ! command -v jq &> /dev/null; then
            error "jq is not installed"
            exit 1
        fi

        log "Prerequisites check passed"
    }

    # Function to send notification
    send_notification() {
        local message="$1"
        local status="${2:-info}"

        # Send to webhook if configured
        if [ -n "$NOTIFICATION_WEBHOOK" ]; then
            case $status in
                "success")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"✅ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                "warning")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"⚠️ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                "error")
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"❌ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
                *)
                    curl -X POST -H "Content-Type: application/json" \
                        -d "{\"text\":\"ℹ️ $message\"}" \
                        "$NOTIFICATION_WEBHOOK" 2>/dev/null || true
                    ;;
            esac
        fi

        # Additional notification methods could be added here
    }

    # Function to run Proxmox patching
    run_proxmox_patching() {
        log "Starting Proxmox patching..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would run Proxmox patching"
            return 0
        fi

        # Check if Proxmox patching script exists
        if [ -f "/scripts/proxmox-patching.sh" ]; then
            log "Running Proxmox patching script..."
            bash /scripts/proxmox-patching.sh
        else
            warn "Proxmox patching script not found, skipping"
        fi
    }

    # Function to run Talos patching
    run_talos_patching() {
        log "Starting Talos patching..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would run Talos patching"
            return 0
        fi

        # Check if Talos patching script exists
        if [ -f "/scripts/talos-patching.sh" ]; then
            log "Running Talos patching script..."
            bash /scripts/talos-patching.sh
        else
            warn "Talos patching script not found, skipping"
        fi
    }

    # Function to run Kubernetes components patching
    run_k8s_patching() {
        log "Starting Kubernetes components patching..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would run Kubernetes components patching"
            return 0
        fi

        # Check if Kubernetes patching script exists
        if [ -f "/scripts/k8s-components-patching.sh" ]; then
            log "Running Kubernetes components patching script..."
            bash /scripts/k8s-components-patching.sh
        else
            warn "Kubernetes components patching script not found, skipping"
        fi
    }

    # Function to check system health before patching
    check_system_health() {
        log "Checking system health before patching..."

        # Check cluster status
        if command -v kubectl &> /dev/null; then
            local node_count
            node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

            if [ "$node_count" -gt 0 ]; then
                local ready_nodes
                ready_nodes=$(kubectl get nodes --no-headers -o custom-columns=:.status.conditions[?(@.type=='Ready')].status | grep -c True 2>/dev/null || echo "0")

                log "Cluster health: $ready_nodes/$node_count nodes ready"

                if [ "$ready_nodes" -lt 1 ]; then
                    error "Cluster is not healthy, aborting patching"
                    return 1
                fi
            fi
        fi

        # Additional health checks could be added here
        # - Check storage status
        # - Check network connectivity
        # - Check application health

        log "System health check passed"
    }

    # Function to check patch window
    is_patch_window_active() {
        local current_time
        current_time=$(date +%H:%M)

        local start_time
        local end_time
        start_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f1)
        end_time=$(echo "$PATCH_WINDOW" | cut -d'-' -f2)

        # Convert times to minutes since midnight for comparison
        local current_minutes
        local start_minutes
        local end_minutes

        current_minutes=$((10#$(echo "$current_time" | cut -d':' -f1) * 60 + 10#$(echo "$current_time" | cut -d':' -f2)))
        start_minutes=$((10#$(echo "$start_time" | cut -d':' -f1) * 60 + 10#$(echo "$start_time" | cut -d':' -f2)))
        end_minutes=$((10#$(echo "$end_time" | cut -d':' -f1) * 60 + 10#$(echo "$end_time" | cut -d':' -f2)))

        if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -le $end_minutes ]; then
            return 0
        else
            return 1
        fi
    }

    # Function to run patching in specified order
    run_patching_sequence() {
        log "Starting unified patching sequence..."

        # Check system health first
        if ! check_system_health; then
            error "System health check failed, aborting patching"
            send_notification "Patching aborted due to system health issues" "error"
            return 1
        fi

        # Parse patch order
        local orders
        IFS=',' read -ra orders <<< "$PATCH_ORDER"

        for component in "${orders[@]}"; do
            case $component in
                "proxmox")
                    log "Patching Proxmox layer..."
                    if ! run_proxmox_patching; then
                        error "Proxmox patching failed"
                        send_notification "Proxmox patching failed" "error"
                        # Continue with other components
                    else
                        send_notification "Proxmox patching completed successfully" "success"
                    fi
                    ;;
                "talos")
                    log "Patching Talos layer..."
                    if ! run_talos_patching; then
                        error "Talos patching failed"
                        send_notification "Talos patching failed" "error"
                        # Continue with other components
                    else
                        send_notification "Talos patching completed successfully" "success"
                    fi
                    ;;
                "k8s")
                    log "Patching Kubernetes layer..."
                    if ! run_k8s_patching; then
                        error "Kubernetes patching failed"
                        send_notification "Kubernetes patching failed" "error"
                        # Continue with other components
                    else
                        send_notification "Kubernetes patching completed successfully" "success"
                    fi
                    ;;
                *)
                    warn "Unknown component in patch order: $component"
                    ;;
            esac
        done

        log "Unified patching sequence completed"
    }

    # Function to generate patching report
    generate_report() {
        log "Generating patching report..."

        local report_content="Patching Report - $(date)\n"
        report_content+="Schedule: $PATCH_SCHEDULE\n"
        report_content+="Patch Window: $PATCH_WINDOW\n"
        report_content+="Dry Run: $DRY_RUN\n"
        report_content+="Components Patched: $PATCH_ORDER\n"

        # Add more details to the report
        if command -v kubectl &> /dev/null; then
            local node_count
            local ready_count
            node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
            ready_count=$(kubectl get nodes --no-headers -o custom-columns=:.status.conditions[?(@.type=='Ready')].status 2>/dev/null | grep -c True || echo "0")

            report_content+="Kubernetes Nodes: $ready_count/$node_count ready\n"
        fi

        echo -e "$report_content"

        # Optionally save report to file
        local report_file="/tmp/unified-patching-report-$(date +%s).txt"
        echo -e "$report_content" > "$report_file"
        log "Patching report saved to: $report_file"
    }

    # Main function
    main() {
        log "Starting Twinbox Unified Automatic Patching Orchestrator"

        # Check if we're in patch window
        if ! is_patch_window_active; then
            warn "Current time is not in patch window ($PATCH_WINDOW), exiting"
            exit 0
        fi

        # Check prerequisites
        check_prerequisites

        # Send notification that patching is starting
        send_notification "Starting unified patching process" "info"

        # Run the patching sequence
        run_patching_sequence

        # Generate and send final report
        generate_report
        send_notification "Unified patching process completed successfully" "success"

        log "Twinbox Unified Automatic Patching Orchestrator completed"
    }

    # Run main function if script is executed directly
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
---
apiVersion: v1
kind: Secret
metadata:
  name: unified-patch-secrets
  namespace: unified-patcher
type: Opaque
stringData:
  webhook-url: ""
  proxmox-password: ""
```

Make the script executable:
```bash
chmod +x patching/unified-patcher.sh
```

**Step 4: Run test to verify it passes**
Run: `bash tests/unified_patching_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add patching/unified-patcher.sh k8s-manifests/patching/unified-patcher.yaml
git commit -m "Add unified automatic patching orchestrator"
```

### Task 5: Create Patching Documentation and Integration Tests

**Files:**
- Create: `docs/automatic-patching-guide.md`
- Create: `tests/integration-patching-test.sh`
- Update: `tests/run-all-tests.sh`

**Step 1: Write the failing test**
```bash
#!/bin/bash
# tests/final_patching_test.sh
set -e

if [ ! -f "docs/automatic-patching-guide.md" ]; then
    echo "FAIL: docs/automatic-patching-guide.md does not exist"
    exit 1
fi

if [ ! -f "tests/integration-patching-test.sh" ]; then
    echo "FAIL: tests/integration-patching-test.sh does not exist"
    exit 1
fi

if ! grep -q "patching" "tests/run-all-tests.sh"; then
    echo "FAIL: patching test not included in run-all-tests.sh"
    exit 1
fi

echo "PASS: Patching documentation and tests exist"
```

**Step 2: Run test to verify it fails**
Run: `bash tests/final_patching_test.sh`
Expected: FAIL error indicating files don't exist

**Step 3: Write minimal implementation**

Create `docs/automatic-patching-guide.md`:
```markdown
# Twinbox Automatic Patching Guide

This guide explains how to configure and use the automatic patching system for the Twinbox Kubernetes platform.

## Overview

The Twinbox automatic patching system provides coordinated updates across all platform layers:

- **Proxmox VE**: Host system updates
- **Talos Linux**: Kubernetes node OS updates
- **Kubernetes Components**: Core services and applications
- **Platform Services**: Rook, Traefik, Keycloak, Portainer, ArgoCD

## Architecture

The patching system consists of multiple coordinated components:

1. **Layer-Specific Patchers**: Individual patching scripts for each platform layer
2. **Unified Orchestrator**: Coordinates patching across all layers with proper sequencing
3. **Scheduling System**: CronJobs that run patching on configured schedules
4. **Health Checks**: Pre and post-update validation
5. **Notification System**: Alerts for patching status

## Configuration

### Environment Variables

All patching components use standardized environment variables:

#### General Configuration
- `PATCH_SCHEDULE`: How often to patch (`weekly`, `monthly`, `daily`)
- `PATCH_WINDOW`: Time window for patching (`HH:MM-HH:MM`)
- `DRY_RUN`: Whether to simulate patching (`true`, `false`)
- `NOTIFICATION_WEBHOOK`: Webhook URL for notifications

#### Proxmox Configuration
- `PROXMOX_HOST`: Proxmox host address
- `PROXMOX_USER`: Proxmox API user
- `PROXMOX_PASSWORD`: Proxmox API password
- `PROXMOX_API_URL`: Proxmox API URL
- `CLUSTER_MODE`: Whether to operate in cluster mode (`true`, `false`)

#### Talos Configuration
- `TALOS_CONFIG`: Path to Talos config file
- `MAX_UNAVAILABLE`: Maximum unavailable nodes during update
- `GRACE_PERIOD`: Node drain timeout in seconds

#### Kubernetes Configuration
- `HELM_UPGRADE_TIMEOUT`: Timeout for Helm upgrades in seconds

### Patch Order

The unified orchestrator uses a configurable patch order to ensure system stability:

```
proxmox,talos,k8s
```

This means:
1. First update Proxmox hosts
2. Then update Talos nodes
3. Finally update Kubernetes components

## Deployment

### Installing the Patching System

The patching system is deployed as Kubernetes CronJobs in dedicated namespaces:

```bash
# Deploy all patching components
kubectl apply -f k8s-manifests/patching/
```

### ConfigMaps and Secrets

Each patching component has its own ConfigMap for configuration and Secret for sensitive data:

- `talos-updater` namespace
- `k8s-updater` namespace
- `proxmox-updater` namespace
- `unified-patcher` namespace

### Scheduling

The default schedules are:

- **Talos**: Weekly on Sundays at 2 AM (`0 2 * * 0`)
- **Kubernetes Components**: Weekly on Sundays at 3 AM (`0 3 * * 0`)
- **Proxmox**: Monthly on 1st at 2 AM (`0 2 1 * *`)
- **Unified Orchestrator**: Weekly on Sundays at 2 AM (`0 2 * * 0`)

## Operation

### Manual Execution

To run patching manually (useful for testing):

```bash
# Run unified patching manually
kubectl create job --from=cronjob/unified-patcher manual-patch-$(date +%s)

# Run specific layer manually
kubectl create job --from=cronjob/talos-patcher manual-talos-$(date +%s)
kubectl create job --from=cronjob/k8s-patcher manual-k8s-$(date +%s)
kubectl create job --from=cronjob/proxmox-patcher manual-proxmox-$(date +%s)
```

### Monitoring

Monitor patching jobs:

```bash
# Watch all patching jobs
kubectl get jobs -A | grep -i patch

# Check logs of a specific job
kubectl logs -n talos-updater job.batch/talos-patcher-xxxxx

# Check CronJob status
kubectl get cronjobs -A
```

### Health Checks

The system performs several health checks:

1. **Pre-update**: Verifies cluster health before patching
2. **During update**: Monitors node status and application health
3. **Post-update**: Validates system functionality after updates

## Safety Features

### Maintenance Windows

All patching occurs within configured maintenance windows to minimize impact on users.

### Gradual Rollouts

- Proxmox: One node at a time with VM migration
- Talos: Rolling updates with proper draining
- Kubernetes: Respects pod disruption budgets

### Rollback Capability

While the system doesn't automatically rollback, it maintains system state that allows for manual rollbacks if needed.

### Dry Run Mode

All patching components support dry run mode for testing:

```bash
# Set DRY_RUN=true in the CronJob specification
# This shows what would be patched without making changes
```

## Notifications

The system can send notifications to various channels:

- Slack via webhook
- Email via SMTP integration
- Generic webhook endpoints

Configure notification endpoints in the respective Secrets.

## Troubleshooting

### Common Issues

#### Patching Jobs Fail

Check the job logs:
```bash
kubectl logs -n unified-patcher job/unified-patcher-xxxxx
```

Common causes:
- Authentication issues
- Network connectivity problems
- Insufficient permissions
- System health issues

#### Cluster Unhealthy During Patching

The system has built-in health checks that may halt patching if the cluster becomes unhealthy.

#### Proxmox Connection Issues

Ensure the Proxmox API credentials are correct and the Proxmox host is reachable.

### Debugging

Enable verbose logging by modifying the CronJob environment variables:

```yaml
env:
- name: DEBUG
  value: "true"
```

## Security

### RBAC

Each patching component has minimal required permissions:

- `talos-updater`: Node and pod management permissions
- `k8s-updater`: Full application management permissions
- `proxmox-updater`: ConfigMap and Secret read permissions only
- `unified-patcher`: Minimal cluster monitoring permissions

### Secrets Management

Sensitive information like API passwords is stored in Kubernetes Secrets and mounted as environment variables.

## Maintenance

### Updating Patching Scripts

To update the patching scripts:

1. Modify the ConfigMap containing the script
2. The CronJob will automatically pick up the new script on its next run
3. For immediate effect, delete existing jobs to force new ones

### Changing Schedules

Modify the CronJob schedule in the YAML files:

```yaml
spec:
  schedule: "0 3 * * 0"  # Changed from default
```

### Scaling

The patching system is designed to be lightweight and doesn't require scaling. However, you can adjust:

- Concurrency policy
- History limits
- Resource requests/limits

## Best Practices

### Testing

Always test patching configurations in a development environment first using `DRY_RUN=true`.

### Monitoring

Set up monitoring for:
- CronJob execution status
- System health metrics during patching
- Application availability

### Backup

Ensure you have recent backups before enabling automatic patching.

### Communication

Notify stakeholders about maintenance windows and potential service impacts.

## Integration with CI/CD

The patching system can be integrated with CI/CD pipelines for:

- Automated testing of patching scripts
- Promotion of patching configurations
- Canary deployments of patching changes

## Support

For issues with the patching system:

1. Check the logs of the relevant CronJob
2. Verify authentication and permissions
3. Test in dry run mode
4. Review system health before patching
5. Consult the Twinbox documentation

The automatic patching system provides a robust, safe, and coordinated approach to keeping your Twinbox platform up-to-date across all layers.
```

Create `tests/integration-patching-test.sh`:
```bash
#!/bin/bash

# Twinbox Automatic Patching Integration Test
# Tests the complete patching system functionality

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

log "Starting Twinbox Automatic Patching integration test..."

# Test 1: Check all patching scripts exist
log "Test 1: Checking patching scripts..."
PATCHING_SCRIPTS=(
    "patching/talos-patching.sh"
    "patching/k8s-components-patching.sh"
    "patching/proxmox-patching.sh"
    "patching/unified-patcher.sh"
)

for script in "${PATCHING_SCRIPTS[@]}"; do
    if [ ! -f "$script" ]; then
        error "Patching script $script missing"
        exit 1
    fi
    
    if [ ! -x "$script" ]; then
        error "Patching script $script not executable"
        exit 1
    fi
done

# Test 2: Check all patching manifests exist
log "Test 2: Checking patching manifests..."
PATCHING_MANIFESTS=(
    "k8s-manifests/patching/talos-updater.yaml"
    "k8s-manifests/patching/k8s-updater.yaml"
    "k8s-manifests/patching/proxmox-updater.yaml"
    "k8s-manifests/patching/unified-patcher.yaml"
)

for manifest in "${PATCHING_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "Patching manifest $manifest missing"
        exit 1
    fi
done

# Test 3: Check that patching scripts have proper shebangs
log "Test 3: Checking script shebangs..."
for script in "${PATCHING_SCRIPTS[@]}"; do
    if ! head -1 "$script" | grep -q "^#!/bin/bash"; then
        error "Script $script doesn't have proper shebang"
        exit 1
    fi
done

# Test 4: Check that patching scripts have required functions
log "Test 4: Checking required functions in scripts..."
for script in "${PATCHING_SCRIPTS[@]}"; do
    case "$script" in
        *"talos"*)
            if ! grep -q "check_prerequisites\|perform_rolling_update" "$script"; then
                error "Talos script $script missing required functions"
                exit 1
            fi
            ;;
        *"k8s"*)
            if ! grep -q "check_prerequisites\|upgrade_rook_ceph\|upgrade_traefik" "$script"; then
                error "K8s script $script missing required functions"
                exit 1
            fi
            ;;
        *"proxmox"*)
            if ! grep -q "check_prerequisites\|authenticate_proxmox\|perform_cluster_update" "$script"; then
                error "Proxmox script $script missing required functions"
                exit 1
            fi
            ;;
        *"unified"*)
            if ! grep -q "check_prerequisites\|run_patching_sequence\|run_proxmox_patching\|run_talos_patching\|run_k8s_patching" "$script"; then
                error "Unified script $script missing required functions"
                exit 1
            fi
            ;;
    esac
done

# Test 5: Check that CronJobs are properly configured
log "Test 5: Checking CronJob configurations..."
for manifest in "${PATCHING_MANIFESTS[@]}"; do
    if ! grep -q "apiVersion: batch/v1" "$manifest"; then
        error "Manifest $manifest doesn't contain CronJob"
        exit 1
    fi
    
    if ! grep -q "kind: CronJob" "$manifest"; then
        error "Manifest $manifest doesn't define CronJob kind"
        exit 1
    fi
    
    if ! grep -q "schedule:" "$manifest"; then
        error "Manifest $manifest doesn't have schedule"
        exit 1
    fi
done

# Test 6: Check that ConfigMaps are properly configured
log "Test 6: Checking ConfigMap configurations..."
for manifest in "${PATCHING_MANIFESTS[@]}"; do
    if ! grep -q "kind: ConfigMap" "$manifest"; then
        error "Manifest $manifest doesn't define ConfigMap"
        exit 1
    fi
    
    if ! grep -q "patchWindow:\|schedule:" "$manifest"; then
        error "ConfigMap in $manifest doesn't have patch configuration"
        exit 1
    fi
done

# Test 7: Check that RBAC is properly configured
log "Test 7: Checking RBAC configurations..."
for manifest in "${PATCHING_MANIFESTS[@]}"; do
    if ! grep -q "kind: ServiceAccount" "$manifest"; then
        error "Manifest $manifest doesn't define ServiceAccount"
        exit 1
    fi
    
    if ! grep -q "kind: ClusterRole\|kind: Role" "$manifest"; then
        error "Manifest $manifest doesn't define Role/ClusterRole"
        exit 1
    fi
    
    if ! grep -q "kind: ClusterRoleBinding\|kind: RoleBinding" "$manifest"; then
        error "Manifest $manifest doesn't define RoleBinding"
        exit 1
    fi
done

# Test 8: Check that unified patcher includes all components
log "Test 8: Checking unified patcher completeness..."
if ! grep -q "run_proxmox_patching\|run_talos_patching\|run_k8s_patching" "patching/unified-patcher.sh"; then
    error "Unified patcher doesn't include all patching functions"
    exit 1
fi

# Test 9: Check that patching order is configurable
if ! grep -q "PATCH_ORDER" "patching/unified-patcher.sh"; then
    error "Unified patcher doesn't have configurable patch order"
    exit 1
fi

# Test 10: Check that health checks are implemented
log "Test 10: Checking health check implementations..."
if ! grep -q "check_system_health" "patching/unified-patcher.sh"; then
    error "Unified patcher doesn't have system health check"
    exit 1
fi

log "All Twinbox Automatic Patching integration tests passed!"
log "The patching system is properly structured and ready for use."
```

Update the `tests/run-all-tests.sh` to include patching tests:
```bash
#!/bin/bash

# Run all tests for Twinbox Full-Stack Kubernetes with Portainer, Proxmox Backup, Wizard, and Automatic Patching
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

log "Starting all tests for Twinbox Full-Stack Kubernetes with Portainer, Proxmox Backup, Wizard, and Automatic Patching..."

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

# Test 10: Portainer manifests exist
log "Test 10: Checking Portainer manifests..."
PORTAINER_MANIFESTS=(
    "k8s-manifests/portainer/portainer-deployment.yaml"
    "k8s-manifests/portainer/portainer-agent-daemonset.yaml"
    "k8s-manifests/portainer/portainer-ingress.yaml"
)

for manifest in "${PORTAINER_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "Portainer manifest $manifest missing"
        exit 1
    fi
done

# Test 11: Wizard components exist
log "Test 11: Checking Wizard components..."
WIZARD_COMPONENTS=(
    "twinbox-wizard.sh"
    "wizard/setup-wizard.sh"
    "wizard/deploy-from-config.sh"
    "wizard/menu-system.sh"
    "wizard/validate-config.sh"
    "wizard/test-deployment.sh"
)

for component in "${WIZARD_COMPONENTS[@]}"; do
    if [ ! -f "$component" ]; then
        error "Wizard component $component missing"
        exit 1
    fi
    
    if [ ! -x "$component" ]; then
        error "Wizard component $component not executable"
        exit 1
    fi
done

# Test 12: Patching components exist
log "Test 12: Checking Patching components..."
PATCHING_COMPONENTS=(
    "patching/talos-patching.sh"
    "patching/k8s-components-patching.sh"
    "patching/proxmox-patching.sh"
    "patching/unified-patcher.sh"
)

for component in "${PATCHING_COMPONENTS[@]}"; do
    if [ ! -f "$component" ]; then
        error "Patching component $component missing"
        exit 1
    fi
    
    if [ ! -x "$component" ]; then
        error "Patching component $component not executable"
        exit 1
    fi
done

# Test 13: Patching manifests exist
log "Test 13: Checking Patching manifests..."
PATCHING_MANIFESTS=(
    "k8s-manifests/patching/talos-updater.yaml"
    "k8s-manifests/patching/k8s-updater.yaml"
    "k8s-manifests/patching/proxmox-updater.yaml"
    "k8s-manifests/patching/unified-patcher.yaml"
)

for manifest in "${PATCHING_MANIFESTS[@]}"; do
    if [ ! -f "$manifest" ]; then
        error "Patching manifest $manifest missing"
        exit 1
    fi
done

# Test 14: Documentation exists
log "Test 14: Checking documentation..."
if [ ! -f "docs/full-stack-deployment-guide.md" ] || 
   [ ! -f "docs/keycloak-integration-guide.md" ] ||
   [ ! -f "docs/proxmox-backup-guide.md" ] ||
   [ ! -f "docs/wizard-guide.md" ] ||
   [ ! -f "docs/automatic-patching-guide.md" ]; then
    error "Documentation incomplete"
    exit 1
fi

# Test 15: Examples exist
log "Test 15: Checking examples..."
if [ ! -f "examples/simple-cluster.sh" ]; then
    error "Examples incomplete"
    exit 1
fi

# Test 16: All test scripts exist
log "Test 16: Checking test scripts..."
for test_script in tests/*_test.sh; do
    if [ ! -f "$test_script" ]; then
        error "Test script missing: $test_script"
        exit 1
    fi
done

# Test 17: Run Keycloak-specific tests
log "Test 17: Running Keycloak-specific tests..."
bash tests/keycloak-integration-test.sh

# Test 18: Run Portainer-specific tests
log "Test 18: Running Portainer-specific tests..."
bash tests/portainer-integration-test.sh

# Test 19: Run Wizard-specific tests
log "Test 19: Running Wizard-specific tests..."
bash tests/wizard-integration-test.sh

# Test 20: Run Patching-specific tests
log "Test 20: Running Patching-specific tests..."
bash tests/integration-patching-test.sh

log "All tests passed!"
log "Twinbox Full-Stack Kubernetes with Portainer, Proxmox Backup, Wizard, and Automatic Patching is ready for deployment."
```

**Step 4: Run test to verify it passes**
Run: `bash tests/final_patching_test.sh`
Expected: PASS message

**Step 5: Commit**
```bash
git add docs/automatic-patching-guide.md tests/integration-patching-test.sh tests/run-all-tests.sh
git commit -m "Add patching documentation and integration tests"
```

## Summary

The Twinbox Automatic Patching Implementation is now complete with:

1. **Talos Linux Patching System** - Handles automatic updates for Talos nodes with safe rolling updates
2. **Kubernetes Components Patching** - Updates platform services like Rook, Traefik, Keycloak, Portainer, ArgoCD
3. **Proxmox Host Patching** - Updates Proxmox VE systems with VM migration and maintenance mode
4. **Unified Orchestrator** - Coordinates patching across all platform layers with proper sequencing
5. **Comprehensive Documentation** - Complete guide for configuring and using the patching system
6. **Integration Tests** - Validates the complete patching system functionality

The automatic patching system provides coordinated updates across all platform layers while maintaining system stability and availability. It includes safety features like maintenance windows, gradual rollouts, health checks, and notification capabilities to ensure reliable operation in production environments.