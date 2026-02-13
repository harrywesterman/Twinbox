# Twinbox Proxmox VM Manager

Automated VM creation and management for Proxmox VE with plan-then-execute pattern, comprehensive validation, and rollback capabilities.

## Features

- **Plan-Then-Execute**: Generate detailed execution plans before making changes
- **Dry-Run Support**: Preview all commands without affecting the system
- **Preflight Validation**: Comprehensive environment checks
- **Rollback Protection**: Automatic snapshots before execution
- **Profile-Based**: Reusable YAML configuration profiles
- **Asset Management**: ISO discovery and download support
- **Progress Tracking**: Real-time execution feedback
- **Comprehensive Logging**: Detailed execution logs for audit and debugging

## Architecture

```
proxmox-vm-manager.sh (main entry point)
├── lib/
│   ├── adapter.sh      # Proxmox API/CLI abstraction
│   ├── preflight.sh    # Environment validation
│   ├── validator.sh    # Configuration validation
│   ├── planner.sh      # Plan generation
│   ├── executor.sh     # Plan execution with rollback
│   ├── assets.sh       # ISO and asset management
│   └── rollback.sh     # Snapshot management
├── configs/
│   └── profiles/       # VM configuration profiles
├── logs/               # Execution logs
├── plans/              # Generated execution plans
└── snapshots/          # VM configuration snapshots
```

## Quick Start

### 1. Prerequisites

- Proxmox VE 7.0+ with root access
- `qm`, `pvesm`, `pvesh` CLI tools available
- `curl`, `jq`, `yq` (for YAML processing)
- Bash 4.0+

### 2. Check Environment

```bash
cd /path/to/twinbox
./scripts/proxmox-vm-manager.sh preflight
```

### 3. List Available Profiles

```bash
./scripts/proxmox-vm-manager.sh list-profiles
```

### 4. Create a VM (Interactive)

```bash
# Generate and review plan first
./scripts/proxmox-vm-manager.sh plan ubuntu-2204 --output ubuntu-plan.json

# Review the plan
./scripts/proxmox-vm-manager.sh apply ubuntu-plan.json --dry-run

# Execute the plan
./scripts/proxmox-vm-manager.sh apply ubuntu-plan.json
```

Or use the combined command:

```bash
./scripts/proxmox-vm-manager.sh create ubuntu-2204
```

## Commands

### Environment and Discovery

| Command | Description |
|---------|-------------|
| `preflight` | Check Proxmox environment readiness |
| `list-profiles` | List available VM configuration profiles |
| `list-vms` | List all VMs on the Proxmox cluster |
| `list-isos [storage]` | List ISOs available in storage |

### VM Creation

| Command | Description |
|---------|-------------|
| `plan <profile>` | Generate execution plan for a profile |
| `apply <plan-file>` | Execute a plan (use `--dry-run` to preview) |
| `create <profile>` | Combined plan + apply with confirmation |

### Validation

| Command | Description |
|---------|-------------|
| `validate <config>` | Validate a configuration file or profile |

### Asset Management

| Command | Description |
|---------|-------------|
| `download-iso <url> [storage]` | Download ISO to Proxmox storage |
| `list-isos [storage]` | List available ISOs |

### VM Operations

| Command | Description |
|---------|-------------|
| `snapshot <vmid>` | Create a snapshot of an existing VM |
| `rollback <vmid>` | Rollback VM to previous snapshot |
| `get-vm-info <vmid>` | Get detailed VM information |
| `wait-for-ip <vmid>` | Wait for VM to obtain IP address |

## Configuration Profiles

Profiles are YAML files defining VM configurations. Create custom profiles in:

- `scripts/configs/profiles/*.yaml` (project-wide)
- `./vm-profiles.yaml` (local to working directory)

### Profile Structure

```yaml
# Required fields
vmid: 900                    # VM ID (100-999999)
name: my-vm                 # VM name (min 3 chars)
cores: 2                    # CPU cores
memory: 4096                # RAM in MB
disk: 20G                   # Disk size (e.g., 20G, 100G)
bridge: vmbr0               # Network bridge
storage: local-lvm          # Storage pool

# Optional fields
iso_path: local:iso/ubuntu-22.04.iso  # Installation ISO
macos: sequoia                          # macOS version (for macOS VMs)
smbios_serial: ""                       # Custom SMBIOS serial
smbios_uuid: ""                         # Custom SMBIOS UUID
smbios_mlb: ""                          # Custom SMBIOS MLB
smbios_model: ""                        # Custom SMBIOS model
vlan_id: 0                              # VLAN tag (0 = none)
```

### Example Profiles

See `scripts/configs/profiles/` for examples:

- `ubuntu-2204.yaml` - Standard Ubuntu Linux server
- `talos-controlplane.yaml` - Talos Linux control plane node
- `talos-worker.yaml` - Talos Linux worker node
- `macos-sequoia.yaml` - macOS Sequoia VM

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXMOX_HOST` | `localhost` | Proxmox host address |
| `PROXMOX_PORT` | `8006` | Proxmox API port |
| `PROXMOX_USER` | `root@pam` | Proxmox username |
| `PROXMOX_PASSWORD` | *required* | Proxmox password |
| `PROXMOX_REALM` | `pam` | Authentication realm |
| `ISO_STORAGE` | `local` | Default storage for ISOs |
| `DEBUG` | `0` | Enable debug logging (set to 1) |
| `TIMEOUT` | `300` | Command timeout in seconds |
| `FORCE` | `0` | Skip confirmation prompts (set to 1) |

## Usage Examples

### Basic VM Creation

```bash
# Set credentials
export PROXMOX_PASSWORD="your-password"

# Create Ubuntu VM
./scripts/proxmox-vm-manager.sh create ubuntu-2204
```

### Dry-Run Preview

```bash
# Generate plan
./scripts/proxmox-vm-manager.sh plan ubuntu-2204 --output plan.json

# Preview without executing
./scripts/proxmox-vm-manager.sh apply plan.json --dry-run
```

### Custom Configuration

```bash
# Create custom profile file
cat > my-vm.yaml << EOF
vmid: 950
name: custom-vm
cores: 4
memory: 8192
disk: 50G
bridge: vmbr0
storage: local-lvm
iso_path: local:iso/debian-12.iso
EOF

# Validate and create
./scripts/proxmox-vm-manager.sh validate my-vm.yaml
./scripts/proxmox-vm-manager.sh create my-vm.yaml
```

### ISO Management

```bash
# List available ISOs
./scripts/proxmox-vm-manager.sh list-isos local

# Download ISO to Proxmox
./scripts/proxmox-vm-manager.sh download-iso \
  "https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-amd64.iso" \
  local
```

### VM Information and IP Discovery

```bash
# Get VM details
./scripts/proxmox-vm-manager.sh get-vm-info 900

# Wait for VM to get IP (useful after creation)
./scripts/proxmox-vm-manager.sh wait-for-ip 900
```

## Plan Format

Plans are JSON files containing:

```json
{
  "metadata": {
    "config_file": "/path/to/profile.yaml",
    "generated": "2025-02-12T14:20:00Z",
    "version": "1.0"
  },
  "steps": [
    {
      "title": "Create VM shell",
      "argv": ["qm", "create", "900", "--name", "my-vm", ...],
      "risk": "safe"
    },
    {
      "title": "Start VM",
      "argv": ["qm", "start", "900"],
      "risk": "action"
    }
  ]
}
```

## Safety Features

1. **Preflight Checks**: Validates environment before any operation
2. **Configuration Validation**: Ensures all parameters are valid
3. **Dry-Run Mode**: Preview commands without execution
4. **Automatic Snapshots**: Creates rollback points before execution
5. **Rollback on Failure**: Automatic restoration on execution errors
6. **VMID Conflict Detection**: Prevents using existing VMIDs
7. **Resource Validation**: Checks CPU/memory against host capacity

## Logging

All operations are logged to:

- **Main log**: `logs/vm-manager.log`
- **Execution logs**: `logs/executions/execute-<timestamp>.log`
- **Snapshots**: `snapshots/vm-<vmid>-<name>.conf`

## Troubleshooting

### Authentication Failures

Ensure `PROXMOX_PASSWORD` is set and the user has appropriate permissions:

```bash
export PROXMOX_PASSWORD="your-password"
./scripts/proxmox-vm-manager.sh preflight
```

### Missing Dependencies

Install required tools:

```bash
# On Proxmox host
apt-get update
apt-get install -y curl jq jq python3-yaml
```

### ISO Not Found

Verify ISO exists in Proxmox storage:

```bash
./scripts/proxmox-vm-manager.sh list-isos local
```

Or download directly:

```bash
./scripts/proxmox-vm-manager.sh download-iso <url> local
```

### Permission Errors

Run as root or with appropriate sudo privileges:

```bash
sudo ./scripts/proxmox-vm-manager.sh create ubuntu-2204
```

## Integration with Twinbox

This VM manager complements Twinbox's existing infrastructure:

- **Terraform**: Use for complex, repeatable infrastructure
- **Ansible**: Use for configuration management after VM creation
- **VM Manager**: Use for ad-hoc VM creation and testing

### Typical Workflow

1. Use VM Manager to create base VMs interactively
2. Convert successful configurations to Terraform modules
3. Use Ansible playbooks for configuration
4. Use VM Manager for one-off VMs or testing

## Advanced Usage

### Custom Callbacks

Override progress callbacks by defining functions before sourcing:

```bash
on_step_start() {
    local current="$1"
    local total="$2"
    local title="$3"
    # Custom progress display
    printf "\r[%3d/%3d] %s" "$current" "$total" "$title"
}

on_step_complete() {
    local current="$1"
    local total="$2"
    local title="$3"
    local ok="$4"
    if $ok; then
        echo " ✓"
    else
        echo " ✗"
    fi
}
```

### Batch VM Creation

```bash
#!/bin/bash
# Create multiple VMs from profiles

for profile in scripts/configs/profiles/*.yaml; do
    echo "Creating VM from: $profile"
    ./scripts/proxmox-vm-manager.sh create "$profile" || {
        echo "Failed to create VM from $profile"
        continue
    }
    echo "✓ Created VM from $profile"
done
```

## Contributing

When extending the VM manager:

1. Follow the library pattern (separate functions in `lib/`)
2. Use `log_*` functions for consistent logging
3. Export functions with `export -f` for library use
4. Add comprehensive error handling
5. Update this documentation

## License

Part of the Twinbox project. See LICENSE for details.