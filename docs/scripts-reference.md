# Manager Scripts Reference

Scripts under `scripts/manager/` are executed by the `manager-worker` container. Each step in `categories/` delegates to one or more of these scripts.

## Cluster Provisioning

### `apply-cluster.sh`

Main provisioning entry point. Creates Talos VMs on Proxmox using OpenTofu.

- Creates a per-cluster OpenTofu workspace under `manager-data/clusters/<cluster-id>/iac/`
- Downloads the pinned Talos ISO and uploads it to Proxmox storage
- Renders VM configuration from the cluster JSON
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

### `install-flannel.sh`

Bootstraps Flannel CNI directly on the cluster so pods can run before Argo CD is installed.

### `install-argocd.sh`

Installs Argo CD on the cluster and registers the Flannel Application for GitOps tracking.

### `apply-argocd-application.sh`

Applies a single Argo CD `Application` manifest to the cluster. Used by step scripts that deploy through GitOps.

## Storage & Secrets

### `install-longhorn-storage.sh`

Installs Longhorn via Argo CD and sets `StorageClass/longhorn` as the default.

### `install-secret-sync.sh`

Installs External Secrets Operator and OpenBao:

- Deploys External Secrets Operator
- Deploys OpenBao with Raft storage on Longhorn
- Seeds OpenBao from bootstrap JSON files
- Creates `ClusterSecretStore/openbao`

### `openbao-secret-sync.sh`

Synchronizes secrets from the Management VM bootstrap files into OpenBao.

### `sync-openbao-global-secret.sh`

Syncs a specific global secret item from the filesystem into OpenBao.

## Backup

### `install-velero-backup.sh`

Installs Velero with either the embedded Garage bucket or an external S3-compatible target.

## Utility

### `upsert-secret-artifact.mjs`

Node.js script that writes or updates a secret file attachment. Used by bootstrap and provisioning scripts to persist runtime artifacts (kubeconfig, talosconfig, talos secrets).

```
Usage: upsert-secret-artifact.mjs --scope <scope> --item <item> --attachment <name> --source <path> [--cluster-id <id>]
```

## Environment

All scripts expect:

| Variable | Purpose |
|----------|---------|
| `MANAGER_DATA_DIR` | Root of the `manager-data/` tree |
| `WORKSPACE_ROOT` | Path to the Twinbox checkout (`/opt/twinbox`) |
| `TWINBOX_BOOTSTRAP_DIR` | Root of the bootstrap secrets tree |
