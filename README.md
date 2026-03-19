# Twinbox

Twinbox is a manager-first platform for provisioning and bootstrapping Talos Kubernetes clusters on Proxmox.

## Current Workflow

1. Run the Proxmox wizard: `wizard/setup-wizard.sh`.
2. The wizard creates a Management VM only.
3. Cloud-init on that VM installs Docker CE from the official Docker repo, clones this repository, installs `talosctl`/`kubectl`/`helm` from pinned `.env` versions, and starts the manager stack automatically.
4. Open the web UI and create/bootstrap Talos clusters from there.

## Quick Start

### 1. Run wizard on Proxmox

<p><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)</code> <kbd title="Kopieer">📋</kbd></p>

For local wizard iteration without pushing to GitHub first:

```bash
cp .env.wizard.local.example .env.wizard.local
# set WIZARD_DEV_SSH_TARGET=root@<proxmox-host>
make wizard-dev-run
```

This uploads only your local `wizard/setup-wizard.sh` to the Proxmox host and runs it over SSH with a TTY. The Management VM still clones the repository from GitHub afterward.

### 2. Open endpoints

- UI: `http://<management-vm-ip>:3000`
- API health: `http://<management-vm-ip>:8080/api/health`

### 3. Optional manual recovery on Management VM

```bash
cd /opt/twinbox
# edit .env if needed
docker compose pull
docker compose up -d
```

## Docker Images (Prebuilt)

Twinbox uses public prebuilt images from GHCR:

- `ghcr.io/harrywesterman/twinbox-manager-api`
- `ghcr.io/harrywesterman/twinbox-manager-worker`
- `ghcr.io/harrywesterman/twinbox-manager-web`

Image tag is controlled by `.env`:

```dotenv
TWINBOX_IMAGE_TAG=latest
```

Management tool versions are configured as follows:

- `talosctl` is pinned in `config/pinned-defaults.sh`
- `kubectl` and `helm` stay configurable in `.env`

```dotenv
KUBECTL_VERSION=v1.30.0
HELM_VERSION=v3.15.4
```

## Repository Layout

- `wizard/`: Proxmox setup wizard.
- `manager-web/`: React frontend.
- `manager-api/`: REST API and job metadata handling.
- `manager-worker/`: Async job runner.
- `scripts/manager/`: Provisioning/bootstrap scripts bundled into the worker image.
- `docs/`: Operational documentation.

## Publishing Images

GitHub Actions workflow `.github/workflows/docker-publish.yml` publishes images to GHCR on:

- Push to `main`
- Tags matching `v*`
- Manual trigger (`workflow_dispatch`)

## Phase 1 Scope

- Submit Talos VM provisioning jobs from UI.
- Submit Talos bootstrap jobs from UI.
- Track jobs (`pending`, `running`, `succeeded`, `failed`) and logs.

## Security Baseline (Phase 1)

- Intended for trusted LAN environments.
- No app-level auth yet.
- Runtime secrets are loaded from `.env`.
- Wizard-generated cloud-init snippets on Proxmox are written with `0600` permissions.
