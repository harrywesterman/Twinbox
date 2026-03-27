# Getting Started

This guide covers first deployment with the manager-first Twinbox setup.

## Prerequisites

- Proxmox host access (`root`).
- Internet access from Proxmox and the future Management VM.
- Enough CPU/RAM/storage for one Management VM plus later Talos nodes.

## Step 1: Run Proxmox Wizard

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

The wizard:

- Asks for a cluster name (`ontwikkel`, `test`, `productie`, or custom).
- Creates the Management VM with cluster-specific naming and tags.
- Detects existing resources for that cluster and can remove them after explicit confirmation.
- Installs Docker CE on that VM from the official Docker repository.
- Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox`.
- Writes `/opt/twinbox/.env` and starts the manager stack automatically, including a Vaultwarden instance on `http://<management-vm-ip>:8222`.

## Step 2: Verify Vaultwarden bootstrap

Before using the rest of the stack, verify that the one-time local Vaultwarden bootstrap completed on the Management VM:

```bash
ssh root@<management-vm-ip> 'test -f /opt/twinbox/bootstrap/vaultwarden-ready && echo ready'
```

You can also inspect the generated bootstrap files directly:

```bash
ssh root@<management-vm-ip> 'ls -l /opt/twinbox/bootstrap/'
```

Expected:

- `/opt/twinbox/bootstrap/vaultwarden-password` exists
- `/opt/twinbox/bootstrap/vaultwarden-client-id` exists
- `/opt/twinbox/bootstrap/vaultwarden-client-secret` exists
- `/opt/twinbox/bootstrap/vaultwarden-ready` exists

If `vaultwarden-ready` is missing after first boot, rerun the bootstrap on the Management VM:

```bash
ssh root@<management-vm-ip> 'cd /opt/twinbox && sudo bash scripts/bootstrap-vaultwarden.sh'
```

This re-syncs the Bitwarden CLI state, regenerates the API key files if needed, and writes the ready marker once the bootstrap completes.

After that, the normal manager-first flow continues.

## Step 3: Open the Installation Wizard

- `http://<management-vm-ip>:3000`

From there you can walk through the cluster bootstrap wizard, export or import the answer set, and monitor live output while the steps run.

## API Endpoints

- `GET /api/health`
- `POST /api/clusters`
- `POST /api/clusters/{cluster_id}/bootstrap`
- `GET /api/jobs/{job_id}`
- `GET /api/jobs/{job_id}/logs`

## Current Limitations

- LAN-only intended deployment.
- No app authentication yet.
