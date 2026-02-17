# Twinbox

**Simplified Kubernetes on Proxmox**

A one-command setup that creates a management VM on Proxmox VE, ready for manual Twinbox platform installation.

## Quick Start

### Option 1: Web UI (Recommended)

On your Proxmox console:

```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh -o /tmp/setup-wizard.sh && bash /tmp/setup-wizard.sh
```

After the wizard completes, note the management VM IP address. Then SSH to the VM:

```bash
ssh ubuntu@<management-vm-ip>
```

Once connected, install the Twinbox platform:

```bash
# Clone the repository
git clone https://github.com/harrywesterman/Twinbox.git
cd Twinbox

# Start the platform (web UI + worker)
docker-compose up -d

# Access the web UI at http://<management-vm-ip>:8080
```

### Option 2: Terminal UI (TUI)

For a simpler, direct terminal interface on the Proxmox host itself:

```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-tui-install.sh -o /tmp/setup-tui-install.sh && chmod +x /tmp/setup-tui-install.sh && bash /tmp/setup-tui-install.sh --start
```

This installs and immediately launches the Twinbox TUI, which runs directly on the Proxmox host without requiring a management VM. See [wizard/TUI_INSTALL_README.md](wizard/TUI_INSTALL_README.md) for details.

## What You Get (Phase 1)

On your Proxmox console:

```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh -o /tmp/setup-wizard.sh && bash /tmp/setup-wizard.sh
```

After the wizard completes, note the management VM IP address. Then SSH to the VM:

```bash
ssh ubuntu@<management-vm-ip>
```

Once connected, install the Twinbox platform:

```bash
# Clone the repository
git clone https://github.com/harrywesterman/Twinbox.git
cd Twinbox

# Start the platform (web UI + worker)
docker-compose up -d

# Access the web UI at http://<management-vm-ip>:8080
```

The web UI option creates a minimal Ubuntu VM with:

- **Ubuntu 24.04** server installation
- **Docker** and Docker Compose installed and configured
- **SSH access** configured for the ubuntu user
- **Static IP** configuration for reliable access
- **Prerequisite tools** (git, curl, etc.)

The management VM is ready for you to manually deploy the Twinbox platform (FastAPI web service + RQ worker) which will then orchestrate Kubernetes cluster deployments.

The TUI option installs the Twinbox TUI directly on the Proxmox host for immediate use without VM creation.

## Architecture

The wizard creates a minimal Ubuntu VM with:

- **Ubuntu 24.04** server installation
- **Docker** and Docker Compose installed and configured
- **SSH access** configured for the ubuntu user
- **Static IP** configuration for reliable access
- **Prerequisite tools** (git, curl, etc.)

The management VM is ready for you to manually deploy the Twinbox platform (FastAPI web service + RQ worker) which will then orchestrate Kubernetes cluster deployments.

## Architecture

### Web UI Path
- **Phase 1**: Wizard creates a Management VM on Proxmox with Docker and SSH
- **Phase 2**: Administrator SSHes to VM, clones repo, and runs `docker-compose up` to start the platform
- **Phase 3** (future): Web UI-driven deployment of Kubernetes clusters with Talos Linux

### Terminal UI (TUI) Path
- **Single command**: Install and run the TUI directly on the Proxmox host
- **No VM required**: Runs natively on Proxmox for direct cluster management
- **Manual operation**: Interactive terminal interface for configuring and deploying clusters

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full system design.

## Documentation

- [Architecture Guide](docs/ARCHITECTURE.md)
- [Wizard README](wizard/README.md)
- [Manager README](manager/README.md)

## License

MIT
