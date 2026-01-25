# Twinbox

Twinbox is a comprehensive infrastructure automation platform for deploying and managing **Talos Linux Kubernetes** clusters on **Proxmox VE**. It uses a "Console Wizard" approach to simplify bootstrapping from zero to a fully managed cluster.

## Features

- **Talos Linux First**: Secure, immutable, and minimal API-managed Kubernetes OS.
- **Proxmox Console Wizard**: A standalone bash script (`setup-wizard.sh`) to bootstrap the cluster directly from the Proxmox host.
- **Management Identity**: Deploys a dedicated Ubuntu **Management VM** pre-configured with all necessary tools (`talosctl`, `kubectl`, `terraform`, `ansible`).
- **Platform Enhancements**: Plans for integrated storage (Rook/Ceph), Ingress (Traefik), and GitOps (ArgoCD).

## Quick Start

### Prerequisites

- A Proxmox VE server with internet access.
- Root access to the Proxmox console (SSH or Web Shell).
- Sufficient resources (RAM/CPU/Disk) for your desired cluster size.

### Installation (The "One-Liner")

Run the setup wizard directly on your Proxmox host:

```bash
bash <(curl -s https://raw.githubusercontent.com/your-org/twinbox/main/wizard/setup-wizard.sh)
```

*(Replace `your-org/twinbox` with the actual repository URL)*

### What happens next?

1.  **Wizard**: You answer a few questions (Cluster Name, Node Count, Resources).
2.  **Provisioning**: The wizard downloads ISOs and creates:
    -   **Control Plane Node(s)** (Talos)
    -   **Worker Node(s)** (Talos)
    -   **Management Node** (Ubuntu Cloud)
3.  **Auto-Start**: All VMs boot automatically.
4.  **Bootstrap**:
    -   SSH into the new Management Node: `ssh ubuntu@<IP>`
    -   Run the helper script: `./bootstrap-cluster.sh`
    -   **Done!** Your cluster is compliant and ready.

## Architecture

Twinbox abandons the complexity of external Terraform/Ansible management machines in favor of a self-contained approach:

1.  **Bootstrap Layer**: A lightweight bash script on Proxmox creates the VMs.
2.  **Management Layer**: A dedicated VM inside the cluster environment holds the state and management tools.
3.  **Cluster Layer**: Talos Linux nodes tailored for Kubernetes.

## Components

- `wizard/setup-wizard.sh`: The core bootstrapping logic.
- `docs/wizard-guide.md`: Detailed usage guide.
- `docs/plans/`: Architectural decisions and future roadmaps.

## License

Twinbox is released under the [LICENSE](LICENSE) license.
