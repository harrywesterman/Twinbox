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
- Writes `/opt/twinbox/.env` and starts the manager stack automatically, including a local Vaultwarden instance on `127.0.0.1:8222`.

## Step 2: Complete Vaultwarden bootstrap

Before using the rest of the stack, finish the one-time Vaultwarden setup over an SSH tunnel:

```bash
ssh -L 8222:127.0.0.1:8222 root@<management-vm-ip>
```

Then open `http://localhost:8222` in your browser and create the first Vaultwarden user with the password that the wizard wrote to `/opt/twinbox/bootstrap/vaultwarden-password`.

After the first user exists, finish the local seeding step on the Management VM:

```bash
cd /opt/twinbox
bw config server http://127.0.0.1:8222
bw login twinbox@local
export BW_SESSION="$(bw unlock --passwordfile /opt/twinbox/bootstrap/vaultwarden-password --raw)"
bash scripts/bootstrap-vaultwarden.sh
```

After that, the normal manager-first flow continues.

## Step 3: Open UI

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
