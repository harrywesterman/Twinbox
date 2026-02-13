#!/usr/bin/env bash
#
# Twinbox Proxmox VM Manager
# Automated VM creation and management with plan-then-execute pattern
#
# Features:
# - Preflight validation
# - Plan generation (dry-run preview)
# - Safe execution with rollback
# - Asset management
# - Multiple VM profiles
# - Comprehensive logging

set -euo pipefail

# ============================================================================
# Configuration and Defaults
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly LIB_DIR="$SCRIPT_DIR/lib"
readonly TEMPLATE_DIR="$SCRIPT_DIR/templates"
readonly CONFIG_DIR="$SCRIPT_DIR/configs"
readonly LOG_DIR="$PROJECT_ROOT/logs"
readonly PLAN_DIR="$PROJECT_ROOT/plans"
readonly SNAPSHOT_DIR="$PROJECT_ROOT/snapshots"

# Default configuration
PROXMOX_HOST="${PROXMOX_HOST:-localhost}"
PROXMOX_PORT="${PROXMOX_PORT:-8006}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
PROXMOX_REALM="${PROXMOX_REALM:-pam}"

# VM defaults
DEFAULT_VM_CORES=2
DEFAULT_VM_MEMORY=4096
DEFAULT_DISK_SIZE="20G"
DEFAULT_STORAGE_POOL="local-lvm"
DEFAULT_NETWORK_BRIDGE="vmbr0"
DEFAULT_VLAN_ID=0
DEFAULT_NODE="pve"

# ISO storage
ISO_STORAGE="${ISO_STORAGE:-local}"
ISO_PATH="/var/lib/vz/template/iso"

# ============================================================================
# Logging
# ============================================================================

log() {
    local level="$1"
    local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOG_DIR/vm-manager.log"
}

log_info() {
    log "INFO" "$1"
}

log_warn() {
    log "WARN" "$1"
}

log_error() {
    log "ERROR" "$1" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log "DEBUG" "$1"
    fi
}

# ============================================================================
# Library Loading
# ============================================================================

load_library() {
    local lib_name="$1"
    local lib_file="$LIB_DIR/${lib_name}.sh"

    if [[ -f "$lib_file" ]]; then
        # shellcheck source=/dev/null
        source "$lib_file"
        log_debug "Loaded library: $lib_name"
    else
        log_error "Library not found: $lib_file"
        exit 1
    fi
}

# ============================================================================
# Initialization
# ============================================================================

initialize() {
    # Create required directories
    mkdir -p "$LOG_DIR" "$PLAN_DIR" "$SNAPSHOT_DIR" "$CONFIG_DIR"

    # Initialize log file
    echo "=== Twinbox Proxmox VM Manager ===" > "$LOG_DIR/vm-manager.log"
    echo "Started at: $(date -Iseconds)" >> "$LOG_DIR/vm-manager.log"
    echo "Host: $PROXMOX_HOST" >> "$LOG_DIR/vm-manager.log"
    echo "==================================" >> "$LOG_DIR/vm-manager.log"

    log_info "Initialized (log: $LOG_DIR/vm-manager.log)"
}

# ============================================================================
# Profile Management
# ============================================================================

list_profiles() {
    log_info "Listing available profiles..."

    local profiles_found=0

    echo "Available VM profiles:"
    echo ""

    # Check profiles directory
    if [[ -d "$CONFIG_DIR/profiles" ]]; then
        for profile in "$CONFIG_DIR/profiles"/*.yaml; do
            if [[ -f "$profile" ]]; then
                local profile_name
                profile_name=$(basename "$profile" .yaml)
                local description
                description=$(yq eval '# Description' "$profile" 2>/dev/null || echo "")
                if [[ -z "$description" || "$description" == "null" ]]; then
                    description="No description"
                fi
                printf "  %-30s %s\n" "$profile_name" "$description"
                ((profiles_found++))
            fi
        done
    fi

    # Check current directory
    if [[ -f "./vm-profiles.yaml" ]]; then
        echo "  local (./vm-profiles.yaml)"
        ((profiles_found++))
    fi

    if [[ $profiles_found -eq 0 ]]; then
        echo "  No profiles found."
        echo ""
        echo "Create profiles in: $CONFIG_DIR/profiles/"
        echo "Or use: ./vm-profiles.yaml in current directory"
    fi

    echo ""
    log_info "Found $profiles_found profile(s)"
}

find_profile() {
    local profile_name="$1"
    local profile_file=""

    # Check if it's a direct file path
    if [[ -f "$profile_name" ]]; then
        profile_file="$profile_name"
    # Check current directory
    elif [[ -f "./${profile_name}.yaml" ]]; then
        profile_file="./${profile_name}.yaml"
    elif [[ -f "./vm-profiles.yaml" ]]; then
        # Could be a profile in a multi-profile file
        profile_file="./vm-profiles.yaml"
    # Check profiles directory
    elif [[ -f "$CONFIG_DIR/profiles/${profile_name}.yaml" ]]; then
        profile_file="$CONFIG_DIR/profiles/${profile_name}.yaml"
    else
        log_error "Profile not found: $profile_name"
        return 1
    fi

    echo "$profile_file"
}

# ============================================================================
# Plan Generation Wrapper
# ============================================================================

generate_plan() {
    local profile="$1"
    local output_file="${2:-}"

    log_info "Generating plan for profile: $profile"

    # Find profile file
    local profile_file
    if ! profile_file=$(find_profile "$profile"); then
        return 1
    fi

    log_info "Using profile file: $profile_file"

    # Validate configuration
    if ! validate_config_yaml "$profile_file"; then
        log_error "Configuration validation failed"
        return 1
    fi

    # Generate plan
    if [[ -z "$output_file" ]]; then
        output_file="$PLAN_DIR/plan-$(timestamp).json"
    fi

    if generate_vm_plan "$profile_file" "$output_file"; then
        log_info "Plan generated: $output_file"
        echo "Plan generated: $output_file"
        echo ""
        render_plan "$output_file"
        return 0
    else
        log_error "Failed to generate plan"
        return 1
    fi
}

# ============================================================================
# Plan Execution Wrapper
# ============================================================================

execute_plan() {
    local plan_file="$1"

    log_info "Executing plan: $plan_file"

    # Validate plan
    if ! validate_plan "$plan_file"; then
        log_error "Plan validation failed"
        return 1
    fi

    # Determine execution mode
    local execute_mode="false"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "Dry-run mode enabled"
        execute_mode="false"
    else
        execute_mode="true"
    fi

    # Execute
    if execute_plan_internal "$plan_file" "$execute_mode"; then
        log_info "Plan execution completed successfully"
        return 0
    else
        log_error "Plan execution failed"
        return 1
    fi
}

# ============================================================================
# VM Information
# ============================================================================

list_vms() {
    log_info "Listing VMs..."

    pvesh cluster/resources --type vm | jq -r '.data[] | "\(.vmid) \(.name) \(.status) \(.node) \(.cpu // "0") cores, \(.mem // "0")MB"' || {
        log_error "Failed to list VMs"
        return 1
    }
}

get_vm_info() {
    local vmid="$1"

    log_info "Getting VM info: $vmid"

    if ! vm_exists "$vmid"; then
        log_error "VM $vmid does not exist"
        return 1
    fi

    echo "VM $vmid Configuration:"
    echo "========================="
    qm config "$vmid" || {
        log_error "Failed to get VM config"
        return 1
    }

    echo ""
    echo "VM $vmid Status:"
    echo "========================="
    qm status "$vmid" || {
        log_error "Failed to get VM status"
        return 1
    }
}

# ============================================================================
# Main Command Dispatcher
# ============================================================================

main() {
    local command="${1:-}"

    # Parse global options
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --verbose)
                DEBUG=1
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

    case "$command" in
        preflight)
            load_library "preflight"
            preflight_check
            ;;
        plan)
            load_library "planner"
            load_library "validator"
            load_library "assets"
            generate_plan "${2:-}" "${OUTPUT_FILE:-}"
            ;;
        apply)
            load_library "executor"
            load_library "rollback"
            execute_plan "${2:-}"
            ;;
        create)
            load_library "planner"
            load_library "executor"
            load_library "validator"
            load_library "assets"
            load_library "rollback"
            create_vm "${2:-}"
            ;;
        list-profiles)
            list_profiles
            ;;
        list-vms)
            load_library "adapter"
            list_vms
            ;;
        validate)
            load_library "validator"
            validate_config_file "${2:-}"
            ;;
        snapshot)
            load_library "rollback"
            create_vm_snapshot "${2:-}"
            ;;
        rollback)
            load_library "rollback"
            restore_vm_snapshot "${2:-}"
            ;;
        download-iso)
            load_library "assets"
            shift 2
            download_iso "$@"
            ;;
        list-isos)
            load_library "assets"
            shift 1
            list_storage_content "$@"
            ;;
        get-vm-info)
            load_library "adapter"
            shift 1
            get_vm_info "$@"
            ;;
        wait-for-ip)
            load_library "adapter"
            shift 1
            wait_for_ip "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            log_error "No command specified"
            show_help
            exit 1
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# ============================================================================
# Main Execution
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    initialize
    main "$@"
fi