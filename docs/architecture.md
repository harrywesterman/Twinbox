# Architecture

Twinbox is a complete K8s cluster based on Talos Linux, completely configured. The Management VM is the control point for bootstrap, queueing, and long-lived bootstrap material.

GitHub `main` is the source of truth for both the management stack and the GitOps manifests. The Management VM is a runtime host that keeps only runtime data under `/opt/twinbox`; the host no longer depends on a persistent repo checkout.

## Layers

1. **Wizard layer**
   - `wizard/setup-wizard.sh`
   - Runs on Proxmox and creates only the Management VM.

2. **Manager runtime layer**
  - `manager-web`
  - `manager-api`
  - `manager-worker`
  - `categories/`
  - Management VM runtime files under `/opt/twinbox`

3. **Execution layer**
   - `scripts/manager/apply-cluster.sh`
   - `scripts/manager/bootstrap-talos.sh`
   - `scripts/manager/create-talos-vms.sh`
   - `scripts/manager/collect-state.sh`
   - `scripts/manager/render-cilium-manifest.sh`
   - `scripts/manager/apply-argocd-application.sh`
   - `scripts/manager/install-argocd.sh`
   - `scripts/manager/install-cloudtty.sh`
   - `scripts/manager/install-longhorn-storage.sh`
   - `scripts/manager/install-prometheus.sh`
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
2. `provision-nodes` sizes control-plane VMs at `2 GB RAM / 10 GB disk`, sizes workers separately with a storage-oriented disk budget derived from host free space, and labels Talos nodes with `twinbox.io/role`.
3. `provision-nodes` materializes Talos runtime files from the local bootstrap tree and cluster-scoped attachments.
4. `provision-nodes` renders the pinned Cilium Helm chart against the cluster VIP/API endpoint, stores the bootstrap manifest under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/`, and injects it as an inline manifest into every control-plane Talos config.
5. The Cilium bootstrap enables Hubble Relay and the Hubble UI so network flows are visible from the first cluster boot.
6. `provision-nodes` sets `cluster.network.cni.name: none`, `cluster.proxy.disabled: true`, `machine.features.kubePrism.enabled: true`, and `machine.features.hostDNS.forwardKubeDNSToHost: false` so Talos boots with kube-proxy-free Cilium from the start.
7. `provision-nodes` waits for `cilium`, `cilium-operator`, and `coredns` to become ready before the step completes.
8. `install-argocd` installs Argo CD after the Talos/Cilium bootstrap has completed.
9. `install-cloudtty` installs the Cloudtty operator with Helm and creates a default browser shell against the same cluster.
10. `install-longhorn-storage` runs before cluster secret sync so stateful workloads and backup storage can use Longhorn PVCs immediately through the cluster default storage class, and Longhorn stays on worker nodes through the `twinbox.io/role=worker` selector.
11. `install-prometheus` installs the kube-prometheus-stack through Argo CD, enabling Prometheus, Alertmanager, node-exporter, and kube-state-metrics on Longhorn-backed storage.
12. `install-secret-sync` installs External Secrets Operator and OpenBao on Longhorn.
13. `install-secret-sync` seeds OpenBao from the Management VM bootstrap files and creates `ClusterSecretStore/openbao`.
14. `install-velero-backup` deploys Velero together with a Twinbox-managed Garage bucket or an external S3-compatible backup target.
15. `install-cloudnativepg` installs the CloudNativePG operator on top of Longhorn so PostgreSQL-backed workloads can share one database platform.
16. `install-postgres-clusters` deploys the CloudNativePG Cluster, Pooler, ScheduledBackup, and ExternalSecret resources for each application database, then waits on the concrete database resources instead of Argo CD aggregate app health before the Authentik app step runs.
17. Authentik uses a `Recreate` rollout strategy so its bootstrap lock is only held by one pod at a time during upgrades and restarts.
18. The Proxmox wizard stores the cluster login password in `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json` inside the Management VM so the Authentik onboarding step can reuse it.
19. `install-authentik-idp` seeds the Authentik bootstrap secret into OpenBao and removes the temporary local seed file after sync.
20. Later Authentik consumers read the bootstrap data from OpenBao instead of reopening `/opt/twinbox/bootstrap/secrets/global/authentik.json`.
21. `install-pgadmin4` provisions the pgAdmin 4 Authentik OIDC application, seeds the pgAdmin bootstrap secret into OpenBao, and deploys pgAdmin with Longhorn-backed persistence and Traefik ingress.
22. GitOps apps consume secrets through `ExternalSecret` resources backed by `ClusterSecretStore/openbao`.

## Domain Flow

All platform services share a single base domain (`ZONE_NAME`) provided by the user during the **Choose Ingress Route** wizard step. Twinbox prefixes the cluster slug for non-`prd` public hostnames, uses the base DNS domain directly for `prd`, and follows the canonical policy in [docs/ingress-policy.md](./ingress-policy.md). Cloudflare Tunnel is only offered for `prd` on Cloudflare Free.

1. **User input** — The user enters the base domain (e.g. `example.com`) in the web wizard.
2. **Filesystem storage** — `choose-ingress-route/run.sh` writes `ZONE_NAME`, `WIREDOOR_FQDN`, and `WILDCARD_FQDN` to `/opt/twinbox/bootstrap/secrets/global/cloudflare-<cluster-id>.json`.
3. **OpenBao sync** — The same script calls `sync-openbao-global-secret.sh` to push these values to OpenBao at `twinbox/global/cluster-hostnames`.
4. **Argo cluster secret** — The ingress/domain step upserts a local Argo CD cluster secret in the `argocd` namespace with the derived public zone name as an annotation.
5. **ApplicationSets** — The `platform-ingress`, `grafana`, and `ntfy` ApplicationSets read the cluster annotation at render time and project the domain into Kustomize patches or Helm values.
6. **Kustomize render** — The `platform-ingress` ApplicationSet deploys `gitops/platform/` via Kustomize, which patches the live route expressions and homepage strings before sync.

The local Argo cluster secret must exist before the domain-aware ApplicationSets are applied.

## Runtime Guarantees

- Queue recovery marks orphaned `running` jobs as failed on worker startup.
- Step state is cluster-scoped for Talos cluster journeys.
- Talos configs and kubeconfigs are runtime artifacts, not canonical files under `manager-data/`.
- Management VM edits under `/opt/twinbox` are temporary unless they are committed and pushed back to GitHub `main`.
- OpenBao uses static auto-unseal material stored on the Management VM for zero-touch restarts.
- The Management VM runs SeaweedFS in Docker as the default S3 target for Velero backups.
- The Management VM does not need a Twinbox repository checkout; cloud-init seeds `/opt/twinbox` and Ansible maintains the host from there.
- The first visible setup step in the UI is `Deploy Talos Cluster`.
