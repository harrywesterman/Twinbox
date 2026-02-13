#!/usr/bin/env bash
#
# Plan Generator - Creates execution plans for VM creation
# Uses plan-then-execute pattern with dry-run support

set -eo pipefail

# ============================================================================
# Plan Step JSON Creation
# ============================================================================

step_to_json() {
    local title="$1"
    shift
    local argv=("$@")
    local risk="${3:-safe}"

    # Escape special characters in argv
    local json_argv
    json_argv=$(printf '%s\n' "${argv[@]}" | jq -R . | jq -s .)

    jq -n \
        --arg title "$title" \
        --argjson argv "$json_argv" \
        --arg risk "$risk" \
        '{title: $title, argv: $argv, risk: $risk}'
}

# ============================================================================
# VM Plan Generation
# ============================================================================

generate_vm_plan() {
    local config_file="$1"
    local output_file="${2:-}"

    # Check dependencies
    if ! command -v yq &> /dev/null; then
        echo "ERROR: yq is required but not installed" >&2
        return 1
    fi

    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required but not installed" >&2
        return 1
    fi

    # Check if config file exists
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file" >&2
        return 1
    fi

    # Extract configuration values
    local vmid
    vmid=$(yq eval --raw-output '.vmid' "$config_file" 2>/dev/null || echo "")
    local name
    name=$(yq eval --raw-output '.name' "$config_file" 2>/dev/null || echo "")
    local cores
    cores=$(yq eval --raw-output '.cores' "$config_file" 2>/dev/null || echo "")
    local memory
    memory=$(yq eval --raw-output '.memory' "$config_file" 2>/dev/null || echo "")
    local disk
    disk=$(yq eval --raw-output '.disk' "$config_file" 2>/dev/null || echo "")
    local bridge
    bridge=$(yq eval --raw-output '.bridge' "$config_file" 2>/dev/null || echo "")
    local storage
    storage=$(yq eval --raw-output '.storage' "$config_file" 2>/dev/null || echo "")
    local iso_path
    iso_path=$(yq eval --raw-output '.iso_path' "$config_file" 2>/dev/null || echo "")
    local macos_version
    macos_version=$(yq eval --raw-output '.macos' "$config_file" 2>/dev/null || echo "")

    # Validate required fields
    if [[ -z "$vmid" || -z "$name" || -z "$cores" || -z "$memory" || -z "$disk" || -z "$bridge" || -z "$storage" ]]; then
        echo "ERROR: Missing required configuration fields" >&2
        return 1
    fi

    # Build plan steps
    local steps_json="[]"

    # Step 1: Create VM shell
    local create_args=(
        "qm" "create" "$vmid"
        "--name" "$name"
        "--ostype" "other"
        "--machine" "q35"
        "--bios" "ovmf"
        "--cores" "$cores"
        "--memory" "$memory"
        "--cpu" "host"
        "--net0" "virtio,bridge=$bridge"
    )
    steps_json=$(jq --argjson steps "$steps_json" '.steps + [$(step_to_json "Create VM shell" "${create_args[@]}")]' <<< '{}' --argjson steps "$steps_json")

    # Step 2: Apply macOS hardware profile (if macOS)
    if [[ -n "$macos_version" ]]; then
        local profile_args=(
            "qm" "set" "$vmid"
            "--args"
            "-device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc -smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu host,kvm=on,vendor=GenuineIntel,+kvm_pv_unhalt,+kvm_pv_eoi,+hypervisor,+invtsc"
            "--vga" "std"
            "--tablet" "1"
            "--scsihw" "virtio-scsi-pci"
        )
        steps_json=$(jq --argjson steps "$steps_json" '.steps + [$(step_to_json "Apply macOS hardware profile" "${profile_args[@]}")]' <<< '{}' --argjson steps "$steps_json")
    fi

    # Step 3: Set SMBIOS (if provided)
    local smbios_serial
    smbios_serial=$(yq eval --raw-output '.smbios_serial' "$config_file" 2>/dev/null || echo "")
    if [[ -n "$smbios_serial" && "$smbios_serial" != "null" ]]; then
        local smbios_uuid
        smbios_uuid=$(yq eval --raw-output '.smbios_uuid' "$config_file" 2>/dev/null || echo "")
        local smbios_mlb
        smbios_mlb=$(yq eval --raw-output '.smbios_mlb' "$config_file" 2>/dev/null || echo "")
        local smbios_value="uuid=$smbios_uuid,serial=$smbios_serial,mlb=$smbios_mlb"
        steps_json=$(jq --argjson steps "$steps_json" --arg value "$smbios_value" '.steps + [{"title": "Set SMBIOS", "argv": ["qm", "set", "'"$vmid"'", "--smbios1", $value], "risk": "safe"}]' <<< '{}' --argjson steps "$steps_json")
    fi

    # Step 4: Attach EFI and TPM
    local efi_args=(
        "qm" "set" "$vmid"
        "--efidisk0" "${storage}:0,efitype=4m,pre-enrolled-keys=0"
        "--tpmstate0" "${storage}:0,version=v2.0"
    )
    steps_json=$(jq --argjson steps "$steps_json" '.steps + [$(step_to_json "Attach EFI and TPM" "${efi_args[@]}")]' <<< '{}' --argjson steps "$steps_json")

    # Step 5: Create main disk
    local disk_args=(
        "qm" "set" "$vmid"
        "--sata0" "${storage}:${disk}"
    )
    steps_json=$(jq --argjson steps "$steps_json" '.steps + [$(step_to_json "Create main disk" "${disk_args[@]}")]' <<< '{}' --argjson steps "$steps_json")

    # Step 6: Attach ISO (if provided)
    if [[ -n "$iso_path" && "$iso_path" != "null" ]]; then
        local iso_args=(
            "qm" "set" "$vmid"
            "--ide2" "${iso_path},media=cdrom"
        )
        steps_json=$(jq --argjson steps "$steps_json" '.steps + [$(step_to_json "Attach installation ISO" "${iso_args[@]}")]' <<< '{}' --argjson steps "$steps_json")
    fi

    # Step 7: Set boot order
    local boot_order="order=ide2;ide3;sata0"
    if [[ -z "$iso_path" || "$iso_path" == "null" ]]; then
        boot_order="order=sata0"
    fi
    steps_json=$(jq --argjson steps "$steps_json" '.steps + [$(step_to_json "Set boot order" "qm" "set" "$vmid" "--boot" "$boot_order")]' <<< '{}' --argjson steps "$steps_json")

    # Step 8: Start VM
    steps_json=$(jq --argjson steps "$steps_json" '.steps + [$(step_to_json "Start VM" "qm" "start" "$vmid" "action")]' <<< '{}' --argjson steps "$steps_json")

    # Build final plan JSON
    local plan_json
    plan_json=$(jq -n \
        --argjson steps "$steps_json" \
        --arg config_file "$config_file" \
        --arg generated "$(date -Iseconds)" \
        '{metadata: {config_file: $config_file, generated: $generated, version: "1.0"}, steps: $steps}')

    # Output plan
    if [[ -n "$output_file" ]]; then
        echo "$plan_json" > "$output_file"
    else
        echo "$plan_json"
    fi

    return 0
}

# ============================================================================
# Plan Rendering (Human-readable)
# ============================================================================

render_plan() {
    local plan_file="$1"

    if [[ ! -f "$plan_file" ]]; then
        echo "ERROR: Plan file not found: $plan_file" >&2
        return 1
    fi

    local plan_json
    plan_json=$(cat "$plan_file")

    echo "=== VM Creation Plan ==="
    echo "Config: $(echo "$plan_json" | jq -r '.metadata.config_file')"
    echo "Generated: $(echo "$plan_json" | jq -r '.metadata.generated')"
    echo ""

    local total_steps
    total_steps=$(echo "$plan_json" | jq '.steps | length')

    echo "$total_steps steps:"
    echo ""

    local idx=1
    echo "$plan_json" | jq -r '.steps[] | "\($idx). \(.title)\n   \(.argv | join(" "))\n"' | while IFS= read -r line; do
        echo "$line"
        idx=$((idx + 1))
    done

    echo ""
    echo "Risk summary:"
    echo "$plan_json" | jq -r '.steps[] | select(.risk == "action") | "  - \(.title) (action)"'
}

# ============================================================================
# Plan Validation
# ============================================================================

validate_plan() {
    local plan_file="$1"

    if [[ ! -f "$plan_file" ]]; then
        echo "ERROR: Plan file not found: $plan_file" >&2
        return 1
    fi

    # Check plan structure
    if ! jq -e '.metadata and .steps' "$plan_file" &>/dev/null; then
        echo "ERROR: Invalid plan format: missing metadata or steps" >&2
        return 1
    fi

    # Check for required metadata
    local config_file
    config_file=$(jq -r '.metadata.config_file // empty' "$plan_file")
    if [[ -z "$config_file" || "$config_file" == "null" ]]; then
        echo "ERROR: Plan missing config_file in metadata" >&2
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file referenced in plan not found: $config_file" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# Exports
# ============================================================================

export -f generate_vm_plan render_plan validate_plan step_to_json