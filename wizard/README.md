# Wizard

`wizard/setup-wizard.sh` runs on a Proxmox host and creates only the Twinbox Management VM.

## Current Behavior

The wizard now does all of this automatically:

1. Creates an Ubuntu 24.04 Management VM.
2. Installs Docker CE from the official Docker APT repo (`download.docker.com`).
3. Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox`.
4. Writes `/opt/twinbox/.env` from wizard input values.
5. Starts the manager stack with Docker Compose.

After cloud-init completes, open:

- UI: `http://<management-vm-ip>:3000`
- API health: `http://<management-vm-ip>:8080/api/health`

## Run

From Proxmox:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

Or from a local clone:

```bash
bash wizard/setup-wizard.sh
```

## Prompts

The wizard asks for:

- Management VM sizing and bridge settings
- SSH public key
- Proxmox API settings for manager runtime (`PROXMOX_*`)
- Talos ISO filename and image tag (`TWINBOX_IMAGE_TAG`)

## What It Does Not Do

- It does not create Talos VMs directly.
- Talos provisioning/bootstrap is triggered later from the manager web UI.

## Validation

On the Management VM:

```bash
docker --version
docker compose version
curl -fsS http://localhost:8080/api/health
```

## Recovery

If needed:

```bash
cd /opt/twinbox
# adjust .env if required
docker compose pull
docker compose up -d
```

## Notes

- Docker source is official Docker repo, not Ubuntu `docker.io`.
- Phase 1 is LAN-only and has no app-level auth yet.
