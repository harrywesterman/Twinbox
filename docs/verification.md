# Verification

Use this checklist after large changes.

## Repo checks

```bash
bash -n wizard/setup-wizard.sh \
  scripts/bootstrap-vm.sh \
  scripts/start-manager.sh \
  scripts/install-management-tools.sh \
  scripts/manager/apply-cluster.sh \
  scripts/manager/bootstrap-talos.sh \
  scripts/manager/create-talos-vms.sh \
  scripts/manager/collect-state.sh \
  scripts/manager/render-cilium-manifest.sh \
  scripts/manager/apply-argocd-application.sh \
  scripts/manager/install-argocd.sh \
  scripts/manager/install-cloudtty.sh \
  scripts/manager/install-longhorn-storage.sh \
  scripts/manager/install-secret-sync.sh \
  scripts/manager/install-velero-backup.sh \
  scripts/manager/openbao-secret-sync.sh \
  scripts/manager/sync-openbao-global-secret.sh \
  ansible/management-vm-maintenance.yml \
  categories/talos-cluster/steps/install-cloudnativepg/run.sh \
  categories/talos-cluster/steps/install-postgres-clusters/run.sh

ansible-playbook --syntax-check -i localhost, -c local ansible/management-vm-maintenance.yml

node --check manager-api/src/server.js
node --check manager-worker/src/worker.js
node --check scripts/manager/upsert-secret-artifact.mjs
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

## Time sync checks

### Management VM

```bash
timedatectl timesync-status
systemctl status systemd-timesyncd --no-pager
```

Expected:

- `systemd-timesyncd` is active
- the configured NTP server matches `TWINBOX_TIME_SERVER`

### Talos cluster

```bash
talosctl get timeservers
talosctl get timestatus
```

Expected:

- each node reports the pinned timeserver in `timeservers`
- each node reports `SYNCED=true` once the cluster is up

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
- Cilium bootstrap manifest exists under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`
- the Talos configs include inline Cilium manifests on all control-plane nodes
- the generated Talos nodes carry `twinbox.io/role=control-plane` and `twinbox.io/role=worker` labels as appropriate
- control-plane VMs are provisioned at `2 GB RAM / 10 GB disk`
- worker VMs keep a larger storage budget that is derived from the selected Proxmox host's free disk space
- the first step in a clean UI session remains `Deploy Talos Cluster`

### `provision-nodes` runtime network checks

```bash
kubectl --kubeconfig <kubeconfig> get ds cilium -n kube-system
kubectl --kubeconfig <kubeconfig> get deploy cilium-operator -n kube-system
kubectl --kubeconfig <kubeconfig> get deploy hubble-relay -n kube-system
kubectl --kubeconfig <kubeconfig> get deploy hubble-ui -n kube-system
kubectl --kubeconfig <kubeconfig> get svc hubble-ui -n kube-system
kubectl --kubeconfig <kubeconfig> get deploy coredns -n kube-system
kubectl --kubeconfig <kubeconfig> get ds kube-proxy -n kube-system
kubectl --kubeconfig <kubeconfig> get ingressroute hubble -n kube-system
```

Expected:

- the rendered Cilium manifest uses the cluster VIP/API endpoint rather than `localhost:7445`
- `daemonset/cilium` is ready
- `deployment/cilium-operator` is ready
- `deployment/hubble-relay` is ready
- `deployment/hubble-ui` is ready
- `service/hubble-ui` exists and serves the UI
- `deployment/coredns` is ready
- `daemonset/kube-proxy` does not exist
- `IngressRoute/hubble` is present in `kube-system`

### `install-cloudtty`

```bash
kubectl --kubeconfig <kubeconfig> get deployment cloudtty-operator-controller-manager -n cloudtty-system
kubectl --kubeconfig <kubeconfig> get cloudshell cloudtty-shell -n cloudtty-system
kubectl --kubeconfig <kubeconfig> get cloudshell cloudtty-shell -n cloudtty-system -o jsonpath='{.status.accessUrl}'
```

Expected:

- the cloudtty operator deployment is ready
- `CloudShell/cloudtty-shell` reports `Ready`
- the shell status exposes a browser-accessible `accessUrl`

### `install-longhorn-storage`

```bash
kubectl --kubeconfig <kubeconfig> get pods -n longhorn-system
kubectl --kubeconfig <kubeconfig> get pods -n longhorn-system -o wide
kubectl --kubeconfig <kubeconfig> get storageclass longhorn
kubectl --kubeconfig <kubeconfig> get storageclass longhorn -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
kubectl --kubeconfig <kubeconfig> get nodes -L twinbox.io/role
```

Expected:

- Longhorn manager and CSI components are running
- Longhorn manager and CSI pods run on worker nodes
- `StorageClass/longhorn` exists
- `StorageClass/longhorn` is marked as the default storage class
- worker nodes are labeled `twinbox.io/role=worker`
- control-plane nodes are labeled `twinbox.io/role=control-plane`

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

- `Application/postgres-clusters` is synced
- CloudNativePG Cluster resources report `Cluster is Ready` with the ready instance count from the manifest
- PgBouncer Pooler deployments are available for read-write and read-only traffic
- ScheduledBackup resources exist for daily backups
- ExternalSecret resources report `Ready=True` after syncing database credentials from OpenBao

Verify database connectivity:

```bash
kubectl --kubeconfig <kubeconfig> cnpg status authentik-db -n databases
```

### `install-pgadmin4`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd pgadmin4
kubectl --kubeconfig <kubeconfig> get pods -n pgadmin4
kubectl --kubeconfig <kubeconfig> get externalsecret -n pgadmin4
kubectl --kubeconfig <kubeconfig> get ingressroute -n pgadmin4
```

Expected:

- `Application/pgadmin4` is synced
- The pgAdmin 4 pod is running with its Longhorn-backed PVC mounted
- `ExternalSecret/pgadmin4-oidc` reports `Ready=True`
- Traefik publishes `pgadmin4.<ZONE_NAME>` through the configured ingress route

### `install-velero-backup`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd velero
kubectl --kubeconfig <kubeconfig> get pods -n velero
kubectl --kubeconfig <kubeconfig> get backupstoragelocation -n velero
kubectl --kubeconfig <kubeconfig> get secret velero-credentials -n velero
kubectl --kubeconfig <kubeconfig> get ingressroute -n longhorn-system seaweedfs seaweedfs-admin
```

Expected:

- Velero server and node-agent are running
- SeaweedFS is running on the Management VM and exposed through Traefik
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
