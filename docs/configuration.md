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
TALOS_IMAGE_PRESET=qemu-guest-agent
TWINBOX_IMAGE_TAG=latest
TWINBOX_HOST_REPO_ROOT=/opt/twinbox
TWINBOX_SECRET_BACKEND=filesystem
TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap
TWINBOX_SECRET_ITEM_PREFIX=twinbox
TWINBOX_TIME_SERVER=time.cloudflare.com
MANAGEMENT_VM_IP=192.168.1.50
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
- `/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-<cluster-id>.json`
- `/opt/twinbox/bootstrap/secrets/global/cloudflare-<cluster-id>.json`
- `/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-<cluster-id>.json`
- `/opt/twinbox/bootstrap/secrets/global/cloudflare-<cluster-id>.json`

### Cluster-scoped runtime artifacts

- `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/talos-secrets/secrets.yaml`
- `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/talosconfig/talosconfig`
- `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/kubeconfig/kubeconfig`
- `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`

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

### `authentik.json` (database keys)

```json
{
  "AUTHENTIK_SECRET_KEY": "generated-secret",
  "AUTHENTIK_BOOTSTRAP_PASSWORD": "generated-password",
  "AUTHENTIK_BOOTSTRAP_TOKEN": "generated-token",
  "AUTHENTIK_BOOTSTRAP_EMAIL": "akadmin@twinbox.local",
  "AUTHENTIK_HOST": "https://authentik.example.com",
  "AUTHENTIK_HOST_BROWSER": "https://authentik.example.com",
  "AUTHENTIK_POSTGRESQL__USERNAME": "authentik",
  "AUTHENTIK_POSTGRESQL__PASSWORD": "generated-password"
}
```

## Cluster Secret Runtime

- `provision-nodes` bootstraps Talos and writes the Talos runtime artifacts for a cluster.
- `provision-nodes` renders the Talos-owned Cilium bootstrap manifest and injects it into the control-plane machine configs.
- `provision-nodes` configures Talos for kube-proxy-free Cilium with `cni: none`, `proxy.disabled: true`, KubePrism, the host DNS workaround, and an explicit `machine.time.servers` entry.
- Management VM bootstrap and maintenance use `TWINBOX_TIME_SERVER` to pin Ubuntu's `systemd-timesyncd` to the same timeserver.
- `install-argocd` installs Argo CD after the cluster networking layer is already available.
- `install-longhorn-storage` installs Longhorn, makes it the default storage class, and runs before any stateful secret infrastructure.
- `install-secret-sync` installs:
  - External Secrets Operator
  - OpenBao with Raft storage on Longhorn
  - `ClusterSecretStore/openbao`
  - `ExternalSecret/proxmox-bootstrap`
- `install-cloudnativepg` installs the CloudNativePG operator with two replicas on Longhorn. The operator uses ServerSideApply for its CRDs.
- `install-postgres-clusters` deploys all database clusters defined under `gitops/databases/`. Each cluster gets a CloudNativePG `Cluster` (3 instances), PgBouncer `Pooler` (read-write and read-only), a `ScheduledBackup` for daily snapshots, and an `ExternalSecret` that pulls credentials from OpenBao. Applications connect through the pooler service (e.g. `authentik-db-pooler-rw.databases.svc.cluster.local`).
- `install-velero-backup` installs Velero together with either a Twinbox-managed Garage bucket or an external S3-compatible backup target.
- Later application steps write bootstrap JSON into OpenBao before enabling their Argo CD applications.

## Dynamic Domain Configuration

Twinbox uses a single base domain (`ZONE_NAME`) for all platform services, then prefixes the cluster slug for non-PRD hostnames. The user provides the base domain during the **Choose Ingress Route** step and Twinbox derives the public hostname from it.

### How it works

1. **User input** — The user enters the base domain (e.g. `example.com`) in the web wizard during `choose-ingress-route`.
2. **OpenBao sync** — The ingress selection step syncs `ZONE_NAME`, `WIREDOOR_FQDN`, and `WILDCARD_FQDN` to OpenBao at `twinbox/global/cluster-hostnames`.
3. **ExternalSecret** — The `cluster-config` ExternalSecret reads `ZONE_NAME` from OpenBao and creates a Kubernetes Secret in the `argocd` namespace.
4. **Rendered ConfigMap** — The ingress/domain step renders `gitops/platform/cluster-config/configmap.yaml` with the cluster-prefixed public zone name and prebuilt route strings.
5. **Kustomize replacements** — The `platform-ingress` Argo CD application uses Kustomize to copy the rendered match expressions and homepage strings into the live platform manifests.
6. **Ingress-specific apps** — Cloudflare Tunnel, Wiredoor, MetalLB, and Tailscale all reuse the same selected domain when they render route-specific configuration.

### Affected services

All platform services use the rendered `cluster-config` values:

| Service | Hostname |
|---------|----------|
| Argo CD | `argocd.<ZONE_NAME>` |
| Traefik dashboard | `traefik.<ZONE_NAME>` |
| Authentik | `authentik.<ZONE_NAME>` |
| Headlamp | `headlamp.<public-zone-name>` |
| Grafana | `grafana.<ZONE_NAME>` |
| Whoami | `whoami.<ZONE_NAME>` |
| Homepage | `homepage.<ZONE_NAME>` |

### GitOps structure

```
gitops/platform/
├── kustomization.yaml          # Central Kustomize config with replacements
├── cluster-config/
│   ├── configmap.yaml          # Rendered plain-text source for Kustomize replacements
│   └── externalsecret.yaml     # Reads ZONE_NAME from OpenBao
├── authentik/ingressroute.yaml # Host match rendered from cluster-config
├── whoami/
│   ├── ingressroute.yaml       # Host match rendered from cluster-config
│   └── k8s.yaml                # Deployment + Service (no domain reference)
├── grafana/
│   ├── ingressroute.yaml       # Host match rendered from cluster-config
│   └── externalsecret.yaml     # Admin credentials from OpenBao
├── headlamp/ingressroute.yaml  # Host match rendered from cluster-config
├── traefik/
│   ├── argocd-ingressroute.yaml
│   └── traefik-dashboard-ingressroute.yaml
├── wiredoor-gateway/
│   ├── ingressroute.yaml
│   └── externalsecret.yaml
└── homepage/
    ├── ingressroute.yaml
    ├── configmap.yaml          # Bookmarks and services rendered with the selected domain
    └── deployment.yaml         # HOMEPAGE_ALLOWED_HOSTS
```

### Argo CD application order

The `cluster-config` application must sync before `platform-ingress` so that the rendered ConfigMap exists when Kustomize performs replacements. Add `depends_on` in the wizard journey:

```
cluster-config → platform-ingress
```

The `platform-ingress` application deploys the entire `gitops/platform/` directory via Kustomize, which handles all replacements at sync time.

## Tooling Versions

Tool versions are pinned in [`config/pinned-defaults.sh`](../config/pinned-defaults.sh) and are not meant to be edited through `.env`.

The runtime `.env` only carries per-installation settings such as Proxmox access, image tags, and secret backend selection.
