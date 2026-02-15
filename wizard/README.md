# Twinbox Setup Wizard

The Twinbox Setup Wizard is a standalone bash script that creates a dedicated management VM on Proxmox VE with Twinbox pre-configured and ready to deploy Kubernetes clusters.

## Quick Start

Run the wizard directly on your Proxmox host:

```bash
cd /path/to/twinbox
bash wizard/setup-wizard.sh
```

Or download and run directly:

```bash
bash <(curl -s https://raw.githubusercontent.com/your-org/twinbox/main/wizard/setup-wizard.sh)
```

## What It Does

The wizard automates the following steps:

1. **Validates Proxmox environment** - Checks for required commands (`qm`, `pvesh`)
2. **Prompts for configuration** - Cluster name, VM resources, node selection
3. **Checks resources** - Validates available RAM and disk space
4. **Creates Twinbox user** - `twinbox@pve` with random password
5. **Creates resource pool** - `twinbox-<cluster-name>` for organizing resources
6. **Grants permissions** - Gives `twinbox@pve` necessary VM management rights
7. **Generates API token** - For programmatic access to Proxmox API
8. **Downloads Ubuntu Cloud image** - If not already present in `/var/lib/vz/template/iso`
9. **Creates management VM** - With specified CPU, RAM, and disk
10. **Configures cloud-init** - Installs Docker, Docker Compose, and Twinbox
11. **Starts VM** - Boots the management VM and waits for IP
12. **Displays next steps** - Shows IP and instructions for completing setup

## Prerequisites

### On Proxmox Host

- **Proxmox VE 7.x or 8.x**
- **Root access** - The script must run as root
- **Internet access** - To download Ubuntu Cloud image and Twinbox repository
- **Sufficient resources** - At least 2 CPU cores, 4GB RAM, 20GB disk for the management VM
- **Storage** - A Proxmox storage (default: `local-lvm`) with enough free space
- **Network bridge** - A bridge interface (default: `vmbr0`) for VM networking

### Required Commands

The following commands must be available on the Proxmox host:

- `qm` - Proxmox VM management
- `pvesh` - Proxmox API shell
- `pveum` - Proxmox user management (optional fallback)
- `curl` - Download files
- `openssl` - Generate random passwords
- `jq` - JSON processing (for token extraction)
- `ping`, `arp` - Network discovery

If any are missing, the wizard will attempt to install `curl` and `jq` via `apt`, but most are standard on Proxmox.

## Usage

### Interactive Mode

Simply run the script and follow the prompts:

```bash
./wizard/setup-wizard.sh
```

#### Prompts

1. **Cluster name?**
   - Default: `twinbox-$(hostname)`
   - Used for resource pool: `twinbox-<cluster-name>`
   - Used for VM name: `twinbox-mgmt-<cluster-name>`
   - Must be alphanumeric (letters, numbers, underscores, hyphens)

2. **Management VM CPU?**
   - Default: `2`
   - Number of virtual CPU cores
   - Minimum: 1

3. **Management VM RAM (GB)?**
   - Default: `4`
   - RAM in gigabytes
   - Minimum: 2

4. **Management VM disk (GB)?**
   - Default: `32`
   - Disk size in gigabytes
   - Minimum: 20

5. **Proxmox node to use?**
   - Default: Auto-select node with lowest load
   - Shows a list of available nodes if multiple exist
   - Enter number to select, or press Enter for auto

### Non-Interactive Mode

You can also run the wizard non-interactively by setting environment variables:

```bash
export CLUSTER_NAME="mycluster"
export CPU_CORES=2
export RAM_GB=4
export DISK_GB=32
export SELECTED_NODE="pve-node1"
# export SKIP_RESOURCE_CHECK=1  # Skip resource check

./wizard/setup-wizard.sh
```

## Configuration Files

### Cloud-Init Template

The wizard uses a cloud-init configuration template at `wizard/cloud-init.yml` to set up the management VM. You can customize this file before running the wizard to:

- Install additional packages
- Configure different users or groups
- Change setup scripts
- Add additional configuration files

The template supports dynamic substitutions for `DB_PASSWORD` and `SECRET_KEY` which are generated automatically by the wizard.

### Systemd Service

The systemd service file `manager/init/twinbox.service` is copied to the management VM during cloud-init. This service:

- Manages the Twinbox Docker Compose application
- Starts on boot
- Restarts on failure
- Can be controlled with `systemctl` commands

After setup, you can manage Twinbox on the management VM with:

```bash
sudo systemctl status twinbox
sudo systemctl restart twinbox
sudo systemctl stop twinbox
sudo journalctl -u twinbox -f
```

## What Gets Created

### On Proxmox

- **User**: `twinbox@pve` with random password
- **Resource Pool**: `twinbox-<cluster-name>`
- **ACL**: Permissions for `twinbox@pve` on the pool
- **API Token**: For programmatic access (name and secret saved to `/tmp`)
- **VM**: `twinbox-mgmt-<cloud-init>` with Ubuntu Cloud image

### On Management VM

- **User**: `twinbox` (UID 999, GID 999)
- **Group**: `twinbox`
- **Directorys**:
  - `/opt/twinbox` - Repository and application
  - `/opt/twinbox/config` - Configuration files
  - `/opt/twinbox/logs` - Application logs
- **Files**:
  - `/opt/twinbox/docker-compose.yml` - Docker Compose configuration
  - `/opt/twinbox/.env` - Environment variables with generated secrets
  - `/opt/twinbox/config/proxmox-creds.yaml` - Proxmox API credentials
  - `/etc/systemd/system/twinbox.service` - Systemd service unit

## Security Notes

- The wizard generates random passwords and API tokens and saves them to `/tmp/` on the Proxmox host
- These files should be moved to a secure location after setup
- The Proxmox credentials are stored in `proxmox-creds.yaml` with permissions `0600`
- The API token is created with `privsep=0` (full API access). Consider refining permissions after setup.
- SSL verification is disabled (`verify_ssl: false`) by default. Enable it if you have valid certificates.

## Output Files

After successful execution, the wizard creates:

- `/tmp/twinbox-password-<cluster-name>.txt` - Password for `twinbox@pve`
- `/tmp/twinbox-creds-<cluster-name>.env` - API token (name and secret)
- `/tmp/cloud-init-<cluster-name>.yml` - The cloud-init config used (for reference)

## Troubleshooting

### VM Creation Fails

- Check storage availability: `qm list` to see existing VMs
- Check storage free space: `pvesh get /nodes/<node>/status | jq .disk_free`
- Verify storage name: `pvesh get /storage` (default is `local-lvm`)

### Cloud-Init Errors

If the VM boots but Twinbox doesn't start:

1. SSH to the management VM
2. Check cloud-init logs: `cat /var/log/cloud-init-output.log`
3. Check systemd service: `sudo systemctl status twinbox`
4. Check Docker Compose: `sudo docker-compose -f /opt/twinbox/docker-compose.yml logs`

### IP Address Not Detected

The wizard attempts to detect the VM IP automatically. If it fails:

- Enter the IP manually when prompted
- Or find it via Proxmox GUI: VM > Summary
- Or use: `qm guest cmd <vmid> "hostname -I"`

### Permission Errors

If the wizard fails to create users or set ACLs:

- Ensure you're running as root
- Check pvesh permissions: `pvesh get /access/users`
- Try manually: `pveum aclmod -group user:twinbox@pve -role PVEAdmin -path "/pools/twinbox-<name>"`

### Ubuntu Image Download Fails

If the Ubuntu Cloud image cannot be downloaded:

- Check internet connectivity on Proxmox host
- Verify the URL is accessible: `curl -I $CLOUD_IMAGE_URL`
- Manually download and place in `/var/lib/vz/template/iso/`
- Or use an existing image: `ubuntu-22.04-live-server-amd64.img`

## Examples

### Basic Setup

```bash
# Run wizard
./wizard/setup-wizard.sh

# Enter prompts:
# Cluster name? mycluster
# Management VM CPU? 2
# Management VM RAM (GB)? 4
# Management VM disk (GB)? 32
# Proxmox node to use? (press Enter for auto)

# After completion, SSH to management VM
ssh ubuntu@192.168.1.100

# Check Twinbox is running
docker ps

# Access web UI at http://192.168.1.100:8080
```

### Custom Resource Pool

```bash
# If you want to create the pool manually first:
pvesh create /pools -poolid twinbox-production
pvesh set /pools/twinbox-production/acl -path / -group user:twinbox@pve -roles VM.Create,VM.Modify,VM.PowerMgmt

# Then run wizard with cluster name "production"
```

### Using Different Storage

Edit the script or set environment:

```bash
export DEFAULT_STORAGE="proxmox-nvme"
./wizard/setup-wizard.sh
```

## Post-Setup

After the wizard completes:

1. **SSH to management VM** using the displayed IP
2. **Verify Twinbox is running**: `docker ps` should show the web container
3. **Access web UI**: Open `http://<vm-ip>:8080` in browser
4. **Securely store credentials**: Move `/tmp/twinbox-*.txt` and `/tmp/twinbox-creds-*.env` to password manager
5. **Bootstrap first cluster**: Use the web UI or CLI to deploy Talos Kubernetes cluster

## Advanced Configuration

### Custom cloud-init.yml

If you need to customize the cloud-init configuration (e.g., install additional tools, configure networking, etc.), edit `wizard/cloud-init.yml` before running the wizard.

The cloud-init format supports:

- `packages` - APT packages to install
- `runcmd` - Shell commands to run (as root)
- `write_files` - Files to create on the VM
- `ssh_authorized_keys` - SSH keys for users
- `hostname` - Set the VM hostname
- `fqdn` - Set the fully qualified domain name

### Modifying VM Hardware

Edit the `create_vm` function in `setup-wizard.sh` to change:

- VM hardware version
- BIOS type (seabios vs. ovmf)
- Network model
- Disk controller type
- Additional disks

### Custom Storage

Change `DEFAULT_STORAGE` at the top of the script or override per-node:

```bash
# In select_node function, customize per node:
if [[ "$SELECTED_NODE" == "pve-node1" ]]; then
    DEFAULT_STORAGE="fast-ssd"
fi
```

## Limitations

- **Single management VM**: The wizard creates one management VM per cluster. For HA, you would need to manually create additional management VMs.
- **DHCP only**: The management VM uses DHCP for networking. Static IP requires manual configuration post-setup.
- **Ubuntu 22.04**: The cloud image is hardcoded to Ubuntu 22.04 LTS (Jammy). Modify `UBUNTU_VERSION` and `UBUNTU_RELEASE` to change.
- **Self-signed certs**: The Proxmox connection uses `verify_ssl: false`. Upload proper certificates and enable verification for production.

## Support

For issues, feature requests, or contributions:

- GitHub Issues: https://github.com/your-org/twinbox/issues
- Documentation: `/docs/` directory
- Community: [link to community]

## License

Twinbox is released under the MIT License. See LICENSE for details.
