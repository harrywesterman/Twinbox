# Wizard Guide

`wizard/setup-wizard.sh` runs on Proxmox and prepares the Management VM.

## What It Does

- Prompts for Management VM sizing/network values.
- Collects Proxmox/Talos defaults for manager `.env`.
- Creates the Management VM from Ubuntu 24.04 cloud image.
- Installs Docker CE on Management VM using official Docker apt repo (`download.docker.com`).
- Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox`.
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
