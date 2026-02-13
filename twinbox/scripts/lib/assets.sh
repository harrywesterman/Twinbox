#!/usr/bin/env bash
#
# Asset Management - ISO download, storage management, and asset discovery
# Handles ISO files and other VM assets in Proxmox storage

set -eo pipefail

# ============================================================================
# ISO Download
# ============================================================================

download_iso() {
    local iso_url="$1"
    local storage="${2:-$ISO_STORAGE}"
    local node="${3:-$(get_first_node)}"

    if [[ -z "$iso_url" ]]; then
        log_error "ISO URL is required"
        return 1
    fi

    local iso_filename
    iso_filename=$(basename "$iso_url")

    log_info "Downloading ISO: $iso_filename to $storage on $node"

    # Check if ISO already exists
    if storage_has_iso "$node" "$storage" "$iso_filename"; then
        log_info "ISO already exists: $iso_filename in $storage"
        return 0
    fi

    # Download to temporary location
    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_iso="$temp_dir/$iso_filename"

    log_info "Downloading from: $iso_url"
    if ! curl -fL --progress-bar "$iso_url" -o "$temp_iso"; then
        log_error "Failed to download ISO"
        rm -rf "$temp_dir"
        return 1
    fi

    # Upload to Proxmox storage
    log_info "Uploading to Proxmox storage: $storage"
    if ! qm set "$node" --arg "storage=$storage" --arg "file=$temp_iso"; then
        log_error "Failed to upload ISO to Proxmox"
        rm -rf "$temp_dir"
        return 1
    fi

    # Cleanup
    rm -rf "$temp_dir"
    log_info "ISO uploaded successfully: $iso_filename"
    return 0
}

# ============================================================================
# Storage Management
# ============================================================================

list_storage_content() {
    local storage="${1:-$ISO_STORAGE}"
    local node="${2:-$(get_first_node)}"

    log_info "Listing storage content: $storage on $node"

    if pvesh nodes/"$node"/storage/"$storage"/content >/dev/null 2>&1; then
        pvesh nodes/"$node"/storage/"$storage"/content | jq -r '.data[] | "\(.volid) \(.size // "0") \(.content)"' || {
            log_error "Failed to list storage content"
            return 1
        }
    else
        log_error "Storage not found: $storage on $node"
        return 1
    fi
}

find_iso() {
    local pattern="$1"
    local storage="${2:-$ISO_STORAGE}"
    local node="${3:-$(get_first_node)}"

    # Convert shell pattern to regex
    local regex
    regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*/.*/g; s/\?/./g')

    pvesh nodes/"$node"/storage/"$storage"/content 2>/dev/null | \
        jq -r --arg regex "$regex" '.data[] | select(.volid | test($regex)) | .volid' | \
        head -1
}

# ============================================================================
# Asset Discovery
# ============================================================================

find_available_isos() {
    local storage="${1:-$ISO_STORAGE}"
    local node="${2:-$(get_first_node)}"

    log_info "Scanning for available ISOs in $storage on $node"

    pvesh nodes/"$node"/storage/"$storage"/content 2>/dev/null | \
        jq -r '.data[] | select(.content | contains("iso")) | .volid' | \
        sort
}

get_iso_info() {
    local iso_path="$1"
    local storage
    storage=$(echo "$iso_path" | cut -d: -f1)
    local iso_name
    iso_name=$(echo "$iso_path" | cut -d: -f2-)

    local node
    node=$(get_first_node)

    pvesh nodes/"$node"/storage/"$storage"/content | \
        jq -r --arg iso "$iso_name" '.data[] | select(.volid | contains($iso)) | "\(.volid) \(.size // "0") \(.content)"' | \
        head -1
}

# ============================================================================
# Asset Validation
# ============================================================================

validate_iso_exists() {
    local iso_path="$1"

    if [[ -z "$iso_path" ]]; then
        log_error "ISO path is required"
        return 1
    fi

    local storage
    storage=$(echo "$iso_path" | cut -d: -f1)
    local iso_name
    iso_name=$(echo "$iso_path" | cut -d: -f2-)

    if [[ -z "$storage" || -z "$iso_name" ]]; then
        log_error "Invalid ISO path format: $iso_path (expected storage:filename)"
        return 1
    fi

    local node
    node=$(get_first_node)

    if storage_has_iso "$node" "$storage" "$iso_name"; then
        log_info "ISO found: $iso_path"
        return 0
    else
        log_error "ISO not found: $iso_path"
        return 1
    fi
}

# ============================================================================
# Common ISO Patterns
# ============================================================================

COMMON_ISO_PATTERNS=(
    "*.iso"
    "*ubuntu*"
    "*centos*"
    "*debian*"
    "*talos*"
    "*windows*"
    "*opencore*"
    "*recovery*"
)

list_all_isos() {
    local storage="${1:-$ISO_STORAGE}"
    local node="${2:-$(get_first_node)}"

    echo "Available ISOs in $storage on $node:"
    echo ""

    for pattern in "${COMMON_ISO_PATTERNS[@]}"; do
        local matches
        matches=$(find_iso "$pattern" "$storage" "$node")
        if [[ -n "$matches" ]]; then
            echo "Pattern: $pattern"
            echo "$matches" | sed 's/^/  /'
            echo ""
        fi
    done
}

# Export functions
export -f download_iso list_storage_content find_iso find_available_isos
export -f get_iso_info validate_iso_exists list_all_isos
export ISO_STORAGE