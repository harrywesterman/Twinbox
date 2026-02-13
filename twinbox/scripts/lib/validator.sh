#!/usr/bin/env bash
#
# Configuration Validator - Validate VM configuration files and parameters
# Supports YAML configuration files and command-line parameters

set -eo pipefail

# ============================================================================
# Validation Functions
# ============================================================================

validate_vmid() {
    local vmid="$1"

    if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
        log_error "VMID must be a number"
        return 1
    fi

    if [[ $vmid -lt 100 || $vmid -gt 999999 ]]; then
        log_error "VMID must be between 100 and 999999"
        return 1
    fi

    # Check if VMID is already in use
    if vm_exists "$vmid"; then
        log_error "VMID $vmid is already in use"
        return 1
    fi

    return 0
}

validate_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "VM name cannot be empty"
        return 1
    fi

    if [[ ${#name} -lt 3 ]]; then
        log_error "VM name must be at least 3 characters"
        return 1
    fi

    # Check for invalid characters
    if [[ "$name" =~ [^a-zA-Z0-9._-] ]]; then
        log_error "VM name contains invalid characters (only a-z, A-Z, 0-9, ., _, - allowed)"
        return 1
    fi

    return 0
}

validate_cores() {
    local cores="$1"

    if [[ ! "$cores" =~ ^[0-9]+$ ]]; then
        log_error "CPU cores must be a number"
        return 1
    fi

    if [[ $cores -lt 1 ]]; then
        log_error "At least 1 CPU core is required"
        return 1
    fi

    # Check host CPU count
    local host_cores
    host_cores=$(nproc 2>/dev/null || echo 4)
    if [[ $cores -gt $host_cores ]]; then
        log_warn "Requested cores ($cores) exceeds host cores ($host_cores)"
    fi

    return 0
}

validate_memory() {
    local memory="$1"

    if [[ ! "$memory" =~ ^[0-9]+$ ]]; then
        log_error "Memory must be a number in MB"
        return 1
    fi

    if [[ $memory -lt 512 ]]; then
        log_error "At least 512 MB RAM is required"
        return 1
    fi

    # Check host memory
    local host_mem_mb
    host_mem_mb=$(grep -E '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}' || echo 4096)
    if [[ $memory -gt $host_mem_mb ]]; then
        log_error "Requested memory (${memory}MB) exceeds host memory (${host_mem_mb}MB)"
        return 1
    fi

    return 0
}

validate_disk_size() {
    local disk_size="$1"

    # Accept formats: 10G, 10GB, 10240M, 10240MB
    local size_num
    local size_unit

    if [[ "$disk_size" =~ ^([0-9]+)([GM][B]?)$ ]]; then
        size_num="${BASH_REMATCH[1]}"
        size_unit="${BASH_REMATCH[2]}"
    else
        log_error "Disk size must be in format like 20G, 20GB, 20480M, or 20480MB"
        return 1
    fi

    if [[ $size_num -lt 1 ]]; then
        log_error "Disk size must be greater than 0"
        return 1
    fi

    # Convert to GB for minimum check
    local size_gb
    if [[ "$size_unit" =~ ^[G] ]]; then
        size_gb=$size_num
    else
        size_gb=$((size_num / 1024))
    fi

    if [[ $size_gb -lt 10 ]]; then
        log_warn "Disk size less than 10GB may be too small for some workloads"
    fi

    return 0
}

validate_bridge() {
    local bridge="$1"

    if [[ -z "$bridge" ]]; then
        log_error "Network bridge is required"
        return 1
    fi

    # Check if bridge exists on Proxmox
    local node
    node=$(get_first_node)
    if ! pvesh nodes/"$node"/network | jq -r --arg bridge "$bridge" '.data[] | select(.iface == $bridge)' >/dev/null 2>&1; then
        log_warn "Bridge '$bridge' not found on Proxmox node $node"
    fi

    return 0
}

validate_storage() {
    local storage="$1"
    local storage_type="${2:-volume}"  # volume, iso, etc.

    local node
    node=$(get_first_node)

    if ! pvesh nodes/"$node"/storage | jq -r --arg storage "$storage" '.data[] | select(.storage == $storage)' >/dev/null 2>&1; then
        log_error "Storage '$storage' not found on Proxmox node $node"
        return 1
    fi

    # Check storage content type
    local storage_info
    storage_info=$(pvesh nodes/"$node"/storage | jq -r --arg storage "$storage" '.data[] | select(.storage == $storage)')
    local content_types
    content_types=$(echo "$storage_info" | jq -r '.content // ""')

    case "$storage_type" in
        iso)
            if [[ ! "$content_types" =~ iso ]]; then
                log_error "Storage '$storage' does not support ISO content"
                return 1
            fi
            ;;
        volume)
            if [[ ! "$content_types" =~ (images|rootdir) ]]; then
                log_error "Storage '$storage' does not support VM disk images"
                return 1
            fi
            ;;
    esac

    return 0
}

validate_iso_path() {
    local iso_path="$1"
    local storage_type="${2:-iso}"

    if [[ -z "$iso_path" ]]; then
        log_error "ISO path is required"
        return 1
    fi

    # Check if ISO exists in Proxmox storage
    local node
    node=$(get_first_node)
    local storage
    storage=$(echo "$iso_path" | cut -d: -f1)
    local iso_name
    iso_name=$(echo "$iso_path" | cut -d: -f2-)

    if ! storage_has_iso "$node" "$storage" "$iso_name"; then
        log_error "ISO not found: $iso_path"
        return 1
    fi

    return 0
}

# ============================================================================
# YAML Configuration Validation
# ============================================================================

validate_config_yaml() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi

    # Check if yq is available
    if ! command -v yq &> /dev/null; then
        log_error "yq (YAML processor) is required but not installed"
        return 1
    fi

    # Validate required fields
    local required_fields=("vmid" "name" "cores" "memory" "disk" "bridge" "storage")
    local missing_fields=()

    for field in "${required_fields[@]}"; do
        if ! yq eval ".$field" "$config_file" 2>/dev/null | grep -q "null"; then
            continue
        fi
        missing_fields+=("$field")
    done

    if [[ ${#missing_fields[@]} -gt 0 ]]; then
        log_error "Missing required fields in configuration: ${missing_fields[*]}"
        return 1
    fi

    # Validate field values
    local vmid
    vmid=$(yq eval '.vmid' "$config_file")
    validate_vmid "$vmid" || return 1

    local name
    name=$(yq eval '.name' "$config_file")
    validate_name "$name" || return 1

    local cores
    cores=$(yq eval '.cores' "$config_file")
    validate_cores "$cores" || return 1

    local memory
    memory=$(yq eval '.memory' "$config_file")
    validate_memory "$memory" || return 1

    local disk
    disk=$(yq eval '.disk' "$config_file")
    validate_disk_size "$disk" || return 1

    local bridge
    bridge=$(yq eval '.bridge' "$config_file")
    validate_bridge "$bridge" || return 1

    local storage
    storage=$(yq eval '.storage' "$config_file")
    validate_storage "$storage" || return 1

    # Optional ISO validation
    if yq eval '.iso_path' "$config_file" 2>/dev/null | grep -q "null"; then
        local iso_path
        iso_path=$(yq eval '.iso_path' "$config_file")
        if [[ -n "$iso_path" && "$iso_path" != "null" ]]; then
            validate_iso_path "$iso_path" || return 1
        fi
    fi

    log_info "Configuration validation passed: $config_file"
    return 0
}

# ============================================================================
# Main Validation Function
# ============================================================================

validate_config() {
    local config_source="$1"

    log_info "Validating configuration: $config_source"

    if [[ -f "$config_source" ]]; then
        # File-based validation
        if [[ "$config_source" =~ \.ya?ml$ ]]; then
            validate_config_yaml "$config_source"
        else
            log_error "Unsupported configuration file format: $config_source"
            return 1
        fi
    else
        # Assume it's a profile name
        local profile_file="$CONFIG_DIR/profiles/$config_source.yaml"
        if [[ -f "$profile_file" ]]; then
            validate_config_yaml "$profile_file"
        else
            log_error "Profile not found: $config_source (searched: $profile_file)"
            return 1
        fi
    fi
}

# Export functions
export -f validate_vmid validate_name validate_cores validate_memory
export -f validate_disk_size validate_bridge validate_storage validate_iso_path
export -f validate_config_yaml validate_config