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
   - `scripts/manager/render-cilium-manifest.sh`
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
3. `provision-nodes` renders the pinned Cilium Helm chart against the cluster VIP/API endpoint, stores the bootstrap manifest under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/`, and injects it as an inline manifest into every control-plane Talos config.
4. `provision-nodes` sets `cluster.network.cni.name: none`, `cluster.proxy.disabled: true`, `machine.features.kubePrism.enabled: true`, and `machine.features.hostDNS.forwardKubeDNSToHost: false` so Talos boots with kube-proxy-free Cilium from the start.
5. `provision-nodes` waits for `cilium`, `cilium-operator`, and `coredns` to become ready before the step completes.
6. `install-argocd` installs Argo CD after the Talos/Cilium bootstrap has completed.
7. `install-longhorn-storage` runs before cluster secret sync so stateful workloads and backup storage can use Longhorn PVCs immediately through the cluster default storage class.
8. `install-secret-sync` installs External Secrets Operator and OpenBao on Longhorn.
9. `install-secret-sync` seeds OpenBao from the Management VM bootstrap files and creates `ClusterSecretStore/openbao`.
10. `install-velero-backup` deploys Velero together with a Twinbox-managed Garage bucket or an external S3-compatible backup target.
11. `install-cloudnativepg` installs the CloudNativePG operator on top of Longhorn so PostgreSQL-backed workloads can share one database platform.
12. `install-postgres-clusters` deploys the CloudNativePG Cluster, Pooler, ScheduledBackup, and ExternalSecret resources for each application database and seeds the Authentik database credentials into OpenBao early so the cluster can bootstrap before the Authentik app step runs.
13. Authentik uses a `Recreate` rollout strategy so its bootstrap lock is only held by one pod at a time during upgrades and restarts.
14. GitOps apps consume secrets through `ExternalSecret` resources backed by `ClusterSecretStore/openbao`.

## Domain Flow

All platform services share a single base domain (`ZONE_NAME`) provided by the user during the **Choose Ingress Route** wizard step. Twinbox prefixes the cluster slug for non-`prd` public hostnames, keeps the special `app.example.com` exception for `prd`, and follows the canonical policy in [docs/ingress-policy.md](./ingress-policy.md). Cloudflare Tunnel is only offered for `prd` on Cloudflare Free.

1. **User input** — The user enters the base domain (e.g. `example.com`) in the web wizard.
2. **Filesystem storage** — `choose-ingress-route/run.sh` writes `ZONE_NAME`, `WIREDOOR_FQDN`, and `WILDCARD_FQDN` to `/opt/twinbox/bootstrap/secrets/global/cloudflare-<cluster-id>.json`.
3. **OpenBao sync** — The same script calls `sync-openbao-global-secret.sh` to push these values to OpenBao at `twinbox/global/cluster-hostnames`.
4. **ExternalSecret** — The `cluster-config` ExternalSecret reads `ZONE_NAME` from OpenBao and creates a Kubernetes Secret in the `argocd` namespace.
5. **Rendered ConfigMap** — The ingress/domain step renders `gitops/platform/cluster-config/configmap.yaml` with the cluster-prefixed public zone name and the full route strings needed by the platform manifests.
6. **Kustomize replacements** — The `platform-ingress` Argo CD application deploys `gitops/platform/` via Kustomize, which copies the rendered route expressions and homepage strings into the live manifests.

The `cluster-config` application must sync before `platform-ingress` so the rendered ConfigMap exists when Kustomize performs replacements.

## Runtime Guarantees

- Queue recovery marks orphaned `running` jobs as failed on worker startup.
- Step state is cluster-scoped for Talos cluster journeys.
- Talos configs and kubeconfigs are runtime artifacts, not canonical files under `manager-data/`.
- OpenBao uses static auto-unseal material stored on the Management VM for zero-touch restarts.
- The first visible setup step in the UI is `Deploy Talos Cluster`.
