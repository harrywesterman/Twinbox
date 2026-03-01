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
- Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox-<cluster-slug>`.
- Writes `/opt/twinbox-<cluster-slug>/.env` and starts the manager stack automatically.

## Step 2: Open UI

- `http://<management-vm-ip>:3000`

From there you can submit provisioning and bootstrap jobs and monitor logs.

## API Endpoints

- `GET /api/health`
- `POST /api/clusters`
- `POST /api/clusters/{cluster_id}/bootstrap`
- `GET /api/jobs/{job_id}`
- `GET /api/jobs/{job_id}/logs`

## Current Limitations

- LAN-only intended deployment.
- No app authentication yet.
