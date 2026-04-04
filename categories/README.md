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

## Categories

### management-vm (order: 10)

Steps for configuring the Management VM itself.

- `configure-automatic-updates` – Nightly Ubuntu patching and hardening via cron.
- `install-k9s` – Install the K9s terminal UI.

### talos-cluster (order: 20)

Steps for provisioning the Talos Kubernetes cluster and deploying platform services.

- `provision-nodes` – Create Talos VMs on Proxmox, apply machine configs, bootstrap.
- `install-argocd` – Deploy Argo CD.
- `install-longhorn-storage` – Deploy Longhorn and set default StorageClass.
- `install-cloudnativepg` – Deploy CloudNativePG operator.
- `install-cloudtty` – Deploy Cloudtty and open a browser shell on the cluster.
- `install-traefik-manager` – Deploy Traefik Manager for browser-based reverse-proxy management.
- `install-prometheus` – Deploy Prometheus, Alertmanager, node-exporter, and kube-state-metrics.
- `install-postgres-clusters` – Create Postgres clusters from templates.
- `install-traefik` – Deploy Traefik ingress controller.
- `install-secret-sync` – Deploy External Secrets Operator and OpenBao.
- `install-authentik-idp` – Deploy Authentik identity provider.
- `create-users-and-groups` – Create the first Authentik user and `admins` group.
- `choose-ingress-route` – Choose the ingress branch for this cluster.
- `configure-argocd-oidc` – Connect Argo CD to Authentik for OIDC login.
- `install-grafana` – Deploy Grafana monitoring dashboard.
- `install-headlamp` – Deploy Headlamp Kubernetes dashboard.
- `install-pgadmin4` – Deploy pgAdmin 4 for PostgreSQL administration.
- `install-dashy-dashboard` – Deploy Dashy as the cluster start page.
- `install-management-consoles` – Deploy the operator web consoles, including SeaweedFS, after the start page.
- `install-ntfy` – Deploy ntfy push notifications.
- `install-velero-backup` – Deploy Velero with the default SeaweedFS backup target.
- `install-whoami` – Deploy whoami test service.
- `install-wiredoor-gateway` – Deploy Wiredoor gateway.
- `install-uptimekuma` – Deploy Uptime Kuma monitoring.
- `install-nextcloud` – Deploy Nextcloud.
- `install-immich` – Deploy Immich photo management.
- `install-gitea` – Deploy Gitea.
- `install-n8n` – Deploy n8n automation.
- `install-audiobookshelf` – Deploy Audiobookshelf.
- `install-freshrss` – Deploy FreshRSS.
- `install-jitsi` – Deploy Jitsi Meet.
- `install-karakeep` – Deploy Karakeep.
- `install-paperless` – Deploy Paperless-ngx.
- `install-zulip` – Deploy Zulip.
- `install-proxmox-backup-system` – Deploy Proxmox Backup Server integration.
- `configure-cloudflare-dns` – Configure Cloudflare DNS records.
- `provision-wiredoor-bastion` – Provision the Wiredoor bastion host.
