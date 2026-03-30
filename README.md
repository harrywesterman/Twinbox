# Twinbox

Twinbox is a platform for provisioning and bootstrapping fully configured Talos Kubernetes clusters on Proxmox.

## Current Flow

1. Run `wizard/setup-wizard.sh` on Proxmox.
2. The wizard creates the Management VM.
3. The Management VM installs Docker CE, clones this repository into `/opt/twinbox`, loads `.env`, and starts `docker compose`.
4. `manager-web` runs on port `3000` and queues jobs through `manager-api` on port `8080`.
5. `manager-worker` polls the file queue under `manager-data/` and runs repo-owned scripts.
6. The first visible wizard step is `Deploy Talos Cluster`.
7. After the Talos cluster is up, the flow continues through Flannel, Argo CD, Longhorn, OpenBao secret sync, CloudNativePG, Traefik, Velero, and the remaining GitOps application steps.

## Secret Model

- Management-local bootstrap files live under `/opt/twinbox/bootstrap`.
- Global bootstrap secrets live under `/opt/twinbox/bootstrap/secrets/global/*.json`.
- Cluster-scoped file artifacts live under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`.
- OpenBao bootstrap state lives under `/opt/twinbox/bootstrap/openbao/`.
- OpenBao becomes the source of truth for runtime secrets after `install-secret-sync`.
- Kubernetes `Secret` objects remain derived artifacts synced by External Secrets Operator.

## Repository Layout

- `wizard/`: Proxmox setup wizard.
- `manager-web/`: web installation wizard for the Management VM.
- `manager-api/`: REST API, validation, queueing, and state handling.
- `manager-worker/`: queue polling and script execution.
- `categories/`: manifest-driven category and step catalog.
- `scripts/manager/`: provisioning and lifecycle scripts bundled into the worker image.
- `gitops/`: Argo CD bootstrap and application manifests.
- `docs/`: operational documentation.

## Quick Start

### Run the Twinbox Web Installation Wizard on a proxmox server console

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

### Open the with a browser to continue installing the cluster

- UI: `http://<management-vm-ip>:3000`
