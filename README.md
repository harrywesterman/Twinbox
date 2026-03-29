# Twinbox

Twinbox is a manager-first platform for provisioning and bootstrapping Talos Kubernetes clusters on Proxmox.

## Current Workflow

1. Run `wizard/setup-wizard.sh` on a Proxmox host.
2. The wizard creates only the Management VM.
3. Cloud-init on that VM installs Docker CE, clones this repository into `/opt/twinbox`, writes `.env`, materializes bootstrap files under `/opt/twinbox/bootstrap`, and starts `docker compose`.
4. The web UI on `http://<management-vm-ip>:3000` queues jobs through `manager-api`.
5. `manager-worker` polls the file queue under `manager-data/` and runs repo-owned scripts.
6. Talos cluster secrets start on the Management VM filesystem and move into the cluster through `install-secret-sync`, which installs External Secrets Operator and OpenBao on Longhorn.

## Secret Model

- Management-local bootstrap files live under `/opt/twinbox/bootstrap`.
- Global bootstrap secrets live under `/opt/twinbox/bootstrap/secrets/global/*.json`.
- Cluster-scoped file artifacts live under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`.
- OpenBao bootstrap state lives under `/opt/twinbox/bootstrap/openbao/`.
- OpenBao becomes the source of truth for cluster runtime secrets after `install-secret-sync`.
- Kubernetes `Secret` objects remain derived artifacts synced by External Secrets Operator.

## Quick Start

### 1. Run the Proxmox wizard

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

For local wizard iteration without pushing first:

```bash
cp .env.wizard.local.example .env.wizard.local
# set WIZARD_DEV_SSH_TARGET=root@<proxmox-host>
make wizard-dev-run
```

For local `manager-web` iteration against an existing Management VM:

```bash
cp .env.vm-preview.local.example .env.vm-preview.local
# set TWINBOX_VM_PREVIEW_TARGET and TWINBOX_VM_PREVIEW_REMOTE_DIR
bash scripts/manager-web-preview.sh
```

### 2. Open the endpoints

- UI: `http://<management-vm-ip>:3000`
- API health: `http://<management-vm-ip>:8080/api/health`

### 3. Optional recovery on the Management VM

```bash
cd /opt/twinbox
docker compose pull
docker compose up -d
```

## Repository Layout

- `wizard/`: Proxmox setup wizard
- `manager-web/`: web installation wizard for the Management VM
- `manager-api/`: REST API and job metadata handling
- `manager-worker/`: queue polling and script execution
- `categories/`: manifest-driven category and step catalog
- `scripts/manager/`: provisioning and lifecycle scripts bundled into the worker image
- `gitops/`: Argo CD bootstrap and application manifests
- `docs/`: operational documentation

## Security Baseline

- Intended for trusted LAN environments.
- No app-level auth yet.
- `.env` carries bootstrap-only material plus non-secret defaults.
- The canonical bootstrap secret tree is local to the Management VM.
- OpenBao holds cluster runtime secrets after the secret-sync step.
