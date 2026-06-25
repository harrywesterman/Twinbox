# Scripts

Shell and Node.js scripts for provisioning, bootstrapping, and managing the Twinbox cluster.

## Structure

```
scripts/
├── bootstrap-vm.sh                 # Bootstrap the Management VM (thin cloud-init / Ansible flow)
├── install-management-vm-maintenance.sh # Install the Management VM maintenance systemd timer
├── start-manager.sh                # Start the manager stack (load .env, start docker compose)
├── get-talos-image-factory.sh      # Fetch or resolve Talos image from the Image Factory
├── install-management-tools.sh     # Install talosctl, tofu, kubectl, helm on the Management VM
├── management-vm-maintenance.sh     # Run apt patching and host hardening through Ansible
├── manager-web-preview.sh          # Local dev helper for manager-web
├── wizard-dev-run.sh               # Local dev helper for the wizard
├── ssh-connection/                 # SSH connection helpers (empty, placeholder)
└── manager/                        # Worker-executed provisioning scripts
    ├── apply-cluster.sh            # Full cluster apply (OpenTofu + Talos bootstrap)
    ├── apply-argocd-application.sh # Apply an ArgoCD Application manifest
    ├── authentik-auth.sh           # Authentik authentication helpers
    ├── bootstrap-talos.sh          # Bootstrap Talos control plane
    ├── cluster-public-zone.sh      # Determine public DNS zone for a cluster
    ├── collect-state.sh            # Collect cluster state after provisioning
    ├── create-talos-vms.sh         # Create Talos VMs on Proxmox
    ├── diagnose-monitoring.sh      # Diagnose monitoring stack health
    ├── install-argocd.sh           # Install Argo CD
    ├── setup-termix-authentik.sh    # Configure Termix OIDC and the browser SSH app
    ├── setup-termix.sh             # Bootstrap the Termix Management VM host access
    ├── install-longhorn-storage.sh # Install Longhorn storage
    ├── install-management-backup.sh # Install Management VM backup cron
    ├── install-prometheus.sh       # Install Prometheus monitoring stack
    ├── install-secret-sync.sh      # Install External Secrets Operator + OpenBao
    ├── install-traefik-manager.sh  # Install Traefik Manager UI
    ├── install-velero-backup.sh    # Install Velero backup
    ├── openbao-secret-sync.sh      # Sync secrets to OpenBao
    ├── reconcile-observability.sh  # Reconcile observability profile (full/minimal/off)
    ├── refresh-grafana-dashboard.mjs # Refresh Grafana dashboards on demand
    ├── render-cilium-manifest.sh    # Render the inline Cilium/Hubble bootstrap manifest with optional API endpoint overrides
    ├── render-grafana-dashboard.mjs # Render Grafana dashboard JSON
    ├── sync-openbao-global-secret.sh # Sync global secrets
    ├── sync-pgadmin4-server.sh     # Sync pgAdmin 4 server registration
    ├── uninstall-argocd-application.sh # Remove an Argo CD Application
    ├── upsert-argocd-cluster-secret.sh # Upsert Argo CD cluster secret
    └── upsert-secret-artifact.mjs  # Node.js helper to upsert secret artifacts
```

## Top-Level Scripts

| Script | Purpose |
|--------|---------|
| `bootstrap-vm.sh` | First-run script for the Management VM: seeds runtime files, fetches the bootstrap playbook tree when needed, installs the Ansible-driven host baseline, creates `.env`, and bootstraps the manager stack once. |
| `install-management-vm-maintenance.sh` | Installs and enables the systemd timer that runs the Management VM maintenance playbook. |
| `start-manager.sh` | Loads `.env`, materializes bootstrap files if needed, and starts the manager stack via `docker compose`. Use `--bootstrap-once` for the initial deployment path. |
| `get-talos-image-factory.sh` | Queries the Talos Image Factory for a schematic ID, download URL, or shell command. Supports `--preset`, `--version`, `--arch`, `--platform`, `--output`. |
| `install-management-tools.sh` | Installs `talosctl`, `tofu`, `kubectl`, `helm`, and `restic` with versions pinned from `config/pinned-defaults.sh` where applicable. |
| `management-vm-maintenance.sh` | Installs `ansible-core` if needed and runs the Management VM maintenance playbook from the bootstrap tree. The playbook keeps the VM on the pinned NTP server, Docker, and the management tools. |
| `manager-web-preview.sh` | Dev helper for previewing `manager-web`. |
| `wizard-dev-run.sh` | Dev helper for running the setup wizard locally. |

## `manager/` Scripts

These scripts are executed by `manager-worker` during job processing. They are called by the worker with environment variables for secrets, cluster parameters, and data directories.

| Script | Purpose |
|--------|---------|
| `apply-cluster.sh` | Orchestrates the full cluster lifecycle: runs OpenTofu, applies control planes first, bootstraps, then applies workers. |
| `apply-argocd-application.sh` | Applies a single ArgoCD Application YAML. |
| `authentik-auth.sh` | Authentik authentication and session helpers. |
| `bootstrap-talos.sh` | Applies Talos machine configs and bootstraps the first control plane node. |
| `cluster-public-zone.sh` | Determines the public DNS zone for a cluster based on slug and ingress choice. |
| `collect-state.sh` | Collects kubeconfig and Talos config after provisioning. |
| `create-talos-vms.sh` | Runs `tofu apply` to create Talos VMs on Proxmox. |
| `diagnose-monitoring.sh` | Diagnoses Prometheus, Grafana, and Alloy health and connectivity. |
| `install-argocd.sh` | Installs Argo CD into the cluster. |
| `setup-termix-authentik.sh` | Configures Termix OIDC and publishes the browser SSH app. |
| `setup-termix.sh` | Creates the Management VM host credential, host entry, and Browser SSH role. |
| `install-longhorn-storage.sh` | Deploys Longhorn and sets the default StorageClass. |
| `install-management-backup.sh` | Installs host cron jobs for Talos etcd snapshots and `/opt/twinbox` restic backups. |
| `install-prometheus.sh` | Deploys Prometheus, Alertmanager, node-exporter, and kube-state-metrics. |
| `install-secret-sync.sh` | Deploys External Secrets Operator and OpenBao. |
| `install-traefik-manager.sh` | Deploys the Traefik Manager browser UI. |
| `install-velero-backup.sh` | Deploys Velero for cluster backups. |
| `openbao-secret-sync.sh` | Syncs application secrets into OpenBao. |
| `reconcile-observability.sh` | Reconciles the observability profile (full, minimal, or off) for the active cluster. |
| `refresh-grafana-dashboard.mjs` | Refreshes Grafana dashboards via the Kubernetes API. |
| `render-cilium-manifest.sh` | Renders the Talos-owned Cilium bootstrap manifest, including Hubble Relay and Hubble UI, from the pinned Helm chart. |
| `render-grafana-dashboard.mjs` | Renders Grafana dashboard JSON for a given cluster. |
| `sync-openbao-global-secret.sh` | Syncs global secrets into OpenBao. |
| `sync-pgadmin4-server.sh` | Syncs pgAdmin 4 server registration for databases. |
| `uninstall-argocd-application.sh` | Removes an Argo CD Application and its resources. |
| `upsert-argocd-cluster-secret.sh` | Upserts an Argo CD cluster secret for external cluster registration. |
| `upsert-secret-artifact.mjs` | Node.js helper to write secret artifacts to the filesystem store. |
