#!/usr/bin/env bash
#
# Common utilities for Proxmox VM Manager
# Shared helper functions

set -eo pipefail

# ============================================================================
# YAML Processing
# ============================================================================

# Check if yq is available
ensure_yq() {
    if ! command -v yq &> /dev/null; then
        log_error "yq is required but not installed. Install with: pip install yq"
        return 1
    fi
    return 0
}

# Read YAML value safely
yq_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"

    ensure_yq || return 1

    local value
    value=$(yq eval --raw-output ".$key" "$file" 2>/dev/null || echo "null")

    if [[ "$value" == "null" || -z "$value" ]]; then
        if [[ -n "$default" ]]; then
            echo "$default"
        else
            return 1
        fi
    else
        echo "$value"
    fi
}

# Check if YAML key exists and is not null
yq_has_key() {
    local file="$1"
    local key="$2"

    ensure_yq || return 1

    local value
    value=$(yq eval --raw-output ".$key" "$file" 2>/dev/null || echo "null")
    [[ "$value" != "null" && -n "$value" ]]
}

# ============================================================================
# JSON Processing
# ============================================================================

# Pretty print JSON
json_pretty() {
    jq '.' 2>/dev/null || cat
}

# Extract value from JSON
json_get() {
    local json="$1"
    local jq_expr="$2"
    local default="${3:-}"

    local value
    value=$(echo "$json" | jq -r "$jq_expr" 2>/dev/null || echo "null")

    if [[ "$value" == "null" || -z "$value" ]]; then
        if [[ -n "$default" ]]; then
            echo "$default"
        else
            return 1
        fi
    else
        echo "$value"
    fi
}

# ============================================================================
# String Utilities
# ============================================================================

# Trim whitespace
trim() {
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Convert to lowercase
tolower() {
    tr '[:upper:]' '[:lower:]'
}

# Generate safe filename from string
safe_filename() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g'
}

# ============================================================================
# Array Utilities
# ============================================================================

# Join array elements with separator
join_by() {
    local IFS="$1"
    shift
    echo "$*"
}

# ============================================================================
# File Utilities
# ============================================================================

# Ensure directory exists
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || {
            log_error "Failed to create directory: $dir"
            return 1
        }
    fi
    return 0
}

# Create temporary file
temp_file() {
    local prefix="${1:-tmp}"
    mktemp "${prefix}.XXXXXX"
}

# ============================================================================
# Time Utilities
# ============================================================================

# Get timestamp in filename-friendly format
timestamp() {
    date +%Y%m%d-%H%M%S
}

# ISO 8601 timestamp
iso_timestamp() {
    date -Iseconds
}

# ============================================================================
# Confirmation Prompt
# ============================================================================

confirm() {
    local prompt="${1:-Are you sure?}"
    local default="${2:-n}"

    if [[ "${FORCE:-0}" == "1" ]]; then
        return 0
    fi

    local yn
    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n]: " yn
        [[ -z "$yn" || "$(echo "$yn" | tr '[:upper:]' '[:lower:]')" == "y" ]]
    else
        read -r -p "$prompt [y/N]: " yn
        [[ "$(echo "$yn" | tr '[:upper:]' '[:lower:]')" == "y" ]]
    fi
}

# ============================================================================
# Export
# ============================================================================

export -f ensure_yq yq_get yq_has_key
export -f json_pretty json_get
export -f trim tolower safe_filename
export -f join_by
export -f ensure_dir temp_file
export -f timestamp iso_timestamp
export -f confirm