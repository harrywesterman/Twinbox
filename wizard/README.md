# Twinbox Management Environment

`wizard/setup-wizard.sh` runs on a Proxmox host and kickstarts the Twinbox Management Environment for a selected cluster name.

## Current Behavior

The wizard now does all of this automatically:

1. Shows the Twinbox clusters already detected on the host.
2. Lets you start a new cluster or remove an existing one.
3. Builds a VMID/IP allocation for the Twinbox Management Environment, VIP, and future Talos nodes.
4. Creates an Ubuntu 24.04 Twinbox Management Environment with cluster-specific names and tags.
5. Creates a cluster-specific Proxmox API user and role.
6. Installs Docker CE from the official Docker APT repo (`download.docker.com`).
7. Clones `https://github.com/harrywesterman/twinbox` into `/opt/twinbox`.
8. Writes `/opt/twinbox/.env` from wizard input values.
9. Starts the manager stack with Docker Compose and hands off to the Twinbox web UI.

After cloud-init completes, open the Twinbox Management Environment website:

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

This uploads the local `wizard/setup-wizard.sh` to the configured Proxmox host, then runs that remote copy with `ssh -tt` so the interactive `whiptail` UI keeps working. It only changes the wizard feedback loop: the Twinbox Management Environment still clones the rest of the repo from GitHub.

## Prompts

The wizard asks for:

- Cluster action: create or remove
- Cluster name
- SSH public key
- Cluster login password
- Optional manual infrastructure values if you do not use the recommended defaults
- A proposed VMID/IP allocation grid that you can edit before continuing

## What It Does Not Do

- It does not create Talos VMs directly.
- Talos provisioning and full cluster configuration continue later from the Twinbox management web UI.

## Validation

On the Twinbox Management Environment:

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
- The wizard keeps passwords out of the completion screen.
