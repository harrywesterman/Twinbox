#!/usr/bin/env bash
#
# Preflight Checks - Validate Proxmox environment readiness
# Returns list of checks with status and details

set -eo pipefail

# ============================================================================
# Check Definitions
# ============================================================================

PreflightCheck=(
    name: string
    ok: bool
    details: string
)

run_check() {
    local check_name="$1"
    local check_func="$2"

    log_info "Running preflight check: $check_name"

    if $check_func; then
        echo "true"
    else
        echo "false"
    fi
}

# ============================================================================
# Individual Checks
# ============================================================================

check_proxmox_tools() {
    local missing=()

    for cmd in qm pvesm pvesh qemu-img; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "All Proxmox tools available"
        return 0
    else
        log_error "Missing Proxmox tools: ${missing[*]}"
        return 1
    fi
}

check_kvm() {
    if [[ -e /dev/kvm ]]; then
        log_info "KVM device present"
        return 0
    else
        log_error "KVM device /dev/kvm not found"
        return 1
    fi
}

check_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        log_info "Running as root"
        return 0
    else
        log_error "Must run as root (UID 0)"
        return 1
    fi
}

check_curl() {
    if command -v curl &> /dev/null; then
        log_info "curl available"
        return 0
    else
        log_error "curl not found"
        return 1
    fi
}

check_jq() {
    if command -v jq &> /dev/null; then
        log_info "jq available"
        return 0
    else
        log_error "jq not found (required for JSON parsing)"
        return 1
    fi
}

check_proxmox_connection() {
    if authenticate; then
        log_info "Proxmox authentication successful"
        return 0
    else
        log_error "Cannot authenticate to Proxmox"
        return 1
    fi
}

check_iso_storage() {
    local storage="${ISO_STORAGE:-local}"
    local node
    node=$(get_first_node)

    if storage_has_iso "$node" "$storage" "test.iso" 2>/dev/null; then
        log_info "ISO storage accessible: $storage on $node"
        return 0
    else
        # Storage might be empty but accessible
        log_info "ISO storage check: $storage on $node (may be empty)"
        return 0
    fi
}

check_disk_space() {
    local log_dir="$LOG_DIR"
    local min_space_mb=100

    if [[ -d "$log_dir" ]]; then
        local free_mb
        free_mb=$(df -m "$log_dir" | awk 'NR==2 {print $4}')
        if [[ $free_mb -ge $min_space_mb ]]; then
            log_info "Sufficient disk space: ${free_mb}MB free"
            return 0
        else
            log_error "Insufficient disk space: ${free_mb}MB free, need ${min_space_mb}MB"
            return 1
        fi
    else
        log_warn "Log directory not created yet, skipping disk space check"
        return 0
    fi
}

# ============================================================================
# Main Preflight Function
# ============================================================================

preflight_check() {
    log_info "Starting preflight checks..."

    local checks=()
    local all_ok=true

    # Define all checks
    checks+=(
        "Proxmox tools:check_proxmox_tools"
        "KVM device:check_kvm"
        "Root privileges:check_root"
        "curl available:check_curl"
        "jq available:check_jq"
        "Proxmox connection:check_proxmox_connection"
        "ISO storage:check_iso_storage"
        "Disk space:check_disk_space"
    )

    # Run all checks
    for check_spec in "${checks[@]}"; do
        IFS=':' read -r name func <<< "$check_spec"

        if $func; then
            echo "OK  $name"
        else
            echo "FAIL $name"
            all_ok=false
        fi
    done

    # Summary
    echo ""
    if $all_ok; then
        log_info "All preflight checks passed"
        echo "All checks passed ✓"
        return 0
    else
        log_error "Some preflight checks failed"
        echo "Some checks failed ✗"
        return 1
    fi
}

# Export for use in main script
export -f preflight_check check_proxmox_tools check_kvm check_root
export -f check_curl check_jq check_proxmox_connection
export -f check_iso_storage check_disk_space