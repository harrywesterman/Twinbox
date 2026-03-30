# Configuration

Twinbox loads runtime configuration from the root `.env`. Secrets are bootstrapped into files under `/opt/twinbox/bootstrap` and are no longer stored in `.env` after initial seeding.

## Required `.env` Values

```dotenv
PROXMOX_HOST=192.168.1.10
PROXMOX_PORT=8006
PROXMOX_USER=root@pam
PROXMOX_PASSWORD=change-me
PROXMOX_NODE=pve
PROXMOX_STORAGE_POOL=local-lvm
PROXMOX_FILE_DATASTORE=local
KUBECTL_VERSION=v1.30.0
HELM_VERSION=v3.15.4
TWINBOX_IMAGE_TAG=latest
TWINBOX_HOST_REPO_ROOT=/opt/twinbox
TWINBOX_SECRET_BACKEND=filesystem
TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap
TWINBOX_SECRET_ITEM_PREFIX=twinbox
TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets
TWINBOX_SECRET_CACHE_TTL_SEC=60
```

## Bootstrap File Layout

### Global bootstrap secrets

- `/opt/twinbox/bootstrap/secrets/global/proxmox.json`
- `/opt/twinbox/bootstrap/secrets/global/traefik-dashboard.json`
- `/opt/twinbox/bootstrap/secrets/global/grafana.json`
- `/opt/twinbox/bootstrap/secrets/global/authentik.json`
- `/opt/twinbox/bootstrap/secrets/global/wiredoor-gateway.json`
- `/opt/twinbox/bootstrap/secrets/global/velero.json`

### Cluster-scoped runtime artifacts

- `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/talos-secrets/secrets.yaml`
- `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/talosconfig/talosconfig`
- `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/kubeconfig/kubeconfig`

### OpenBao bootstrap state

- `/opt/twinbox/bootstrap/openbao/seal/current.key`
- `/opt/twinbox/bootstrap/openbao/seal/current-key-id`
- `/opt/twinbox/bootstrap/openbao/init/initialized.json`
- `/opt/twinbox/bootstrap/openbao/init/root-token`
- `/opt/twinbox/bootstrap/openbao/init/recovery-keys.json`

## Bootstrap JSON Contracts

### `proxmox.json`

```json
{
  "username": "root@pam",
  "password": "super-secret",
  "host": "192.168.1.10",
  "port": "8006",
  "endpoint": "https://192.168.1.10:8006"
}
```

### `traefik-dashboard.json`

```json
{
  "username": "admin",
  "password": "generated-password",
  "users": "admin:$apr1$..."
}
```

### `grafana.json`

```json
{
  "admin-user": "admin",
  "admin-password": "generated-password"
}
```

### `wiredoor-gateway.json`

```json
{
  "WIREDOOR_URL": "https://wiredoor.example",
  "TOKEN": "generated-token"
}
```

### `velero.json`

```json
{
  "mode": "embedded-garage",
  "endpoint": "http://garage.velero.svc.cluster.local:3900",
  "bucket": "twinbox-velero",
  "region": "garage",
  "username": "velero",
  "password": "generated-password"
}
```

## Cluster Secret Runtime

- `provision-nodes` bootstraps Talos and writes the Talos runtime artifacts for a cluster.
- `install-flannel` bootstraps pod networking before Argo CD comes online.
- `install-argocd` installs Argo CD and adopts Flannel for ongoing reconciliation.
- `install-longhorn-storage` installs Longhorn before any stateful secret infrastructure.
- `install-secret-sync` installs:
  - External Secrets Operator
  - OpenBao with Raft storage on Longhorn
  - `ClusterSecretStore/openbao`
  - `ExternalSecret/proxmox-bootstrap`
- `install-velero-backup` installs Velero together with either a Twinbox-managed Garage bucket or an external S3-compatible backup target.
- Later application steps write bootstrap JSON into OpenBao before enabling their Argo CD applications.

## Tooling Versions

- `talosctl`, `tofu`, `k9s`, External Secrets chart, Longhorn chart, and OpenBao chart are pinned in `config/pinned-defaults.sh`
- `kubectl` and `helm` stay configurable through `.env`
