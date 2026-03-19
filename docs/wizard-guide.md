# Wizard Guide

`wizard/setup-wizard.sh` runs on Proxmox and prepares a Management VM for a selected cluster.

## What It Does

- Prompts for one Management VM form with name, IP, netmask, DNS, disk size, and memory.
- Prompts for cluster name (`ontwikkel`, `test`, `productie`, or custom).
- Uses the cluster slug in VM name, Proxmox API user/role, tags, and target path.
- Detects existing resources for the same cluster and supports cleanup with explicit confirmation.
- Creates the Management VM from Ubuntu 24.04 cloud image.
- Installs Docker CE on Management VM using official Docker apt repo (`download.docker.com`).
- Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox-<cluster-slug>`.
- Starts the manager stack with `docker compose pull && docker compose up -d`.

## Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

For local development of the wizard itself:

```bash
cp .env.wizard.local.example .env.wizard.local
# set WIZARD_DEV_SSH_TARGET=root@<proxmox-host>
make wizard-dev-run
```

The dev runner uploads only the current local `wizard/setup-wizard.sh` to the Proxmox host and starts that copy over SSH with an interactive TTY. It does not sync other unpushed repository changes into the eventual Management VM clone.

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
