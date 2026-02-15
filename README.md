# Twinbox

**Simplified Kubernetes on Proxmox**

A one-command setup that creates a management VM on Proxmox VE, ready for manual Twinbox platform installation.

## Quick Start

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

## What You Get (Phase 1)

The wizard creates a minimal Ubuntu VM with:

- **Ubuntu 24.04** server installation
- **Docker** and Docker Compose installed and configured
- **SSH access** configured for the ubuntu user
- **Static IP** configuration for reliable access
- **Prerequisite tools** (git, curl, etc.)

The management VM is ready for you to manually deploy the Twinbox platform (FastAPI web service + RQ worker) which will then orchestrate Kubernetes cluster deployments.

## Architecture

- **Phase 1**: Single bash script (wizard) creates a Management VM on Proxmox with Docker and SSH
- **Phase 2**: Administrator manually SSHes to VM, clones repo, and runs `docker-compose up` to start the platform
- **Phase 3** (future): Web UI-driven deployment of Kubernetes clusters with Talos Linux

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full system design.

## Documentation

- [Architecture Guide](docs/ARCHITECTURE.md)
- [Wizard README](wizard/README.md)
- [Manager README](manager/README.md)

## License

MIT
