# Architecture

Twinbox is a complete K8s cluster based on Talos Linux, completely configured. The Management VM is the control point for bootstrap, queueing, and long-lived bootstrap material.

## Layers

1. **Wizard layer**
   - `wizard/setup-wizard.sh`
   - Runs on Proxmox and creates only the Management VM.

2. **Manager runtime layer**
   - `manager-web`
   - `manager-api`
   - `manager-worker`
   - `categories/`

3. **Execution layer**
   - `scripts/manager/apply-cluster.sh`
   - `scripts/manager/bootstrap-talos.sh`
   - `scripts/manager/create-talos-vms.sh`
   - `scripts/manager/collect-state.sh`
   - `scripts/manager/install-flannel.sh`
   - `scripts/manager/apply-argocd-application.sh`
   - `scripts/manager/install-argocd.sh`
   - `scripts/manager/install-longhorn-storage.sh`
   - `scripts/manager/install-secret-sync.sh`
   - `scripts/manager/install-velero-backup.sh`
   - `scripts/manager/openbao-secret-sync.sh`
   - `scripts/manager/sync-openbao-global-secret.sh`
   - `scripts/manager/upsert-secret-artifact.mjs`
   - `categories/*/steps/*/run.sh`

4. **State layer**
   - `manager-data/clusters/*.json`
   - `manager-data/jobs/*.json`
   - `manager-data/logs/*.log`
   - `manager-data/queue/{pending,running,completed}/*.json`
   - `manager-data/step-state/global/*.json`
   - `manager-data/step-state/clusters/<cluster-id>/*.json`

5. **Bootstrap secret layer**
   - `/opt/twinbox/bootstrap/secrets/global/*.json`
   - `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/...`
   - `/opt/twinbox/bootstrap/openbao/seal/*`
   - `/opt/twinbox/bootstrap/openbao/init/*`

## Request Flow

1. `manager-web` loads `/api/catalog`.
2. The UI executes a step through `POST /api/steps/{step_id}/execute`.
3. `manager-api` validates inputs, persists state, and writes a queue file.
4. `manager-worker` moves the job to `queue/running`, executes the repo-owned script, streams logs, and finalizes state.
5. The UI polls job and catalog state.

## Secret Flow

1. The Management VM bootstraps local JSON files under `/opt/twinbox/bootstrap/secrets/global/`.
2. `provision-nodes` materializes Talos runtime files from the local bootstrap tree and cluster-scoped attachments.
3. `install-flannel` bootstraps pod networking so the cluster can run the Argo CD control plane.
4. `install-argocd` installs Argo CD and starts tracking Flannel through a GitOps `Application`.
5. `install-longhorn-storage` runs before cluster secret sync so stateful workloads and backup storage can use Longhorn PVCs immediately through the cluster default storage class.
6. `install-secret-sync` installs External Secrets Operator and OpenBao on Longhorn.
7. `install-secret-sync` seeds OpenBao from the Management VM bootstrap files and creates `ClusterSecretStore/openbao`.
8. `install-velero-backup` deploys Velero together with a Twinbox-managed Garage bucket or an external S3-compatible backup target.
9. `install-cloudnativepg` installs the CloudNativePG operator on top of Longhorn so PostgreSQL-backed workloads can share one database platform.
10. `install-postgres-clusters` deploys the CloudNativePG Cluster, Pooler, ScheduledBackup, and ExternalSecret resources for each application database.
11. GitOps apps consume secrets through `ExternalSecret` resources backed by `ClusterSecretStore/openbao`.

## Runtime Guarantees

- Queue recovery marks orphaned `running` jobs as failed on worker startup.
- Step state is cluster-scoped for Talos cluster journeys.
- Talos configs and kubeconfigs are runtime artifacts, not canonical files under `manager-data/`.
- OpenBao uses static auto-unseal material stored on the Management VM for zero-touch restarts.
- The first visible setup step in the UI is `Deploy Talos Cluster`.
