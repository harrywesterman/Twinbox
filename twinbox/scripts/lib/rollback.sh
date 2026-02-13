#!/usr/bin/env bash
#
# Rollback Management - Create and restore VM snapshots
# Provides safety net for VM creation and modification operations

set -eo pipefail

# ============================================================================
# Snapshot Management
# ============================================================================

create_vm_snapshot() {
    local vmid="$1"
    local snapshot_name="${2:-pre-apply-$(date +%Y%m%d-%H%M%S)}"

    if ! vm_exists "$vmid"; then
        log_error "Cannot create snapshot: VM $vmid does not exist"
        return 1
    fi

    log_info "Creating snapshot for VM $vmid: $snapshot_name"

    # Save VM configuration
    local snapshot_file="$SNAPSHOT_DIR/vm-${vmid}-${snapshot_name}.conf"
    mkdir -p "$SNAPSHOT_DIR"

    if qm config "$vmid" > "$snapshot_file" 2>/dev/null; then
        log_info "Snapshot saved: $snapshot_file"
        echo "$snapshot_file"
        return 0
    else
        log_error "Failed to create snapshot for VM $vmid"
        return 1
    fi
}

restore_vm_snapshot() {
    local vmid="$1"
    local snapshot_file="$2"

    if [[ ! -f "$snapshot_file" ]]; then
        log_error "Snapshot file not found: $snapshot_file"
        return 1
    fi

    log_warn "Restoring VM $vmid from snapshot: $snapshot_file"
    log_warn "This will stop and reconfigure the VM"

    # Check if VM exists and is running
    if vm_exists "$vmid"; then
        if qm status "$vmid" 2>/dev/null | grep -q "status: running"; then
            log_info "Stopping VM $vmid..."
            if ! qm stop "$vmid"; then
                log_error "Failed to stop VM $vmid"
                return 1
            fi
        fi
    fi

    # Apply snapshot configuration
    if qm restore "$vmid" "$snapshot_file"; then
        log_info "Restored VM $vmid from snapshot"
        return 0
    else
        log_error "Failed to restore VM $vmid"
        return 1
    fi
}

list_snapshots() {
    local vmid="${1:-}"

    if [[ -n "$vmid" ]]; then
        echo "Snapshots for VM $vmid:"
        ls -1t "$SNAPSHOT_DIR"/vm-${vmid}-*.conf 2>/dev/null | while read -r snap; do
            local size
            size=$(ls -lh "$snap" | awk '{print $5}')
            local date
            date=$(stat -c %y "$snap" 2>/dev/null || stat -f %Sm "$snap" 2>/dev/null || echo "unknown")
            echo "  $(basename "$snap") [$size] $date"
        done
    else
        echo "All snapshots:"
        ls -1t "$SNAPSHOT_DIR"/*.conf 2>/dev/null | while read -r snap; do
            local vmid_ext
            vmid_ext=$(basename "$snap" .conf)
            local size
            size=$(ls -lh "$snap" | awk '{print $5}')
            echo "  $vmid_ext [$size]"
        done
    fi
}

# ============================================================================
# Automatic Rollback on Failure
# ============================================================================

with_rollback() {
    local vmid="$1"
    local operation_name="$2"
    shift 2
    local operation_func=("$@")

    log_info "Starting operation with rollback: $operation_name (VM: $vmid)"

    # Create pre-operation snapshot
    local snapshot_file=""
    if vm_exists "$vmid"; then
        if ! snapshot_file=$(create_vm_snapshot "$vmid" "before-$operation_name-$(date +%Y%m%d-%H%M%S)"); then
            log_warn "Failed to create snapshot, proceeding without rollback protection"
        fi
    fi

    # Execute operation
    local result=0
    if "${operation_func[@]}"; then
        log_info "Operation completed successfully: $operation_name"

        # Cleanup snapshot on success
        if [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
            log_info "Cleaning up snapshot: $snapshot_file"
            rm -f "$snapshot_file"
        fi
    else
        result=$?
        log_error "Operation failed: $operation_name (exit code: $result)"

        # Attempt rollback if snapshot exists
        if [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
            log_warn "Attempting rollback..."
            if restore_vm_snapshot "$vmid" "$snapshot_file"; then
                log_info "Rollback successful"
            else
                log_error "Rollback failed - manual intervention required"
                echo "MANUAL ROLLBACK REQUIRED:"
                echo "  VMID: $vmid"
                echo "  Snapshot: $snapshot_file"
                echo "  To restore: qm restore $vmid $snapshot_file"
            fi
        fi
    fi

    return $result
}

# ============================================================================
# Cleanup Old Snapshots
# ============================================================================

cleanup_old_snapshots() {
    local keep_count="${1:-10}"
    local vmid="${2:-}"

    log_info "Cleaning up old snapshots (keeping $keep_count most recent)"

    if [[ -n "$vmid" ]]; then
        # Cleanup for specific VM
        local snapshots
        snapshots=$(ls -1t "$SNAPSHOT_DIR"/vm-${vmid}-*.conf 2>/dev/null)
        local count=0
        while IFS= read -r snap; do
            ((count++))
            if [[ $count -gt $keep_count ]]; then
                log_info "Removing old snapshot: $(basename "$snap")"
                rm -f "$snap"
            fi
        done <<< "$snapshots"
    else
        # Cleanup all snapshots
        local snapshots
        snapshots=$(ls -1t "$SNAPSHOT_DIR"/*.conf 2>/dev/null)
        local count=0
        while IFS= read -r snap; do
            ((count++))
            if [[ $count -gt $keep_count ]]; then
                log_info "Removing old snapshot: $(basename "$snap")"
                rm -f "$snap"
            fi
        done <<< "$snapshots"
    fi
}

# ============================================================================
# Rollback Hints and Diagnostics
# ============================================================================

get_rollback_hints() {
    local vmid="$1"
    local snapshot_file="$2"

    echo "Rollback Information:"
    echo "===================="
    echo "VMID: $vmid"
    echo "Snapshot: $snapshot_file"
    echo ""
    echo "To restore this snapshot:"
    echo "  qm stop $vmid"
    echo "  qm restore $vmid $snapshot_file"
    echo "  qm start $vmid"
    echo ""
    echo "To destroy the VM completely:"
    echo "  qm destroy $vmid --purge"
    echo ""
    echo "To list all snapshots:"
    echo "  ls -la $SNAPSHOT_DIR/vm-${vmid}-*.conf"
}

# Export functions
export -f create_vm_snapshot restore_vm_snapshot list_snapshots
export -f with_rollback cleanup_old_snapshots get_rollback_hints
export SNAPSHOT_DIR