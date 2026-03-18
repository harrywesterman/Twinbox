# Wizard

`wizard/setup-wizard.sh` runs on a Proxmox host and creates only a Twinbox Management VM for a selected cluster name.

## Current Behavior

The wizard now does all of this automatically:

1. Prompts for a cluster name (`ontwikkel`, `test`, `productie`, or custom) and normalizes it.
2. Detects existing resources for that cluster and can remove them after double confirmation.
3. Builds a smart allocation grid for the management VM, VIP, and future Talos nodes.
4. Creates an Ubuntu 24.04 Management VM with cluster-specific names/tags.
5. Creates a cluster-specific Proxmox API user and role.
6. Installs Docker CE from the official Docker APT repo (`download.docker.com`).
7. Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox-<cluster-slug>`.
8. Writes `/opt/twinbox-<cluster-slug>/.env` from wizard input values, including the selected allocation defaults.
9. Starts the manager stack with Docker Compose.

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

For fast iteration from your local checkout without pushing first:

```bash
cp .env.wizard.local.example .env.wizard.local
# set WIZARD_DEV_SSH_TARGET=root@<proxmox-host>
make wizard-dev-run
```

This uploads the local `wizard/setup-wizard.sh` to the configured Proxmox host, then runs that remote copy with `ssh -tt` so the interactive `whiptail` UI keeps working. It only changes the wizard feedback loop: the Management VM still clones the rest of the repo from GitHub.

## Prompts

The wizard asks for:

- Cluster name selection
- Management VM sizing and bridge settings
- SSH public key
- Proxmox API settings for manager runtime (`PROXMOX_*`)
- Talos ISO filename and image tag (`TWINBOX_IMAGE_TAG`)
- A proposed VMID/IP allocation grid that you can edit before continuing

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
cd /opt/twinbox-<cluster-slug>
# adjust .env if required
docker compose pull
docker compose up -d
```

## Notes

- Docker source is official Docker repo, not Ubuntu `docker.io`.
- Phase 1 is LAN-only and has no app-level auth yet.
