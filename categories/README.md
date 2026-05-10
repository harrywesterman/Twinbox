# Categories

Manifest-driven step catalog for the Twinbox web wizard. Each category groups related provisioning and configuration steps that the UI presents in order.

## Structure

```
categories/
├── management-vm/
│   ├── category.yaml
│   └── steps/
│       ├── configure-automatic-updates/
│       └── install-k9s/
└── talos-cluster/
    ├── category.yaml
    └── steps/
        ├── provision-nodes/
        ├── install-argocd/
        ├── install-longhorn-storage/
        └── ... (30+ steps)
```

## `category.yaml`

Defines the category metadata:

| Field | Description |
|-------|-------------|
| `id` | Unique identifier |
| `title` | Display name |
| `summary` | Short description |
| `order` | Numeric sort order for the wizard |

## `step.yaml`

Each step directory contains a `step.yaml` manifest and a runner script.

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (matches directory name) |
| `title` | Display name |
| `type` | `action` (provision/deploy) or `config` (settings) |
| `journey_stage` | Workflow stage (`setup`, `manage`) |
| `order` | Numeric sort order within the category |
| `summary` | Short description |
| `explanation` | Detailed explanation for the UI |
| `side_help` | Contextual help text |
| `depends_on` | Array of prerequisite step IDs |
| `inputs` | Typed input parameters with labels, defaults, constraints, and help text |
| `secrets.files` | Secret references with `scope`, `item`, `attachment`, `format` |
| `runner.script` | Relative path to the shell script to execute |

## Bundle manifests

Bundle manifests live in `categories/apps/bundles/` and are loaded into the app catalog when the manager API asks for bundle definitions.

| Field | Description |
|-------|-------------|
| `id` | Unique bundle identifier |
| `title` | Display name |
| `summary` | Short description |
| `description` | Optional long-form text explaining the bundles purpose, origin, and included apps. Supports markdown-style formatting (paragraphs separated by blank lines, `**bold**` section headers). |
| `order` | Numeric sort order in the catalog |
| `apps` | Array of app step ids that the bundle installs |
| `iconUrl` | Optional bundle artwork |
| `iconAlt` | Optional accessible label for the artwork |

## Categories

### management-vm (order: 10)

Steps for configuring the Management VM itself.

- `configure-automatic-updates` – Nightly Ubuntu patching and hardening via cron.
- `install-k9s` – Install the K9s terminal UI.

### talos-cluster (order: 20)

Steps for provisioning the Talos Kubernetes cluster and deploying platform services.

See [categories/talos-cluster/README.md](talos-cluster/README.md) for the full step reference.

### apps (order: 30)

Standalone applications that can be installed on top of the cluster through the Twinbox Portal.

See [categories/apps/README.md](apps/README.md) for the full app catalog.

- `provision-nodes` – Create Talos VMs on Proxmox, apply machine configs, bootstrap.
- `install-argocd` – Deploy Argo CD.
- `install-longhorn-storage` – Deploy Longhorn, set default StorageClass, and configure recurring SeaweedFS backups.
- `install-crowdsec` – Deploy CrowdSec security engine and Traefik bouncer key plumbing.
- `install-cloudnativepg` – Deploy CloudNativePG operator.
- `install-prometheus` – Deploy Prometheus, Alertmanager, node-exporter, and kube-state-metrics.
- `install-traefik` – Deploy Traefik ingress controller.
- `install-secret-sync` – Deploy External Secrets Operator and OpenBao.
- `install-authentik-idp` – Deploy Authentik identity provider.
- `create-users-and-groups` – Create the first Authentik user and `admins` group.
- `choose-ingress-route` – Choose the ingress branch for this cluster.
- `configure-argocd-oidc` – Connect Argo CD to Authentik for OIDC login.
- `install-loki` – Deploy Loki log aggregation backend for Grafana.
- `install-tempo` – Deploy Tempo trace storage and query backend for Grafana.
- `install-alloy` – Deploy Grafana Alloy as the shared logs, events, and traces collector.
- `install-grafana` – Deploy Grafana monitoring dashboard and seed the default observability datasources and dashboards.
- `install-headlamp` – Deploy Headlamp Kubernetes dashboard.
- `install-pgadmin4` – Deploy pgAdmin 4 for PostgreSQL administration.
- `install-twinbox-portal` – Deploy the main Twinbox user portal with apps, settings, intranet, and status.
- `install-dashy-dashboard` – Deploy Dashy as the legacy admin launcher.
- `install-management-consoles` – Deploy the operator web consoles, including SeaweedFS, after the user portal.
- `install-ntfy` – Deploy ntfy push notifications.
- `install-velero-backup` – Deploy Velero with the default SeaweedFS backup target.
- `install-velero-ui` – Deploy the Velero UI dashboard for backup operations.
- `install-management-backup` – Install Management VM cron backups for Talos etcd snapshots and `/opt/twinbox`.
- `install-wiredoor-gateway` – Deploy Wiredoor gateway.
- `provision-netbird-bastion` – Provision the self-hosted NetBird VPS.
- `configure-netbird-ingress` – Configure NetBird SSO, routing groups, and setup keys.
- `install-netbird-routing-peers` – Deploy NetBird routing peers to Kubernetes.
- `configure-netbird-admin-access` – Enroll the Management VM as a NetBird admin peer.
- `configure-cloudflare-dns` – Configure Cloudflare DNS records.
- `configure-cloudflare-tunnel` – Configure Cloudflare Tunnel for external access.
- `configure-metallb-ingress` – Configure MetalLB load balancer for bare-metal ingress.
- `configure-tailscale-ingress` – Configure Tailscale VPN ingress.
- `configure-wiredoor-ingress` – Configure Wiredoor VPN ingress.
- `install-alloy` – Deploy Grafana Alloy as the shared telemetry collector.
- `install-tempo` – Deploy Tempo trace storage and query backend for Grafana.
- `provision-wiredoor-bastion` – Provision the Wiredoor bastion host.
