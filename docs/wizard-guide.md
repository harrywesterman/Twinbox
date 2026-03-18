# Wizard Guide

`wizard/setup-wizard.sh` runs on Proxmox and prepares a Management VM for a selected cluster.

## What It Does

- Prompts for Management VM sizing/network values.
- Prompts for cluster name (`ontwikkel`, `test`, `productie`, or custom).
- Uses the cluster slug in VM name, Proxmox API user/role, tags, and target path.
- Detects existing resources for the same cluster and supports cleanup with explicit confirmation.
- Builds a smart allocation grid for the management VM, VIP, and future Talos nodes.
- Collects Proxmox/Talos defaults for manager `.env`.
- Creates the Management VM from Ubuntu 24.04 cloud image.
- Installs Docker CE on Management VM using official Docker apt repo (`download.docker.com`).
- Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox-<cluster-slug>`.
- Starts the manager stack with `docker compose pull && docker compose up -d`.

## Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

## Validate Management VM

```bash
ssh ubuntu@<management-vm-ip>
docker --version
docker compose version
curl -fsS http://localhost:8080/api/health
```

## Notes

- Twinbox compose uses prebuilt public GHCR images.
- Docker source is official Docker repository, not Ubuntu `docker.io`.
- Keep deployment in trusted LAN scope for phase 1.
- The wizard writes a cloud-init snippet under `/var/lib/vz/snippets/` with mode `0600`.
- Talos VM provisioning remains in the management stack/UI and is not created directly by the wizard.
- The generated cloud-init template also stores the selected cluster allocation defaults for later reuse.
 - Talos VM provisioning remains in the management stack/UI and is not created directly by the wizard.
 - The generated cloud-init template also stores the selected cluster allocation defaults for later reuse.
