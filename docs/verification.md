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
  scripts/manager/openbao-secret-sync.sh \
  scripts/manager/sync-openbao-global-secret.sh

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

### `install-longhorn-storage`

```bash
kubectl --kubeconfig <kubeconfig> get pods -n longhorn-system
kubectl --kubeconfig <kubeconfig> get storageclass longhorn
```

Expected:

- Longhorn manager and CSI components are running
- `StorageClass/longhorn` exists

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
