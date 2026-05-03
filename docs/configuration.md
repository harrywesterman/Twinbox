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

`TWINBOX_HOST_REPO_ROOT` is the host runtime root used by the manager stack on the Management VM. The name is historical; it does not mean the host keeps a full repo checkout.

## Bootstrap File Layout

### Global bootstrap secrets

- `/opt/twinbox/bootstrap/secrets/global/proxmox.json`
- `/opt/twinbox/bootstrap/secrets/global/traefik-dashboard.json`
- `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`
- `/opt/twinbox/bootstrap/secrets/global/grafana-oidc-<cluster-id>.json`
- `/opt/twinbox/bootstrap/secrets/global/authentik.json` - seed-only; deleted after Authentik syncs into OpenBao
- `/opt/twinbox/bootstrap/secrets/global/pgadmin4-oidc-<cluster-id>.json`
- `/opt/twinbox/bootstrap/secrets/global/audiobookshelf.json`
- `/opt/twinbox/bootstrap/secrets/global/wiredoor-gateway.json`
- `/opt/twinbox/bootstrap/secrets/global/velero.json`
- `/opt/twinbox/bootstrap/secrets/global/velero-ui.json`
- `/opt/twinbox/bootstrap/secrets/global/management-backup.json`
- `/opt/twinbox/bootstrap/secrets/global/argocd-cli.json`
- `/opt/twinbox/bootstrap/secrets/global/twinbox-portal.json`
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

### `grafana-oidc.json`

```json
{
  "GF_AUTH_DISABLE_LOGIN_FORM": "true",
  "GF_AUTH_OAUTH_AUTO_LOGIN": "true",
  "GF_AUTH_BASIC_ENABLED": "false",
  "GF_USERS_AUTO_ASSIGN_ORG_ROLE": "Admin",
  "GF_AUTH_GENERIC_OAUTH_ENABLED": "true",
  "GF_AUTH_GENERIC_OAUTH_NAME": "Authentik",
  "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP": "true",
  "GF_AUTH_GENERIC_OAUTH_CLIENT_ID": "generated-client-id",
  "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": "generated-client-secret",
  "GF_AUTH_GENERIC_OAUTH_SCOPES": "openid profile email",
  "GF_AUTH_GENERIC_OAUTH_AUTH_URL": "https://authentik.example.com/application/o/authorize/",
  "GF_AUTH_GENERIC_OAUTH_TOKEN_URL": "https://authentik.example.com/application/o/token/",
  "GF_AUTH_GENERIC_OAUTH_API_URL": "https://authentik.example.com/application/o/userinfo/",
  "GF_SECURITY_ADMIN_USER": "admin",
  "GF_SECURITY_ADMIN_PASSWORD": "generated-admin-password"
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

### `velero-ui.json`

```json
{
  "pass_phrase": "generated-passphrase",
  "AUTH_SECRET_PASSPHRASE": "generated-passphrase",
  "BASIC_AUTH_ENABLED": "false",
  "OAUTH_AUTH_ENABLED": "true",
  "OAUTH_CLIENT_ID": "generated-client-id",
  "OAUTH_CLIENT_SECRET": "generated-client-secret",
  "OAUTH_AUTHORIZATION_URL": "https://authentik.example.com/application/o/authorize/",
  "OAUTH_TOKEN_URL": "https://authentik.example.com/application/o/token/",
  "OAUTH_USER_INFO_URL": "https://authentik.example.com/application/o/userinfo/",
  "OAUTH_REDIRECT_URI": "https://velero-ui.example.com/login"
}
```

`install-velero-ui` syncs this JSON into OpenBao, reuses it as the Velero UI bootstrap secret, and renders the Velero UI Helm chart with OIDC enabled and the admins-only policy file.

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

`scripts/start-manager.sh` keeps this file aligned with the Management VM's SeaweedFS runtime credentials and endpoint, and `install-velero-backup` syncs the same JSON into OpenBao before rendering the Velero Application.

### `management-backup.json`

```json
{
  "mode": "seaweedfs",
  "endpoint": "http://192.168.1.50:8333",
  "bucket": "twinbox-velero",
  "region": "seaweedfs",
  "username": "velero",
  "password": "generated-password",
  "restic_password": "generated-password",
  "cluster_id": "cluster-id",
  "controlplane_ip": "192.168.1.101",
  "talosconfig": "/opt/twinbox/bootstrap/secrets/cluster/cluster-id/talosconfig/talosconfig",
  "host_root": "/opt/twinbox",
  "retention_days": 30,
  "exclude_paths": ["/opt/twinbox/seaweedfs/data"]
}
```

`install-management-backup` writes this file on the Management VM and installs `/etc/cron.d/twinbox-management-backup`. The cron jobs create daily Talos etcd snapshots and restic backups of `/opt/twinbox` into SeaweedFS while excluding SeaweedFS object data.

### `argocd-cli.json`

```json
{
  "ARGOCD_HOST": "https://argocd.example.com",
  "CLUSTER_ID": "prd"
}
```

`configure-argocd-oidc` writes this file on the Management VM and syncs it into OpenBao so the VM can bootstrap a usable `argocd` CLI login during maintenance runs.

### `authentik.json` (seed-only bootstrap database keys)

```json
{
  "AUTHENTIK_SECRET_KEY": "generated-secret",
  "AUTHENTIK_BOOTSTRAP_PASSWORD": "generated-password",
  "AUTHENTIK_BOOTSTRAP_TOKEN": "generated-token",
  "AUTHENTIK_BOOTSTRAP_EMAIL": "akadmin@twinbox.local",
  "AUTHENTIK_AUTOMATION_TOKEN_KEY": "generated-hex-token",
  "AUTHENTIK_HOST": "https://authentik.example.com",
  "AUTHENTIK_HOST_BROWSER": "https://authentik.example.com",
  "AUTHENTIK_POSTGRESQL__USERNAME": "authentik",
  "AUTHENTIK_POSTGRESQL__PASSWORD": "generated-password"
}
```

## Cluster Secret Runtime

- `provision-nodes` bootstraps Talos and writes the Talos runtime artifacts for a cluster.
- `provision-nodes` keeps control-plane VMs fixed at `4 GB RAM / 10 GB disk`, sizes workers from a `100%` share of the free disk budget across the three Proxmox hosts with a worker-disk slider, and applies the `twinbox.io/role=worker` label to the nodes that should host Longhorn.
- `provision-nodes` renders the Talos-owned Cilium bootstrap manifest, enables Hubble Relay and Hubble UI, and injects it into the control-plane machine configs.
- `provision-nodes` configures Talos for kube-proxy-free Cilium with `cni: none`, `proxy.disabled: true`, KubePrism, the host DNS workaround, and an explicit `machine.time.servers` entry.
- The Hubble UI ingress route lives under `gitops/platform/hubble/` and is synced later by the `platform-ingress` ApplicationSet once the cluster domain is ready.
- Management VM bootstrap and maintenance use `TWINBOX_TIME_SERVER` to pin Ubuntu's `systemd-timesyncd` to the same timeserver.
- `install-argocd` installs Argo CD after the cluster networking layer is already available.
- `install-prometheus` installs the kube-prometheus-stack app so Prometheus, Alertmanager, node-exporter, and kube-state-metrics are available on Longhorn-backed storage.
- `install-loki` installs Loki as the logs backend for Grafana Explore.
- `install-tempo` installs Tempo as the traces backend for Grafana Explore.
- `install-alloy` installs Grafana Alloy as the shared collector for Kubernetes logs, Kubernetes events, and OTLP traces.
- Twinbox also seeds a small default alert set for Cilium and Longhorn so cluster network and storage health surface in Alertmanager and ntfy automatically, with warning, critical, and emergency alerts pushed to `ntfy.bierineenweek.nl` as different notification priorities.
- `install-grafana` installs Grafana, provisions the Prometheus, Loki, and Tempo datasources automatically, seeds the default Managed Kubernetes Overview plus Twinbox Nodes, Twinbox Workloads, Twinbox Control Plane, Twinbox Storage, Twinbox Logs & Events, Twinbox Logs Detail, Twinbox Network, and Twinbox Traefik dashboards so the cluster starts with usable views for nodes, workloads, control plane, storage, logs, traffic, and ingress without manual UI setup, and stores Grafana's admin credentials alongside the OIDC client secret in OpenBao so Argo CD does not keep regenerating its admin Secret.
- `install-longhorn-storage` installs Longhorn, makes it the default storage class, and configures SeaweedFS S3 as Longhorn's default backup target. Longhorn is configured to run only on worker nodes so storage and CSI components stay off control planes. New Longhorn PVCs inherit the default recurring job group, which creates snapshots every four hours and backups daily.
- `install-secret-sync` installs:
  - External Secrets Operator
  - OpenBao with Raft storage on Longhorn
  - `ClusterSecretStore/openbao`
  - `ExternalSecret/proxmox-bootstrap`
- External Secrets Operator uses its own internal TLS bootstrap for the webhook via `certController`; this is separate from the ingress TLS stack and does not require a user-managed CA.
- `install-cloudnativepg` installs the CloudNativePG operator with two replicas on Longhorn. The operator uses ServerSideApply for its CRDs.

- Authentik uses a `Recreate` deployment strategy so its bootstrap lock is held by only one pod at a time during rollouts. That avoids overlapping startup attempts from old and new pods.
- The `twinbox-automation` service account, its dedicated superuser group, and its non-expiring API token are created declaratively by an Authentik blueprint (`gitops/platform/authentik/blueprint-twinbox-automation.yaml`). The blueprint is mounted as a ConfigMap into the Authentik worker and applied during reconciliation, using `AUTHENTIK_AUTOMATION_TOKEN_KEY` (exposed as an env var via the bootstrap secret) as the token key. This avoids the brittle pattern of calling the Authentik API with the ephemeral bootstrap token after pods become ready.
- `install-authentik-idp` generates `AUTHENTIK_AUTOMATION_TOKEN_KEY`, stores it in OpenBao, and waits for the blueprint to create the service account before proceeding. The token key is persisted to OpenBao as `AUTHENTIK_API_TOKEN`.
- `wizard/setup-wizard.sh` writes the chosen cluster login password to `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json` inside the Management VM so later bootstrap steps can reuse it without prompting again.
- `create-users-and-groups` reads the Authentik bootstrap secret from OpenBao via the shared `authentik-auth.sh` helper, which loads the persistent `AUTHENTIK_API_TOKEN` (created by the blueprint) and uses it for all API calls. It creates the first Authentik user, creates the `admins` group as a superuser group, and adds the user to that group. The automation service account itself is also placed in a dedicated superuser group so it can set passwords and manage group membership during bootstrap.
- All downstream steps that talk to the Authentik API (`install-headlamp`, `install-twinbox-portal`, `install-dashy-dashboard`, `configure-argocd-oidc`, `install-pgadmin4`, `install-management-consoles`) source the bundled `scripts/manager/authentik-auth.sh` helper and call `authentik_ensure_token`. The helper reads the persistent `AUTHENTIK_API_TOKEN` from OpenBao and uses it for all API calls.
- `install-velero-backup` installs Velero together with the SeaweedFS S3 target that runs on the Management VM, syncs `/opt/twinbox/bootstrap/secrets/global/velero.json` into OpenBao, and renders the Argo CD values inline from that bootstrap file. Velero creates a daily cluster backup with 30-day retention.
- `install-management-backup` installs host cron jobs on the Management VM for daily Talos etcd snapshots and daily `/opt/twinbox` restic backups to SeaweedFS. The `/opt/twinbox/seaweedfs/data` directory is excluded so the object store is not backed up into itself.
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

### Namespace baseline

`gitops/platform/namespaces.yaml` is the pre-created namespace baseline for the shared platform overlay. When you add a new app or a new platform manifest that targets a namespace, add that namespace here first.

This avoids Argo CD sync failures like `namespaces "..." not found` when `platform-ingress` or another shared overlay renders a manifest before the app-specific chart has created its own namespace.

Current baseline namespaces:

- `authentik`
- `dashy`
- `homepage`
- `immich`
- `longhorn-system`
- `monitoring`
- `pgadmin4`
- `tailscale`
- `traefik`
- `wiredoor`

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
| Twinbox Portal | `portal.<ZONE_NAME>` |
| Dashy admin launcher | `admin.<ZONE_NAME>` |

Twinbox Portal is the default user landing page. It uses Authentik OIDC in the portal backend, stores per-user preferences in its own PVC-backed store, and renders the app catalog from step metadata plus the cluster step-state into `Secret/portal-config` at runtime.
Dashy remains the legacy admin launcher at `admin.<ZONE_NAME>` for operator tools while the new portal becomes the normal front door for users.
Apps installed through the App Installs flow are rendered in the portal catalog (`portal.<ZONE_NAME>`) for end users and are excluded from Dashy tiles.
The Dashy tile list itself is still not GitOps-static: Twinbox renders operator tiles from step metadata plus the cluster step-state on the Management VM and applies the resulting `ConfigMap/dashy-config` at runtime.

### GitOps structure

```
gitops/platform/
├── kustomization.yaml          # Central Kustomize config for the shared platform shape
├── authentik/ingressroute.yaml # Host match patched by the platform-ingress ApplicationSet
├── grafana/
├── headlamp/ingressroute.yaml  # Host match patched by the platform-ingress ApplicationSet
├── headlamp/externalsecret.yaml # Headlamp OIDC client credentials from OpenBao
├── traefik/
├── wiredoor-gateway/
├── dashy/
└── twinbox-portal/
    ├── portal-config (Secret)   # Runtime-generated portal configuration
    ├── deployment.yaml         # Portal app + API
    ├── externalsecret.yaml     # Portal OIDC + session bootstrap credentials from OpenBao
    ├── ingressroute.yaml       # Host match for portal.<ZONE_NAME>
    ├── namespace.yaml
    ├── pvc.yaml                # Per-user preference storage
    └── service.yaml
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
