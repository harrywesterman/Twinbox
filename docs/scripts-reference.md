# Manager Scripts Reference

Scripts under `scripts/manager/` are executed by the `manager-worker` container. Each step in `categories/` delegates to one or more of these scripts.

## Cluster Provisioning

### `apply-cluster.sh`

Main provisioning entry point. Creates Talos VMs on Proxmox using OpenTofu.

- Creates a per-cluster OpenTofu workspace under `manager-data/clusters/<cluster-id>/iac/`
- Downloads the pinned Talos ISO and uploads it to Proxmox storage
- Sizes control-plane VMs at `4 GB RAM / 10 GB disk` and gives workers a default `100%` disk budget from the free space shared across the three Proxmox hosts, with a slider to tune it up or down
- Labels Talos nodes with `twinbox.io/role` so worker-only storage components can target the right machines
- Renders VM configuration from the cluster JSON
- Renders the pinned Cilium Helm chart and injects it into Talos control-plane inline manifests
- Enables Hubble Relay and the Hubble UI in the bootstrap Cilium release
- Adds an explicit `machine.time.servers` entry to the generated Talos machine configs
- Stores the Cilium bootstrap manifest under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`
- Runs `tofu init` and `tofu apply`
- Discovers DHCP addresses for created VMs

### `create-talos-vms.sh`

Thin wrapper that delegates directly to `apply-cluster.sh`. The two scripts are functionally equivalent.

### `bootstrap-talos.sh`

Bootstraps the Talos control plane after VMs are provisioned.

- Runs `talosctl bootstrap` against the first control plane node
- Retrieves the kubeconfig with `talosctl kubeconfig`
- Stores kubeconfig as a cluster-scoped secret attachment (`/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/kubeconfig/kubeconfig`)
- Updates cluster state to `bootstrapped`
- Optionally syncs kubeconfig and talosconfig to the `twinbox` user home directory (when `TWINBOX_SYNC_LOCAL_CLIENT_CONFIGS=true`)

### `collect-state.sh`

Reads and outputs the cluster JSON file from `manager-data/clusters/<cluster-id>.json`. Used for state inspection.

## Networking

### `render-cilium-manifest.sh`

Renders the Talos-owned Cilium bootstrap manifest from the pinned Helm chart and repo-owned values file.
When `CILIUM_K8S_SERVICE_HOST` and `CILIUM_K8S_SERVICE_PORT` are set, the helper uses them as the API endpoint override.

### `install-argocd.sh`

Installs Argo CD on the cluster after the Talos/Cilium bootstrap has completed.

### `install-cloudtty.sh`

Installs the Cloudtty operator with Helm and creates a default CloudShell instance exposed through NodePort so operators can open a browser terminal on the cluster.

### `install-traefik-manager.sh`

Refreshes the shared `platform-ingress` Argo CD application so Traefik Manager is deployed as part of the shared platform overlay behind Authentik.

### `install-prometheus.sh`

Installs the kube-prometheus-stack GitOps app, which enables Prometheus, Alertmanager, node-exporter, and kube-state-metrics on Longhorn-backed storage.

### `apply-argocd-application.sh`

Applies a single Argo CD `Application` manifest to the cluster. Used by step scripts that deploy through GitOps.

The Talos step runners for `install-loki`, `install-tempo`, `install-alloy`, and `install-grafana` live under `categories/talos-cluster/steps/*/run.sh` and delegate to `apply-argocd-application.sh`.

### `uninstall-argocd-application.sh`

Removes a single Argo CD `Application` manifest from the cluster. Used by steps that need to clean up or reinstall apps.

### `upsert-argocd-cluster-secret.sh`

Upserts a local Argo CD cluster secret in the `argocd` namespace with the derived public zone name as an annotation. This secret is read by ApplicationSets to project domain names into manifests at render time.

### `cluster-public-zone.sh`

Derives the public zone name from the cluster ID and base domain. Used by steps that need to know whether to use the bare domain (`prd`) or a slug-prefixed hostname (non-`prd`).

## Storage & Secrets

### `install-longhorn-storage.sh`

Installs Longhorn via Argo CD, sets `StorageClass/longhorn` as the default, configures SeaweedFS as the default Longhorn backup target, and installs recurring Longhorn snapshot/backup jobs.

### `install-secret-sync.sh`

Bootstraps the management secrets layer for GitOps:

- Applies the `external-secrets` and `openbao` Argo CD Applications
- Renders OpenBao values file to `gitops/values/openbao.yaml` (seal key ID, replicas, Raft config)
- Seeds OpenBao static seal secret (`kubectl create secret`)
- Bootstraps management JSON files (proxmox, traefik-dashboard, seal key)

External Secrets Operator is deployed from `gitops/apps/external-secrets.yaml`. OpenBao is applied from a generated Argo CD `Application` manifest that inlines the rendered Helm values so the local bootstrap output is authoritative during install.
ESO's webhook TLS bootstrap is handled internally by its `certController`; Twinbox does not provide ingress-style certificates for this step.

### `openbao-secret-sync.sh`

Shared library for OpenBao lifecycle operations. Provides functions for:

- Rendering OpenBao Helm values to `gitops/values/openbao.yaml` (`openbao_render_values_file`)
- Seeding management bootstrap files
- Seeding the OpenBao static seal Kubernetes secret
- Initializing OpenBao and configuring Kubernetes auth
- Syncing global secrets from JSON files into OpenBao's KV store
- Applying `ClusterSecretStore` and `ExternalSecret` resources

### `sync-openbao-global-secret.sh`

Syncs a specific global secret item from the filesystem into OpenBao.

## Backup

### `install-velero-backup.sh`

Installs Velero with the SeaweedFS S3 target running on the Management VM and a daily cluster backup schedule.

### `install-management-backup.sh`

Installs the Management VM host cron jobs that create daily Talos etcd snapshots and daily restic backups of `/opt/twinbox` into SeaweedFS. The backup excludes `/opt/twinbox/seaweedfs/data`.

### `install-velero-ui.sh`

Installs Velero UI, provisions its Authentik OIDC application, syncs the bootstrap secret into OpenBao, and applies the Velero UI Argo CD application and Traefik ingress route.

## Observability

### `diagnose-monitoring.sh`

Runs diagnostics against the monitoring stack. Checks Prometheus, Alertmanager, Grafana, and related component health. Useful for troubleshooting observability issues.

### `reconcile-observability.sh`

Reconciles the observability stack state. Ensures Prometheus rules, Grafana datasources, and dashboard ConfigMaps are in sync with the expected configuration.

### `refresh-grafana-dashboard.mjs`

Node.js script that refreshes Grafana dashboards from the repo-owned definitions. Updates existing dashboards without full reinstallation.

### `render-grafana-dashboard.mjs`

Node.js script that renders a Grafana dashboard JSON from template inputs. Used during the Grafana installation step to inject cluster-specific values.

## Security

### `authentik-auth.sh`

Shared helper for all steps that interact with the Authentik API.

- Reads the persistent `AUTHENTIK_API_TOKEN` from OpenBao
- Provides `authentik_ensure_token` for token refresh
- Used by `install-headlamp`, `install-twinbox-portal`, `install-dashy-dashboard`, `configure-argocd-oidc`, `install-pgadmin4`, `install-management-consoles`, and `create-users-and-groups`

## Utility

### `upsert-secret-artifact.mjs`

Node.js script that writes or updates a secret file attachment. Used by bootstrap and provisioning scripts to persist runtime artifacts (kubeconfig, talosconfig, talos secrets).

```
Usage: upsert-secret-artifact.mjs --scope <scope> --item <item> --attachment <name> --source <path> [--cluster-id <id>]
```

### `sync-pgadmin4-server.sh`

Syncs pgAdmin 4 server configurations into the running pgAdmin instance. Connects to the PostgreSQL clusters discovered in the `databases` namespace and registers them as managed servers.

## Environment

All scripts expect:

| Variable | Purpose |
|----------|---------|
| `MANAGER_DATA_DIR` | Root of the `manager-data/` tree |
| `WORKSPACE_ROOT` | Path to the Twinbox checkout (`/opt/twinbox`) |
| `TWINBOX_BOOTSTRAP_DIR` | Root of the bootstrap secrets tree |
| `TWINBOX_TIME_SERVER` | NTP server pinned by the management VM and Talos configs |
