# Twinbox Setup Wizard

The Twinbox Setup Wizard is a standalone bash script that creates a dedicated management VM on Proxmox VE. The VM boots with Ubuntu, Docker, and SSH access - **but does NOT automatically install the Twinbox platform**. After the wizard finishes, you must manually install the platform inside the VM.

**Quick summary:**
- Wizard creates: Ubuntu VM with Docker, git, SSH (twinbox user)
- Wizard does NOT: Install Twinbox manager application
- After wizard: SSH to VM, clone repo, run `docker-compose up -d`
- Result: Twinbox web UI available on port 8080

## Quick Start

### Phase 1: Run the Wizard

On your Proxmox host, run:

```bash
cd /path/to/twinbox
bash wizard/setup-wizard.sh
```

Or download and run directly:

```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh -o /tmp/setup-wizard.sh
bash /tmp/setup-wizard.sh
```

**Note**: The `curl | bash` pattern works but doesn't support interactive prompts. Always download first for interactive mode.

### Phase 2: Manual Installation

After the wizard completes and displays the VM IP, SSH to the VM and install Twinbox:

```bash
# 1. SSH to the VM (password from wizard output)
ssh twinbox@<vm-ip>

# 2. Clone the Twinbox repository
git clone https://github.com/harrywesterman/Twinbox.git
cd Twinbox/manager

# 3. Create environment file (copy and edit .env.example)
cp .env.example .env
# Edit .env with your database settings (or use defaults for Docker Compose)

# 4. Start Twinbox with Docker Compose
docker-compose up -d

# 5. Wait a minute for services to start, then access web UI
# Open http://<vm-ip>:8080 in your browser
```

See **Post-Setup** below for detailed instructions.

## What It Does

The wizard automates the following steps:

1. **Validates Proxmox environment** - Checks for required commands (`qm`, `pvesh`)
2. **Prompts for configuration** - Cluster name, VM resources, SSH public key (optional)
3. **Creates Twinbox user** - `twinbox@pve` with random password
4. **Creates resource pool** - `twinbox-<cluster-name>` for organizing resources
5. **Grants permissions** - Gives `twinbox@pve` necessary VM management rights
6. **Generates API token** - For programmatic access to Proxmox API
7. **Downloads Ubuntu Cloud image** - If not already present in `/var/lib/vz/template/iso`
8. **Creates management VM** - With specified CPU, RAM, and disk
9. **Configures cloud-init** - Installs Docker, git, qemu-guest-agent; creates `twinbox` user
10. **Starts VM** - Boots the management VM and waits for IP
11. **Displays credentials and next steps** - Shows VM IP, password, and manual installation instructions

**What the wizard does NOT do:**
- Install the Twinbox manager platform (FastAPI + RQ worker)
- Create Docker containers or run `docker-compose`
- Configure the Twinbox web UI or API

After the wizard finishes, you must manually SSH to the VM and run the installation steps.

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

The cloud-init configuration is embedded directly in `setup-wizard.sh`. To customize the management VM setup, you can:

1. Edit the `wizard/setup-wizard.sh` script and modify the `create_cloudinit_snippet` function
2. Or fork the repository and update the embedded template

**What cloud-init installs on the VM:**

- **OS**: Ubuntu 24.04 (noble)
- **Packages**:
  - `docker.io` - Docker engine
  - `git` - Version control (for cloning the Twinbox repo)
  - `qemu-guest-agent` - For IP detection and VM management
- **User account**: `twinbox` (UID 999, with sudo and docker group permissions)
- **SSH**: Public key (if provided) or password authentication enabled
- **Network**: DHCP (IP retrieved via QEMU guest agent)
- **Services enabled**: qemu-guest-agent, Docker, SSH
- **Message**: MOTD indicates that Phase 1 (wizard) is complete and Twinbox must be installed manually

The cloud-init config uses the `TWINBOX_PASSWORD` environment variable to set the password for the `twinbox` user.

### Systemd Service (Not Used by Wizard)

The systemd service file `manager/init/twinbox.service` is **NOT installed by the wizard**. This is because the wizard does not install the Twinbox platform itself.

After you manually install Twinbox on the VM (see Post-Setup below), you'll need to:
1. Copy `manager/init/twinbox.service` to the VM at `/etc/systemd/system/twinbox.service`
2. Enable and start it:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable twinbox
   sudo systemctl start twinbox
   ```
3. Then you can manage it with:
   ```bash
   sudo systemctl status twinbox
   sudo systemctl restart twinbox
   sudo journalctl -u twinbox -f
   ```

## What Gets Created

### On Proxmox

- **User**: `twinbox@pve` with random password
- **Resource Pool**: `twinbox-<cluster-name>`
- **ACL**: Permissions for `twinbox@pve` on the pool
- **API Token**: For programmatic access (name and secret saved to `/tmp`)
- **VM**: `twinbox-mgmt-<cluster-name>` with Ubuntu Cloud image and cloud-init configuration

### On Management VM (from cloud-init)

- **User**: `twinbox` (password randomly generated, with sudo and docker group access)
- **Group**: `twinbox`, `docker`, `sudo`
- **Packages installed**:
  - `docker.io` - Docker engine
  - `git` - For cloning the Twinbox repository
  - `qemu-guest-agent` - For VM management and IP detection
- **Services enabled and started**:
  - `qemu-guest-agent`
  - `docker`
  - `ssh`
- **Configuration files**:
  - `/etc/ssh/sshd_config.d/99-twinbox.conf` - Enables password authentication
  - `/etc/motd` - Post-setup message
- **Note**: `/opt/twinbox` and Twinbox platform files **are NOT created** - you must install them manually

## Security Notes

- The wizard generates random passwords and API tokens and saves them to `/tmp/` on the Proxmox host
- These files should be moved to a secure location after setup
- The Proxmox credentials are stored in `proxmox-creds.yaml` with permissions `0600`
- The API token is created with `privsep=0` (full API access). Consider refining permissions after setup.
- SSL verification is disabled (`verify_ssl: false`) by default. Enable it if you have valid certificates.

## Output Files

After successful execution, the wizard creates these files on the **Proxmox host**:

- `/tmp/twinbox-vm-password-<cluster-name>.txt` - Password for `twinbox` user on the VM
- `/tmp/twinbox-creds-<cluster-name>.env` - API token credentials (name and secret)
- `/var/lib/vz/snippets/twinbox-<cluster-name>-user.yaml` - Cloud-init config used (stored on Proxmox)

**Important**: These files contain sensitive credentials. Store them securely and delete after use.

## Troubleshooting

### VM Creation Fails

- Check storage availability: `qm list` to see existing VMs
- Check storage free space: `pvesh get /nodes/<node>/status | jq .disk_free`
- Verify storage name: `pvesh get /storage` (default is `local-lvm`)

### Cloud-Init Errors

If the VM boots but Docker or SSH doesn't work:

1. SSH to the management VM (use the password from wizard output)
2. Check cloud-init logs: `cat /var/log/cloud-init-output.log`
3. Check services: `sudo systemctl status docker qemu-guest-agent`
4. Verify twinbox user: `id twinbox`
5. Verify Docker works: `docker --version && docker ps`

**Note**: Twinbox platform is NOT installed by cloud-init. If Docker is running but Twinbox isn't, you need to manually install it (see Post-Setup above).

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
# Run wizard on Proxmox host
./wizard/setup-wizard.sh

# Enter prompts:
# Cluster name? mycluster
# Management VM CPU? 2
# Management VM RAM (GB)? 4
# Management VM disk (GB)? 32
# Proxmox node to use? (press Enter for auto)
# SSH public key? (paste or skip)

# Wizard output shows:
# VM ID: 101
# Name: twinbox-mgmt-mycluster
# IP: 192.168.1.100
# Password: <generated-twinbox-password>

# SSH to the VM
ssh twinbox@192.168.1.100

# Install Twinbox platform
sudo apt update && sudo apt install -y git  # if git not already installed
git clone https://github.com/harrywesterman/Twinbox.git
cd Twinbox/manager
cp .env.example .env
# Edit .env if needed (database defaults are fine)
docker-compose up -d

# Wait 30 seconds, then check
docker ps
# Should show: twinbox-web, twinbox-worker, postgres, redis

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

### Phase 2: Manual Twinbox Installation

After the wizard completes (Phase 1), you must manually install the Twinbox platform inside the VM:

1. **SSH to the management VM** using the IP and password from wizard output
   ```bash
   ssh twinbox@<vm-ip>
   Password: <from /tmp/twinbox-vm-password-<cluster>.txt>
   ```

2. **Clone the Twinbox repository**
   ```bash
   git clone https://github.com/harrywesterman/Twinbox.git
   cd Twinbox/manager
   ```

3. **Create environment file**
   ```bash
   cp .env.example .env
   # Edit .env if you need to customize database settings
   # Defaults use Docker Compose internal networking (no changes needed)
   ```

4. **Start Twinbox with Docker Compose**
   ```bash
   docker-compose up -d
   ```

5. **Verify services are running**
   ```bash
   docker ps
   # Expected containers: twinbox-web, twinbox-worker, postgres, redis
   ```

6. **Access the web UI**
   - Open `http://<vm-ip>:8080` in your browser
   - The UI should load and show the cluster dashboard

### After Twinbox is Running

1. **Securely store credentials** from Proxmox host:
   - `/tmp/twinbox-password-<cluster-name>.txt` - Proxmox `twinbox@pve` password
   - `/tmp/twinbox-creds-<cluster-name>.env` - API token credentials

2. **Check VM provisioning**: The wizard automatically created a `Cluster` record in the database with Proxmox credentials already configured.

3. **Deploy your first Kubernetes cluster**:
   - Use the web UI to configure VM sizes, Talos config, etc.
   - Click "Deploy" to start the Kubernetes deployment workflow
   - Monitor progress in the UI; logs are stored in the database

### Troubleshooting Installation

If Docker Compose fails:
```bash
# Check Docker is running
sudo systemctl status docker

# Check logs
docker-compose logs

# Rebuild if needed
docker-compose down
docker-compose up -d --build
```

## Advanced Configuration

### Custom cloud-init Configuration

If you need to customize the cloud-init configuration (e.g., install additional tools, configure networking, etc.), edit the `create_cloudinit` function in `wizard/setup-wizard.sh`.

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
- **Ubuntu 24.04**: The cloud image is hardcoded to Ubuntu 24.04 LTS (Noble). Modify `UBUNTU_VER` in the script to change.
- **Self-signed certs**: The Proxmox connection uses `verify_ssl: false`. Upload proper certificates and enable verification for production.

## Support

For issues, feature requests, or contributions:

- GitHub Issues: https://github.com/your-org/twinbox/issues
- Documentation: `/docs/` directory
- Community: [link to community]

## License

Twinbox is released under the MIT License. See LICENSE for details.
