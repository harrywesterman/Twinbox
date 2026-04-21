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
  scripts/manager/install-longhorn-storage.sh \
  scripts/manager/install-prometheus.sh \
  scripts/manager/diagnose-monitoring.sh \
  categories/talos-cluster/steps/install-loki/run.sh \
  categories/talos-cluster/steps/install-tempo/run.sh \
  categories/talos-cluster/steps/install-alloy/run.sh \
  categories/talos-cluster/steps/install-grafana/run.sh \
  scripts/manager/install-secret-sync.sh \
  scripts/manager/install-velero-backup.sh \
  scripts/manager/openbao-secret-sync.sh \
  scripts/manager/sync-openbao-global-secret.sh \
  ansible/management-vm-maintenance.yml \
   categories/talos-cluster/steps/install-cloudnativepg/run.sh

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

## Manager image assets

```bash
docker exec twinbox-manager-worker find /opt/twinbox/categories -maxdepth 4 -type f -name run.sh | sort
docker exec twinbox-manager-worker find /opt/twinbox/scripts/manager -maxdepth 2 -type f | sort
```

Expected:

- the worker image carries the step catalog under `/opt/twinbox/categories`
- the manager images carry the shared manager helpers under `/opt/twinbox/scripts/manager`
- step debugging happens against container paths, not a host-side repo checkout

## Step checks

### `provision-nodes`

- queue and logs are written under `manager-data/`
- cluster state exists under `manager-data/clusters/<cluster-id>.json`
- Talos artifacts are materialized under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`
- Cilium bootstrap manifest exists under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`
- the Talos configs include inline Cilium manifests on all control-plane nodes
- the generated Talos nodes carry `twinbox.io/role=control-plane` and `twinbox.io/role=worker` labels as appropriate
- control-plane VMs are provisioned at `4 GB RAM / 10 GB disk`
- worker VMs keep a larger storage budget that is derived from the selected Proxmox host's free disk space
- the first step in a clean UI session remains `Deploy Talos Cluster`

### `install-prometheus`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd prometheus
kubectl --kubeconfig <kubeconfig> get pods -n monitoring
kubectl --kubeconfig <kubeconfig> get ingressroute -n monitoring
kubectl --kubeconfig <kubeconfig> get prometheusrule -n monitoring cluster-health-alerts pvc-usage-alerts
kubectl --kubeconfig <kubeconfig> get configmap -n monitoring kubernetes-overview-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}'
kubectl --kubeconfig <kubeconfig> get configmap -n monitoring node-exporter-full-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}'
kubectl --kubeconfig <kubeconfig> get configmap -n monitoring longhorn-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}'
kubectl --kubeconfig <kubeconfig> get configmap -n monitoring cilium-metrics-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}'
kubectl --kubeconfig <kubeconfig> get configmap -n monitoring hubble-metrics-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}'
```

Expected:

- `Application/prometheus` is synced and healthy
- Prometheus, Alertmanager, node-exporter, and kube-state-metrics pods are running in `monitoring`
- Prometheus ingress routes exist once the domain-aware platform ingress is applied
- `PrometheusRule/cluster-health-alerts` and `PrometheusRule/pvc-usage-alerts` exist in `monitoring`
- `ConfigMap/kubernetes-overview-dashboard` exists and is labeled for Grafana dashboard sidecar discovery
- `ConfigMap/node-exporter-full-dashboard` exists and is labeled for Grafana dashboard sidecar discovery
- `ConfigMap/longhorn-dashboard` exists and is labeled for Grafana dashboard sidecar discovery
- `ConfigMap/cilium-metrics-dashboard` exists and is labeled for Grafana dashboard sidecar discovery
- `ConfigMap/hubble-metrics-dashboard` exists and is labeled for Grafana dashboard sidecar discovery

### `install-loki`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd loki
kubectl --kubeconfig <kubeconfig> get pods -n monitoring -l app.kubernetes.io/name=loki
kubectl --kubeconfig <kubeconfig> get pvc -n monitoring -l app=loki
```

Expected:

- `Application/loki` is synced and healthy
- Loki pods are running in `monitoring`
- Longhorn-backed Loki PVCs are bound

### `install-tempo`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd tempo
kubectl --kubeconfig <kubeconfig> get pods -n monitoring -l app.kubernetes.io/name=tempo
kubectl --kubeconfig <kubeconfig> get svc -n monitoring -l app.kubernetes.io/name=tempo
```

Expected:

- `Application/tempo` is synced and healthy
- Tempo pods are running in `monitoring`
- The Tempo service is available on port `3200`

### `install-alloy`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd alloy
kubectl --kubeconfig <kubeconfig> get pods -n monitoring -l app.kubernetes.io/name=alloy
kubectl --kubeconfig <kubeconfig> get svc -n monitoring -l app.kubernetes.io/name=alloy
```

Expected:

- `Application/alloy` is synced and healthy
- Alloy is running in `monitoring`
- Alloy exposes OTLP and HTTP ports for log, event, and trace collection

### `install-grafana`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd grafana
kubectl --kubeconfig <kubeconfig> get pods -n monitoring -l app.kubernetes.io/name=grafana
kubectl --kubeconfig <kubeconfig> get configmap -n monitoring -l grafana_dashboard=1
kubectl --kubeconfig <kubeconfig> get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}'
```

Expected:

- `Application/grafana` is synced and healthy
- Grafana is running in `monitoring`
- Grafana provisions the Prometheus, Loki, and Tempo datasources
- The seeded Kubernetes Overview, Node Exporter Full, Longhorn, Cilium Metrics, and Hubble Metrics dashboard ConfigMaps exist and are discovered by the sidecar

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
kubectl --kubeconfig <kubeconfig> get application -n argocd platform-ingress
kubectl --kubeconfig <kubeconfig> get pods -n pgadmin4
kubectl --kubeconfig <kubeconfig> get externalsecret -n pgadmin4
kubectl --kubeconfig <kubeconfig> get ingressroute -n pgadmin4
```

Expected:

- `Application/platform-ingress` is synced
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
- The Velero backup storage location points at the configured SeaweedFS endpoint

### `install-velero-ui`

```bash
kubectl --kubeconfig <kubeconfig> get application -n argocd velero-ui
kubectl --kubeconfig <kubeconfig> get pods -n velero-ui
kubectl --kubeconfig <kubeconfig> get externalsecret -n velero-ui velero-ui-bootstrap
kubectl --kubeconfig <kubeconfig> get secret velero-ui-bootstrap -n velero-ui
kubectl --kubeconfig <kubeconfig> get ingressroute -n velero-ui
```

Expected:

- `Application/velero-ui` is synced and healthy
- the Velero UI deployment is running in the `velero-ui` namespace
- the generated Velero UI bootstrap secret exists in the `velero-ui` namespace
- the Velero UI ingress route points at `velero-ui.__ZONE_NAME__`
- only members of the `admins` group can authorize the Authentik application

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
