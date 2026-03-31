# Verification

Use this checklist after large changes.

## Repo checks

```bash
bash -n wizard/setup-wizard.sh \
  scripts/bootstrap-vm.sh \
  scripts/start-manager.sh \
  scripts/install-management-tools.sh \
  scripts/manager/apply-cluster.sh \
  scripts/manager/install-flannel.sh \
  scripts/manager/apply-argocd-application.sh \
  scripts/manager/install-longhorn-storage.sh \
  scripts/manager/install-secret-sync.sh \
  scripts/manager/install-velero-backup.sh \
  scripts/manager/openbao-secret-sync.sh \
  scripts/manager/sync-openbao-global-secret.sh \
  categories/talos-cluster/steps/install-cloudnativepg/run.sh \
  categories/talos-cluster/steps/install-postgres-clusters/run.sh

node --check manager-api/src/server.js
node --check manager-worker/src/worker.js
docker compose config
```

## Manager runtime

```bash
docker compose ps
curl -fsS http://localhost:8080/api/health
```

Expected:

- `manager-web`, `manager-api`, and `manager-worker` are running
- API health returns success

## Bootstrap tree

```bash
find /opt/twinbox/bootstrap -maxdepth 3 -type f | sort
```

Expected:

- global bootstrap JSON exists for Proxmox and Traefik
- OpenBao seal files exist
- OpenBao init files appear after `install-secret-sync`

## Step checks

### `provision-nodes`

- queue and logs are written under `manager-data/`
- cluster state exists under `manager-data/clusters/<cluster-id>.json`
- Talos artifacts are materialized under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`
- the first step in a clean UI session remains `Deploy Talos Cluster`

### `install-longhorn-storage`

```bash
kubectl --kubeconfig <kubeconfig> get pods -n longhorn-system
kubectl --kubeconfig <kubeconfig> get storageclass longhorn
kubectl --kubeconfig <kubeconfig> get storageclass longhorn -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
```

Expected:

- Longhorn manager and CSI components are running
- `StorageClass/longhorn` exists
- `StorageClass/longhorn` is marked as the default storage class

### `install-traefik`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd traefik
kubectl --kubeconfig <kubeconfig> get ingressroute -A
```

Expected:

- `Application/traefik` is healthy
- Argo CD and Traefik dashboard routes exist

### `install-secret-sync`

```bash
kubectl --kubeconfig <kubeconfig> get pods -n external-secrets
kubectl --kubeconfig <kubeconfig> get pods -n openbao
kubectl --kubeconfig <kubeconfig> get clustersecretstore openbao
kubectl --kubeconfig <kubeconfig> get externalsecret -n twinbox-system
kubectl --kubeconfig <kubeconfig> get secret proxmox-bootstrap -n twinbox-system
```

Expected:

- External Secrets Operator is running
- OpenBao is running on Longhorn
- `ClusterSecretStore/openbao` exists
- `Secret/proxmox-bootstrap` exists in `twinbox-system`

### `install-cloudnativepg`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd cloudnativepg
kubectl --kubeconfig <kubeconfig> get pods -n cnpg-system
```

Expected:

- `Application/cloudnativepg` is healthy
- Two CloudNativePG operator pods are running in `cnpg-system`
- CRDs `clusters.postgresql.cnpg.io` and `poolers.postgresql.cnpg.io` exist

### `install-postgres-clusters`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd postgres-clusters
kubectl --kubeconfig <kubeconfig> get cluster -n databases
kubectl --kubeconfig <kubeconfig> get pooler -n databases
kubectl --kubeconfig <kubeconfig> get scheduledbackup -n databases
kubectl --kubeconfig <kubeconfig> get externalsecret -n databases
```

Expected:

- `Application/postgres-clusters` is healthy
- CloudNativePG Cluster resources are in `Cluster in healthy state` with 3 ready instances
- PgBouncer Pooler resources exist for read-write and read-only traffic
- ScheduledBackup resources exist for daily backups
- ExternalSecret resources have synced database credentials from OpenBao

Verify database connectivity:

```bash
kubectl --kubeconfig <kubeconfig> cnpg status authentik-db -n databases
```

### `install-velero-backup`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd velero
kubectl --kubeconfig <kubeconfig> get application -n argocd garage
kubectl --kubeconfig <kubeconfig> get pods -n velero
kubectl --kubeconfig <kubeconfig> get backupstoragelocation -n velero
kubectl --kubeconfig <kubeconfig> get secret velero-credentials -n velero
```

Expected:

- Velero server and node-agent are running
- The Garage deployment is running and initialized
- `BackupStorageLocation/default` is ready
- The generated Velero credentials secret exists in the `velero` namespace

### OpenBao restart check

```bash
kubectl --kubeconfig <kubeconfig> delete pod -n openbao -l app.kubernetes.io/instance=openbao
kubectl --kubeconfig <kubeconfig> get pods -n openbao -w
```

Expected:

- OpenBao pod comes back without manual unseal work

## Queue recovery

- A stale file in `manager-data/queue/running/` is marked failed on worker startup
- The marker is moved to `queue/completed/`
