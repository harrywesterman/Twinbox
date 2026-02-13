#!/usr/bin/env bash
#
# Proxmox Adapter - Low-level Proxmox API interactions
# Provides a clean interface to Proxmox CLI tools and API

set -eo pipefail

# ============================================================================
# Authentication
# ============================================================================

authenticate() {
    if [[ -z "$PROXMOX_PASSWORD" ]]; then
        log_error "PROXMOX_PASSWORD environment variable must be set"
        return 1
    fi

    local auth_response
    auth_response=$(curl -k -s -d "username=$PROXMOX_USER&password=$PROXMOX_PASSWORD" \
        "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/access/ticket") || {
        log_error "Failed to connect to Proxmox API"
        return 1
    }

    TOKEN=$(echo "$auth_response" | jq -r '.data.ticket')
    CSRF_TOKEN=$(echo "$auth_response" | jq -r '.data.CSRFPreventionToken')

    if [[ "$TOKEN" == "null" || "$CSRF_TOKEN" == "null" ]]; then
        log_error "Authentication failed: $(echo "$auth_response" | jq -r '.errors // empty')"
        return 1
    fi

    log_debug "Authenticated successfully"
    return 0
}

# ============================================================================
# Command Execution
# ============================================================================

CommandResult=(
    ok: bool
    returncode: int
    output: str
)

run_command() {
    local argv=("$@")
    local timeout="${TIMEOUT:-300}"

    log_debug "Executing: ${argv[*]}"

    if [[ $# -eq 0 ]]; then
        log_error "run_command called with no arguments"
        return 1
    fi

    local result
    if result=$(timeout "$timeout" "${argv[@]}" 2>&1); then
        local returncode=$?
        if [[ $returncode -eq 0 ]]; then
            echo "$result"
            return 0
        else
            log_error "Command failed with exit code $returncode: ${argv[*]}"
            echo "$result" >&2
            return $returncode
        fi
    else
        local timeout_exit=$?
        if [[ $timeout_exit -eq 124 ]]; then
            log_error "Command timed out after ${timeout}s: ${argv[*]}"
        else
            log_error "Command failed: ${argv[*]}"
        fi
        return $timeout_exit
    fi
}

# ============================================================================
# Proxmox CLI Wrappers
# ============================================================================

qm() {
    run_command qm "$@"
}

pvesm() {
    run_command pvesm "$@"
}

pvesh() {
    authenticate
    run_command curl -k -s -H "Authorization: PVEAuthCookie $TOKEN" \
        -H "CSRFPreventionToken: $CSRF_TOKEN" \
        "https://$PROXMOX_HOST:$PROXMOX_PORT/api2/json/$@"
}

# ============================================================================
# VM Operations
# ============================================================================

get_vm_config() {
    local vmid="$1"
    local node="${2:-$(get_first_node)}"

    qm config "$vmid" 2>/dev/null || {
        log_error "VM $vmid not found or inaccessible"
        return 1
    }
}

get_vm_status() {
    local vmid="$1"
    local node="${2:-$(get_first_node)}"

    qm status "$vmid" 2>/dev/null || return 1
}

vm_exists() {
    local vmid="$1"
    if qm status "$vmid" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

create_vm_shell() {
    local vmid="$1"
    local name="$2"
    local cores="$3"
    local memory="$4"
    local net0="$5"
    local ostype="${6:-other}"
    local machine="${7:-q35}"
    local bios="${8:-ovmf}"

    log_info "Creating VM shell: vmid=$vmid, name=$name, cores=$cores, memory=${memory}MB"

    qm create "$vmid" \
        --name "$name" \
        --ostype "$ostype" \
        --machine "$machine" \
        --bios "$bios" \
        --cores "$cores" \
        --memory "$memory" \
        --cpu "host" \
        --net0 "$net0" || {
        log_error "Failed to create VM $vmid"
        return 1
    }

    log_info "VM $vmid created successfully"
}

apply_macos_profile() {
    local vmid="$1"

    qm set "$vmid" \
        --args "-device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc -smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu host,kvm=on,vendor=GenuineIntel,+kvm_pv_unhalt,+kvm_pv_eoi,+hypervisor,+invtsc" \
        --vga "std" \
        --tablet "1" \
        --scsihw "virtio-scsi-pci" || {
        log_error "Failed to apply macOS hardware profile to VM $vmid"
        return 1
    }

    log_info "Applied macOS hardware profile to VM $vmid"
}

set_smbios() {
    local vmid="$1"
    local smbios_value="$2"

    qm set "$vmid" --smbios1 "$smbios_value" || {
        log_error "Failed to set SMBIOS for VM $vmid"
        return 1
    }

    log_info "Set SMBIOS for VM $vmid"
}

attach_efi_tpm() {
    local vmid="$1"
    local storage="$2"

    qm set "$vmid" \
        --efidisk0 "${storage}:0,efitype=4m,pre-enrolled-keys=0" \
        --tpmstate0 "${storage}:0,version=v2.0" || {
        log_error "Failed to attach EFI and TPM to VM $vmid"
        return 1
    }

    log_info "Attached EFI and TPM to VM $vmid"
}

create_disk() {
    local vmid="$1"
    local storage="$2"
    local disk_size="$3"

    qm set "$vmid" --sata0 "${storage}:${disk_size}" || {
        log_error "Failed to create disk for VM $vmid"
        return 1
    }

    log_info "Created disk for VM $vmid: ${storage}:${disk_size}"
}

attach_iso() {
    local vmid="$1"
    local storage="$2"
    local iso_path="$3"
    local ide_slot="${4:-2}"

    qm set "$vmid" --ide"$ide_slot" "${storage}:${iso_path},media=cdrom" || {
        log_error "Failed to attach ISO to VM $vmid"
        return 1
    }

    log_info "Attached ISO to VM $vmid: ${storage}:${iso_path}"
}

set_boot_order() {
    local vmid="$1"
    local order="$2"

    qm set "$vmid" --boot "$order" || {
        log_error "Failed to set boot order for VM $vmid"
        return 1
    }

    log_info "Set boot order for VM $vmid: $order"
}

start_vm() {
    local vmid="$1"

    qm start "$vmid" || {
        log_error "Failed to start VM $vmid"
        return 1
    }

    log_info "Started VM $vmid"
}

stop_vm() {
    local vmid="$1"

    qm stop "$vmid" || {
        log_error "Failed to stop VM $vmid"
        return 1
    }

    log_info "Stopped VM $vmid"
}

# ============================================================================
# Node and Storage Queries
# ============================================================================

get_first_node() {
    pvesh nodes | jq -r '.data[].node' | head -1
}

get_node_name() {
    local vmid="$1"

    local vm_config
    vm_config=$(qm config "$vmid" 2>/dev/null) || {
        echo "$(get_first_node)"
        return 0
    }

    local node
    node=$(echo "$vm_config" | grep '^node:' | cut -d' ' -f2- || true)

    if [[ -n "$node" ]]; then
        echo "$node"
    else
        get_first_node
    fi
}

list_storage() {
    local node="${1:-$(get_first_node)}"
    local storage_pool="${2:-$ISO_STORAGE}"

    pvesh nodes/"$node"/storage/"$storage_pool"/content | jq -r '.data[] | "\(.volid) \(.size // "0") \(.content)"'
}

storage_has_iso() {
    local node="$1"
    local storage="$2"
    local iso_name="$3"

    local exists
    exists=$(pvesh nodes/"$node"/storage/"$storage"/content | jq -r --arg iso "$iso_name" '.data[] | select(.volid | contains($iso))') || {
        return 1
    }

    [[ -n "$exists" ]]
}

# ============================================================================
# VM IP Address Discovery
# ============================================================================

get_vm_ip() {
    local vmid="$1"
    local timeout="${2:-300}"
    local counter=0

    log_info "Waiting for VM $vmid to obtain IP address (timeout: ${timeout}s)..."

    while [[ $counter -lt $timeout ]]; do
        local node
        node=$(get_node_name "$vmid")

        local agent_status
        agent_status=$(pvesh nodes/"$node"/qemu/"$vmid"/agent/status 2>/dev/null) || {
            sleep 10
            ((counter += 10))
            continue
        }

        if [[ $(echo "$agent_status" | jq -r '.data.result') == "active" ]]; then
            local network_info
            network_info=$(pvesh nodes/"$node"/qemu/"$vmid"/agent/network-get-interfaces 2>/dev/null) || {
                sleep 10
                ((counter += 10))
                continue
            }

            local ip_address
            ip_address=$(echo "$network_info" | jq -r '.data.result.interfaces[] |
                select(.name != "lo" and (.name | startswith("eth") or startswith("ens"))) |
                .ip-addresses[]? |
                select(.["ip-address-type"] == "ipv4") |
                .["ip-address"]' | head -1)

            if [[ -n "$ip_address" && "$ip_address" != "null" ]]; then
                echo "$ip_address"
                return 0
            fi
        fi

        sleep 10
        ((counter += 10))
    done

    log_error "Timeout waiting for VM $vmid to obtain IP address"
    return 1
}

# ============================================================================
# Snapshot Management
# ============================================================================

create_snapshot() {
    local vmid="$1"
    local snapshot_name="${2:-pre-apply-$(date +%Y%m%d-%H%M%S)}"

    if ! vm_exists "$vmid"; then
        log_error "Cannot create snapshot: VM $vmid does not exist"
        return 1
    fi

    # Save VM config
    local snapshot_file="$SNAPSHOT_DIR/vm-${vmid}-${snapshot_name}.conf"
    mkdir -p "$SNAPSHOT_DIR"

    if qm config "$vmid" > "$snapshot_file" 2>/dev/null; then
        log_info "Created snapshot: $snapshot_file"
        echo "$snapshot_file"
    else
        log_error "Failed to create snapshot for VM $vmid"
        return 1
    fi
}

restore_snapshot() {
    local vmid="$1"
    local snapshot_file="$2"

    if [[ ! -f "$snapshot_file" ]]; then
        log_error "Snapshot file not found: $snapshot_file"
        return 1
    fi

    log_warn "Restoring VM $vmid from snapshot: $snapshot_file"
    log_warn "This will stop and reconfigure the VM"

    # Stop VM if running
    if qm status "$vmid" | grep -q "status: running"; then
        qm stop "$vmid"
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

# ============================================================================
# Utility Functions
# ============================================================================

get_next_vmid() {
    local start="${1:-100}"
    local end="${2:-999999}"

    for ((vmid=start; vmid<=end; vmid++)); do
        if ! vm_exists "$vmid"; then
            echo "$vmid"
            return 0
        fi
    done

    log_error "No available VMID found in range $start-$end"
    return 1
}

get_vm_by_name() {
    local name="$1"

    pvesh cluster/resources --type vm | jq -r --arg name "$name" '.data[] | select(.name == $name) | .vmid' | head -1
}

export -f authenticate run_command qm pvesm pvesh
export -f get_first_node get_node_name
export -f vm_exists create_vm_shell apply_macos_profile
export -f set_smbios attach_efi_tpm create_disk attach_iso set_boot_order start_vm
export -f get_vm_ip create_snapshot restore_snapshot
export -f get_next_vmid get_vm_by_name list_storage storage_has_iso