# Scripts

Shell and Node.js scripts for provisioning, bootstrapping, and managing the Twinbox cluster.

## Structure

```
scripts/
├── bootstrap-vm.sh                 # Bootstrap the Management VM (clone repo, install Docker, start compose)
├── start-manager.sh                # Start the manager stack (load .env, start docker compose)
├── get-talos-image-factory.sh      # Fetch or resolve Talos image from the Image Factory
├── install-management-tools.sh     # Install talosctl, tofu, kubectl, helm on the Management VM
├── manager-web-preview.sh          # Local dev helper for manager-web
├── wizard-dev-run.sh               # Local dev helper for the wizard
├── ssh-connection/                 # SSH connection helpers (empty, placeholder)
└── manager/                        # Worker-executed provisioning scripts
    ├── apply-cluster.sh            # Full cluster apply (OpenTofu + Talos bootstrap)
    ├── create-talos-vms.sh         # Create Talos VMs on Proxmox
    ├── bootstrap-talos.sh          # Bootstrap Talos control plane
    ├── collect-state.sh            # Collect cluster state after provisioning
    ├── install-argocd.sh           # Install Argo CD
    ├── apply-argocd-application.sh # Apply an ArgoCD Application manifest
    ├── install-flannel.sh          # Install Flannel CNI
    ├── install-longhorn-storage.sh # Install Longhorn storage
    ├── install-secret-sync.sh      # Install External Secrets Operator + OpenBao
    ├── install-velero-backup.sh    # Install Velero backup
    ├── openbao-secret-sync.sh      # Sync secrets to OpenBao
    ├── sync-openbao-global-secret.sh # Sync global secrets
    └── upsert-secret-artifact.mjs  # Node.js helper to upsert secret artifacts
```

## Top-Level Scripts

| Script | Purpose |
|--------|---------|
| `bootstrap-vm.sh` | First-run script for the Management VM: clones Twinbox, installs Docker CE, creates `.env`, starts `docker compose`. |
| `start-manager.sh` | Loads `.env` and starts the manager stack via `docker compose`. |
| `get-talos-image-factory.sh` | Queries the Talos Image Factory for a schematic ID, download URL, or shell command. Supports `--preset`, `--version`, `--arch`, `--platform`, `--output`. |
| `install-management-tools.sh` | Installs `talosctl`, `tofu`, `kubectl`, and `helm` with versions pinned from `config/pinned-defaults.sh`. |
| `manager-web-preview.sh` | Dev helper for previewing `manager-web`. |
| `wizard-dev-run.sh` | Dev helper for running the setup wizard locally. |

## `manager/` Scripts

These scripts are executed by `manager-worker` during job processing. They are called by the worker with environment variables for secrets, cluster parameters, and data directories.

| Script | Purpose |
|--------|---------|
| `apply-cluster.sh` | Orchestrates the full cluster lifecycle: runs OpenTofu, discovers IPs, applies Talos machine configs, bootstraps. |
| `create-talos-vms.sh` | Runs `tofu apply` to create Talos VMs on Proxmox. |
| `bootstrap-talos.sh` | Applies Talos machine configs and bootstraps the first control plane node. |
| `collect-state.sh` | Collects kubeconfig and Talos config after provisioning. |
| `install-argocd.sh` | Installs Argo CD into the cluster. |
| `apply-argocd-application.sh` | Applies a single ArgoCD Application YAML. |
| `install-flannel.sh` | Deploys Flannel CNI via ArgoCD. |
| `install-longhorn-storage.sh` | Deploys Longhorn and sets the default StorageClass. |
| `install-secret-sync.sh` | Deploys External Secrets Operator and OpenBao. |
| `install-velero-backup.sh` | Deploys Velero for cluster backups. |
| `openbao-secret-sync.sh` | Syncs application secrets into OpenBao. |
| `sync-openbao-global-secret.sh` | Syncs global secrets into OpenBao. |
| `upsert-secret-artifact.mjs` | Node.js helper to write secret artifacts to the filesystem store. |
