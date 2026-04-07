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
- `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`
- `/opt/twinbox/bootstrap/secrets/global/grafana.json`
- `/opt/twinbox/bootstrap/secrets/global/authentik.json` - seed-only; deleted after Authentik syncs into OpenBao
- `/opt/twinbox/bootstrap/secrets/global/pgadmin4-oidc-<cluster-id>.json`
- `/opt/twinbox/bootstrap/secrets/global/wiredoor-gateway.json`
- `/opt/twinbox/bootstrap/secrets/global/velero.json`
- `/opt/twinbox/bootstrap/secrets/global/dashy-oidc-<cluster-id>.json`
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

### `twinbox-login.json`

```json
{
  "username": "twinbox",
  "password": "cluster-login-password"
}
```

### `grafana.json`

```json
{
  "admin-user": "admin",
  "admin-password": "generated-password"
}
```

### `pgadmin4-oidc.json`

```json
{
  "PGADMIN_DEFAULT_EMAIL": "pgadmin@cluster.example.local",
  "PGADMIN_DEFAULT_PASSWORD": "generated-password",
  "PGADMIN_MASTER_PASSWORD": "generated-password",
  "PGADMIN_OAUTH2_CLIENT_ID": "generated-client-id",
  "PGADMIN_OAUTH2_CLIENT_SECRET": "generated-client-secret",
  "PGADMIN_OAUTH2_SERVER_METADATA_URL": "https://authentik.example.com/application/o/pgadmin4/.well-known/openid-configuration",
  "PGADMIN_OAUTH2_SCOPE": "openid email profile",
  "PGADMIN_HOST": "https://pgadmin4.example.com",
  "PGADMIN_OAUTH2_REDIRECT_URI": "https://pgadmin4.example.com/oauth2/authorize"
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
  "mode": "seaweedfs",
  "endpoint": "http://192.168.1.50:8333",
  "bucket": "twinbox-velero",
  "region": "seaweedfs",
  "username": "velero",
  "password": "generated-password"
}
```

### `authentik.json` (seed-only bootstrap database keys)

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
- `provision-nodes` keeps control-plane VMs fixed at `4 GB RAM / 10 GB disk`, sizes workers separately from the node placement budget, and applies the `twinbox.io/role=worker` label to the nodes that should host Longhorn.
- `provision-nodes` renders the Talos-owned Cilium bootstrap manifest, enables Hubble Relay and Hubble UI, and injects it into the control-plane machine configs.
- `provision-nodes` configures Talos for kube-proxy-free Cilium with `cni: none`, `proxy.disabled: true`, KubePrism, the host DNS workaround, and an explicit `machine.time.servers` entry.
- The Hubble UI ingress route lives under `gitops/platform/hubble/` and is synced later by the `platform-ingress` ApplicationSet once the cluster domain is ready.
- Management VM bootstrap and maintenance use `TWINBOX_TIME_SERVER` to pin Ubuntu's `systemd-timesyncd` to the same timeserver.
- `install-argocd` installs Argo CD after the cluster networking layer is already available.
- `install-cloudtty` installs Cloudtty and creates a default browser shell on the cluster.
- `install-traefik-manager` deploys the Traefik Manager UI, stores its config on Longhorn, and exposes it behind the same domain-aware ingress flow.
- `install-prometheus` installs the kube-prometheus-stack app so Prometheus, Alertmanager, node-exporter, and kube-state-metrics are available on Longhorn-backed storage.
- `install-longhorn-storage` installs Longhorn, makes it the default storage class, and runs before any stateful secret infrastructure. Longhorn is configured to run only on worker nodes so storage and CSI components stay off control planes.
- `install-secret-sync` installs:
  - External Secrets Operator
  - OpenBao with Raft storage on Longhorn
  - `ClusterSecretStore/openbao`
  - `ExternalSecret/proxmox-bootstrap`
- External Secrets Operator uses its own internal TLS bootstrap for the webhook via `certController`; this is separate from the ingress TLS stack and does not require a user-managed CA.
- `install-cloudnativepg` installs the CloudNativePG operator with two replicas on Longhorn. The operator uses ServerSideApply for its CRDs.

- Authentik uses a `Recreate` deployment strategy so its bootstrap lock is held by only one pod at a time during rollouts. That avoids overlapping startup attempts from old and new pods.
- `wizard/setup-wizard.sh` writes the chosen cluster login password to `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json` inside the Management VM so later bootstrap steps can reuse it without prompting again.
- `create-users-and-groups` reads the Authentik bootstrap secret from OpenBao and `twinbox-login.json` from the Management VM bootstrap tree, creates the first Authentik user, creates the `admins` group as a superuser group, and adds the user to that group.
- `install-velero-backup` installs Velero together with the SeaweedFS S3 target that runs on the Management VM.
- Later application steps write bootstrap JSON into OpenBao before enabling their Argo CD applications.

## Dynamic Domain Configuration

Twinbox uses one base domain (`dns_domain`) for the cluster and derives a public zone name from it. The canonical policy is documented in [docs/ingress-policy.md](./ingress-policy.md): `prd` uses the base DNS domain directly, while non-`prd` clusters use the slug-prefixed hostname model. Cloudflare Tunnel is only offered for `prd` on Cloudflare Free.

### How it works

1. **User input** — The user enters the base domain in the web wizard during `choose-ingress-route`.
2. **Policy split** — The wizard stores the base domain and derives the public zone name as the base domain for `prd` or `slug.<dns_domain>` for other clusters.
3. **OpenBao sync** — The ingress selection step syncs `ZONE_NAME`, `WIREDOOR_FQDN`, and `WILDCARD_FQDN` to OpenBao at `twinbox/global/cluster-hostnames`.
4. **Argo cluster secret** — The ingress/domain step upserts a local Argo CD cluster secret in the `argocd` namespace and stores the derived public zone name as an annotation.
5. **ApplicationSets** — The `platform-ingress`, `grafana`, and `ntfy` ApplicationSets read that annotation at render time and inject the derived hostnames into Kustomize patches or Helm values.
6. **Kustomize render** — The `platform-ingress` ApplicationSet uses Kustomize to patch the live match expressions and start-page strings before sync.
7. **Ingress-specific apps** — Wiredoor, MetalLB, and Tailscale reuse the slug-prefixed hostname model. Cloudflare Tunnel is only offered for `prd` on Cloudflare Free.

### Affected services

All platform services use the runtime domain projection from the local Argo cluster secret:

| Service | Hostname |
|---------|----------|
| Argo CD | `argocd.<ZONE_NAME>` |
| Traefik dashboard | `traefik.<ZONE_NAME>` |
| Authentik | `authentik.<ZONE_NAME>` |
| pgAdmin 4 | `pgadmin4.<ZONE_NAME>` |
| Headlamp | `headlamp.<public-zone-name>` with Authentik OIDC login |
| Grafana | `grafana.<ZONE_NAME>` |
| Whoami | `whoami.<ZONE_NAME>` |
| Dashy start page | `start.<ZONE_NAME>` |

Dashy's browser-side OIDC flow depends on Authentik answering the discovery and token requests with CORS headers for `https://start.<ZONE_NAME>`. The platform IngressRoute applies a Traefik headers middleware for that response path.
Dashy registers the root start-page URL as its callback (`https://start.<ZONE_NAME>`), so the Authentik provider needs to accept that form without a trailing slash.

### GitOps structure

```
gitops/platform/
├── kustomization.yaml          # Central Kustomize config for the shared platform shape
├── authentik/ingressroute.yaml # Host match patched by the platform-ingress ApplicationSet
├── whoami/
│   ├── ingressroute.yaml       # Host match patched by the platform-ingress ApplicationSet
│   └── k8s.yaml                # Deployment + Service (no domain reference)
├── grafana/
│   ├── ingressroute.yaml       # Host match patched by the platform-ingress ApplicationSet
│   └── externalsecret.yaml     # Admin credentials from OpenBao
├── headlamp/ingressroute.yaml  # Host match patched by the platform-ingress ApplicationSet
├── headlamp/externalsecret.yaml # Headlamp OIDC client credentials from OpenBao
├── traefik/
│   ├── argocd-ingressroute.yaml
│   └── traefik-dashboard-ingressroute.yaml
├── wiredoor-gateway/
│   ├── ingressroute.yaml
│   └── externalsecret.yaml
└── dashy/
    ├── ingressroute.yaml
    ├── configmap.yaml          # Start page config template patched with the selected domain
    ├── externalsecret.yaml     # Dashy OIDC client credentials from OpenBao
    ├── pvc.yaml                # Longhorn-backed persistent user-data volume
    ├── deployment.yaml         # Dashy deployment mounts the PVC for user-data
    ├── service.yaml
```

### Argo CD application order

The local Argo cluster secret must exist before the domain-aware ApplicationSets are applied. Add `depends_on` in the wizard journey:

```
ingress selection → Argo cluster secret projection → platform-ingress
```

The `platform-ingress` ApplicationSet deploys the entire `gitops/platform/` directory via Kustomize and patches the live resources at sync time.

## Tooling Versions

Tool versions are pinned in [`config/pinned-defaults.sh`](../config/pinned-defaults.sh) and are not meant to be edited through `.env`.

The runtime `.env` only carries per-installation settings such as Proxmox access, image tags, and secret backend selection.
