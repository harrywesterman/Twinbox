# Proxmox VM Manager Integration Guide

This guide explains how to integrate the new Proxmox VM Manager with existing Twinbox infrastructure and workflows.

## Overview

The Proxmox VM Manager provides a modular, scriptable interface for VM creation and management that complements Twinbox's existing Terraform and Ansible components.

### Architecture Comparison

| Component | Purpose | When to Use |
|-----------|---------|-------------|
| **VM Manager** | Ad-hoc VM creation, testing, prototyping | One-off VMs, development, testing |
| **Terraform** | Infrastructure as Code, repeatable deployments | Production clusters, version-controlled infra |
| **Ansible** | Configuration management, app deployment | Post-VM setup, software installation |

## Installation

### Prerequisites

Ensure the following are installed on the Proxmox host:

```bash
# Required packages
apt-get update
apt-get install -y \
    curl \
    jq \
    python3-yaml \
    git \
    bash \
    coreutils

# Optional: for ISO downloads
apt-get install -y wget
```

### Setup

1. Clone or copy the scripts to your Twinbox project:

```bash
# The scripts are already in twinbox/scripts/
cd /path/to/twinbox
```

2. Make scripts executable:

```bash
chmod +x twinbox/scripts/proxmox-vm-manager.sh
chmod +x twinbox/scripts/test-vm-manager.sh
chmod +x twinbox/scripts/lib/*.sh
```

3. Test the installation:

```bash
./twinbox/scripts/test-vm-manager.sh
```

All tests should pass ✓.

4. Configure environment variables:

```bash
export PROXMOX_HOST="your-proxmox-host"
export PROXMOX_USER="root@pam"
export PROXMOX_PASSWORD="your-password"
# Optional: PROXMOX_PORT=8006, ISO_STORAGE=local, DEBUG=1
```

## Quick Start

### 1. Check Environment

```bash
./twinbox/scripts/proxmox-vm-manager.sh preflight
```

Expected output:
```
OK  qm available
OK  pvesm available
OK  pvesh available
OK  qemu-img available
OK  /dev/kvm present
OK  Root privileges
OK  curl available
OK  jq available
OK  Proxmox connection
OK  ISO storage
OK  Disk space

All checks passed ✓
```

### 2. List Available Profiles

```bash
./twinbox/scripts/proxmox-vm-manager.sh list-profiles
```

Output:
```
Available VM profiles:

  ubuntu-2204            Standard Ubuntu Linux server
  talos-controlplane     Talos Linux control plane node
  talos-worker           Talos Linux worker node
  macos-sequoia          macOS Sequoia VM
```

### 3. Create a Test VM

```bash
# Generate a plan first (dry-run)
./twinbox/scripts/proxmox-vm-manager.sh plan ubuntu-2204 --output test-plan.json

# Review the plan
./twinbox/scripts/proxmox-vm-manager.sh apply test-plan.json --dry-run

# Execute the plan
./twinbox/scripts/proxmox-vm-manager.sh apply test-plan.json
```

Or use the combined command:

```bash
./twinbox/scripts/proxmox-vm-manager.sh create ubuntu-2204
```

## Integration with Existing Twinbox Workflows

### Workflow 1: Prototyping → Production

1. **Prototype with VM Manager**
   ```bash
   # Test different configurations quickly
   ./twinbox/scripts/proxmox-vm-manager.sh create ubuntu-2204
   ./twinbox/scripts/proxmox-vm-manager.sh create talos-controlplane
   ```

2. **Validate Configuration**
   ```bash
   # SSH into the VM and verify settings
   ssh root@<vm-ip>
   # Check resources, network, etc.
   ```

3. **Convert to Terraform**
   - Extract the successful configuration from the plan
   - Add it to `twinbox/terraform/` as a new module or variable
   - Use Terraform for repeatable deployments

4. **Apply Ansible Configuration**
   ```bash
   # Use existing Ansible playbooks
   cd twinbox
   ansible-playbook -i inventory.ini ansible/playbook.yml
   ```

### Workflow 2: Development and Testing

1. **Create Development Environment**
   ```bash
   # Create a dev VM with custom profile
   cat > dev-vm.yaml << EOF
   vmid: 950
   name: dev-environment
   cores: 4
   memory: 8192
   disk: 50G
   bridge: vmbr0
   storage: local-lvm
   iso_path: local:iso/ubuntu-22.04.iso
   EOF

   ./twinbox/scripts/proxmox-vm-manager.sh create dev-vm.yaml
   ```

2. **Test Changes**
   - Install and configure software
   - Test configurations
   - Validate performance

3. **Snapshot for Rollback**
   ```bash
   ./twinbox/scripts/proxmox-vm-manager.sh snapshot 950
   ```

4. **Clean Up**
   ```bash
   # Destroy VM when done
   qm destroy 950 --purge
   ```

### Workflow 3: Multi-Node Cluster Setup

1. **Create Control Plane**
   ```bash
   # Create first control plane node
   ./twinbox/scripts/proxmox-vm-manager.sh create talos-controlplane
   ```

2. **Get VM IP**
   ```bash
   ./twinbox/scripts/proxmox-vm-manager.sh wait-for-ip 910
   ```

3. **Bootstrap Talos Cluster**
   ```bash
   # Use existing Twinbox Talos scripts
   ./twinbox/scripts/deploy-talos-cluster.sh
   ```

4. **Add Worker Nodes**
   ```bash
   # Create additional worker VMs
   ./twinbox/scripts/proxmox-vm-manager.sh create talos-worker
   ./twinbox/scripts/proxmox-vm-manager.sh create talos-worker
   ```

5. **Join to Cluster**
   - Use Talos configuration to join workers to the cluster
   - Continue with standard Twinbox deployment

## Profile Management

### Creating Custom Profiles

Create a new YAML profile in `twinbox/scripts/configs/profiles/`:

```yaml
# my-custom-vm.yaml
vmid: 960                    # Required: VM ID (100-999999)
name: my-custom-vm          # Required: VM name (min 3 chars)
cores: 4                    # Required: CPU cores
memory: 8192                # Required: RAM in MB
disk: 40G                   # Required: Disk size (e.g., 20G, 100G)
bridge: vmbr0               # Required: Network bridge
storage: local-lvm          # Required: Storage pool

# Optional fields:
iso_path: local:iso/custom.iso  # Installation ISO
macos: sequoia                  # macOS version (for macOS VMs)
smbios_serial: ""               # Custom SMBIOS serial
smbios_uuid: ""                 # Custom SMBIOS UUID
smbios_mlb: ""                  # Custom SMBIOS MLB
smbios_model: ""                # Custom SMBIOS model
vlan_id: 0                      # VLAN tag (0 = none)
```

### Profile Validation

```bash
# Validate a profile before use
./twinbox/scripts/proxmox-vm-manager.sh validate my-custom-vm.yaml
```

### Profile Inheritance

You can create base profiles and extend them:

```yaml
# base-ubuntu.yaml
vmid: 900
name: base-ubuntu
cores: 2
memory: 4096
disk: 20G
bridge: vmbr0
storage: local-lvm

# dev-ubuntu.yaml (extends base)
# Use yq to merge or manually copy and modify
```

## Advanced Usage

### ISO Management

```bash
# List available ISOs
./twinbox/scripts/proxmox-vm-manager.sh list-isos local

# Download ISO directly to Proxmox
./twinbox/scripts/proxmox-vm-manager.sh download-iso \
  "https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-amd64.iso" \
  local
```

### VM Information

```bash
# Get detailed VM configuration
./twinbox/scripts/proxmox-vm-manager.sh get-vm-info 900

# Wait for VM to obtain IP (useful in scripts)
ip=$(./twinbox/scripts/proxmox-vm-manager.sh wait-for-ip 900)
echo "VM IP: $ip"
```

### Rollback and Snapshots

```bash
# Create manual snapshot
./twinbox/scripts/proxmox-vm-manager.sh snapshot 900

# List snapshots
./twinbox/scripts/proxmox-vm-manager.sh rollback 900
# (This will show rollback instructions)
```

## Environment Variables

Configure these in your shell or `.env` file:

```bash
# Required
export PROXMOX_PASSWORD="your-password"

# Optional (defaults shown)
export PROXMOX_HOST="localhost"
export PROXMOX_PORT="8006"
export PROXMOX_USER="root@pam"
export PROXMOX_REALM="pam"
export ISO_STORAGE="local"
export DEBUG="0"  # Set to "1" for debug logging
export FORCE="0"  # Set to "1" to skip confirmations
```

## Troubleshooting

### Authentication Failures

```bash
# Test authentication
./twinbox/scripts/proxmox-vm-manager.sh preflight

# Ensure PROXMOX_PASSWORD is set
echo "PROXMOX_PASSWORD=$PROXMOX_PASSWORD"  # Should not be empty
```

### Missing Dependencies

```bash
# Check required tools
which qm pvesm pvesh jq curl yq

# Install missing tools on Proxmox
apt-get install -y jq python3-yaml curl
```

### Plan Generation Fails

```bash
# Ensure yq is available
yq --version

# Validate profile syntax
yq eval '.vmid' twinbox/scripts/configs/profiles/ubuntu-2204.yaml
```

### Execution Fails

Check logs:

```bash
# Main log
tail -f logs/vm-manager.log

# Execution logs
ls -lat logs/executions/
tail -f logs/executions/execute-<timestamp>.log
```

## Best Practices

1. **Always dry-run first**: Use `--dry-run` or review plans before execution
2. **Use profiles**: Store configurations in YAML for reusability
3. **Version control**: Keep profiles in git, but never commit passwords
4. **Snapshot before changes**: Use `snapshot` command before risky operations
5. **Monitor logs**: Check `logs/vm-manager.log` for audit trail
6. **Validate environment**: Run `preflight` regularly, especially after updates
7. **Use appropriate VMIDs**: Reserve ranges for different purposes:
   - 900-999: Development/test VMs
   - 1000-1999: Production VMs
   - 2000+: Temporary VMs

## Performance Tips

1. **Disk I/O**: Use SSD/NVMe storage for better VM performance
2. **Memory**: Don't overcommit host memory
3. **CPU**: Pin VMs to specific cores if needed (advanced)
4. **Network**: Use virtio drivers for best network performance
5. **Storage**: Use `thin-provision` for dynamic disk allocation

## Security Considerations

1. **Run as root**: VM operations require root privileges
2. **Password management**: Use environment variables, not hardcoded
3. **Network isolation**: Use VLANs for multi-tenant setups
4. **Storage permissions**: Ensure proper access controls on storage pools
5. **API access**: Consider using API tokens instead of passwords

## Comparison with osx-proxmox-next

| Feature | osx-proxmox-next | Twinbox VM Manager |
|---------|------------------|-------------------|
| **Primary Use** | macOS VMs only | All VM types |
| **Interface** | TUI + CLI | CLI only |
| **Configuration** | Interactive wizard | YAML profiles |
| **Plan Generation** | Yes | Yes |
| **Dry-Run** | Yes | Yes |
| **Rollback** | Snapshots | Snapshots |
| **Asset Download** | Auto-download | Manual/auto |
| **Language** | Python | Bash |
| **Dependencies** | Python, textual | Bash, jq, yq |
| **Integration** | Standalone | Twinbox-native |

## Future Enhancements

Potential improvements for the VM Manager:

1. **Template cloning**: Support for cloning from templates (like Terraform)
2. **Cloud-init integration**: Better cloud-init support for Linux VMs
3. **Network bonding**: Support for bonded network interfaces
4. **GPU passthrough**: Simplified GPU passthrough configuration
5. **Live migration**: Support for live VM migration
6. **Backup integration**: Integration with Proxmox backup server
7. **Metrics collection**: Automatic performance metrics
8. **Web interface**: Optional web UI for management

## Support

For issues or questions:

1. Check the documentation: `twinbox/scripts/PROXMOX-VM-MANAGER.md`
2. Run tests: `./twinbox/scripts/test-vm-manager.sh`
3. Check logs: `logs/vm-manager.log` and `logs/executions/`
4. Review plan files for syntax errors
5. Ensure all prerequisites are installed

## Contributing

When extending the VM Manager:

1. Follow the modular library structure in `lib/`
2. Use `log_*` functions for consistent logging
3. Export functions with `export -f` for library use
4. Add comprehensive error handling
5. Update documentation
6. Add tests to `test-vm-manager.sh`