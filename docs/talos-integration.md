# Talos Integration

Talos lifecycle operations are triggered through the manager stack.

## Deployment Flow

1. The UI executes `provision-nodes`.
2. `manager-api` validates inputs and queues the job.
3. `manager-worker` runs `scripts/manager/apply-cluster.sh`.
4. The worker renders a per-cluster OpenTofu workspace.
5. The worker verifies that the configured Proxmox file datastore allows both `import` and `snippets` content, then downloads and decompresses the Talos NoCloud disk image.
6. The worker uploads the disk image as Proxmox `import` content on each node that will host a Talos VM, then asks OpenTofu to import that image directly into the VM disk through the Proxmox API.
7. OpenTofu uploads the generated Talos machine configs and static NoCloud network data as Proxmox `snippets`, creates the VMs, and applies the requested VM placement map.
8. The worker waits for the Talos API at the configured static addresses, applies configs with `talosctl`, and bootstraps the first control plane.
9. Talos access files are stored as cluster-scoped bootstrap artifacts under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`.
10. `provision-nodes` renders the pinned Cilium Helm chart against the cluster VIP/API endpoint and stores it under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`.
11. The rendered Cilium manifest enables Hubble Relay and the Hubble UI so flow visibility is present as soon as Cilium comes up.
12. `provision-nodes` injects the rendered Cilium manifest into the control-plane Talos machine configs as inline manifests, while leaving worker configs CNI-free.
13. `provision-nodes` also sets `cluster.network.cni.name: none`, `cluster.proxy.disabled: true`, `machine.features.kubePrism.enabled: true`, `machine.features.kubePrism.port: 7445`, `machine.features.hostDNS.forwardKubeDNSToHost: false`, `machine.time.servers: [TWINBOX_TIME_SERVER]`, and node labels that mark control planes and workers explicitly for Longhorn scheduling.
14. The management VM bootstrap and maintenance flow pin Ubuntu's `systemd-timesyncd` to the same `TWINBOX_TIME_SERVER` value.
15. The worker waits for `cilium`, `cilium-operator`, `coredns`, `hubble-relay`, and `hubble-ui` to become healthy and verifies that `kube-proxy` is not deployed.
16. `install-argocd` installs Argo CD after the cluster networking layer is already available.
17. `install-longhorn-storage` applies the Longhorn Argo CD application, makes `StorageClass/longhorn` the default, configures SeaweedFS as the default Longhorn backup target, and installs recurring snapshot/backup jobs for new Longhorn PVCs. Longhorn is configured to run on worker nodes only, so its managers, UI, and CSI components stay off control planes. Twinbox also sets Longhorn's drain policy for maintenance-friendly Talos upgrades on the fixed worker pool.
18. `install-prometheus` installs the kube-prometheus-stack through Argo CD, enabling Prometheus, Alertmanager, node-exporter, and kube-state-metrics on Longhorn-backed storage.
19. `install-loki` installs Loki so Grafana can query cluster logs.
20. `install-tempo` installs Tempo so Grafana can query traces.
21. `install-alloy` installs Grafana Alloy as the shared collection pipeline for logs, events, and traces.
22. `install-grafana` installs Grafana, provisions Prometheus, Loki, and Tempo datasources, and seeds the default observability dashboards.
23. `install-secret-sync` installs External Secrets Operator and OpenBao, seeds OpenBao from management-local bootstrap JSON, and creates `Secret/proxmox-bootstrap`.
24. `install-cloudnativepg` installs the CloudNativePG operator on top of Longhorn so PostgreSQL-backed workloads can share one database platform.
25. `install-authentik-idp` provisions the PostgreSQL cluster for Authentik, installs Authentik, seeds the Authentik bootstrap secret into OpenBao, and deletes the temporary local seed file after sync.
26. `create-users-and-groups` creates the first Authentik user, creates the `admins` group, and adds the user to that group using the Authentik bootstrap secret from OpenBao and the Management VM login password stored under `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`.
27. `install-traefik` installs the Traefik ingress controller through Argo CD.
28. `install-velero-backup` deploys Velero and points it at the SeaweedFS S3 target running on the Management VM as the default backup storage location for daily cluster backups.
29. `install-velero-ui` deploys the Velero UI dashboard on top of the Velero install and gates access through Authentik.
30. `install-management-backup` installs host cron jobs on the Management VM for daily Talos etcd snapshots and daily `/opt/twinbox` restic backups to SeaweedFS.
31. `install-crowdsec` deploys CrowdSec security engine and seeds the Traefik bouncer key into OpenBao.
32. `install-ntfy` deploys the ntfy push notification service for cluster alerts.
33. `install-browser-ssh` deploys Termix browser SSH access and creates the opkssh Authentik OAuth2 application. `install-opkssh` installs opkssh on the Management VM and bastion so admins authenticate with Authentik + MFA.
34. `install-headlamp` deploys the Kubernetes dashboard with native Authentik OIDC login.
35. `install-twinbox-portal` renders the user portal config from step metadata and cluster state, writing it to `Secret/portal-config`.
36. `install-dashy-dashboard` renders the legacy admin launcher config into `ConfigMap/dashy-config`.
37. `install-management-consoles` publishes Proxmox, Longhorn, Forgejo, and SeaweedFS web UIs behind Traefik. Forgejo uses native Authentik/OIDC login; the other management consoles use Authentik proxy protection.
38. `install-pgadmin4` deploys pgAdmin 4 with Longhorn-backed persistence and Authentik OIDC.
39. `configure-argocd-oidc` configures Argo CD to use Authentik for SSO.
40. Later wizard steps apply one Argo CD `Application` at a time for ingress configuration, NetBird, Cloudflare, and user applications.

## Ingress Configuration Steps

After the core platform, ingress routes are configured based on user choice:

| Ingress | Steps | Description |
|---------|-------|-------------|
| **Cloudflare Tunnel** | `configure-cloudflare-tunnel` | Outbound tunnel (prd-only on Free) |
| **NetBird** | `provision-netbird-bastion` → `configure-netbird-ingress` → `install-netbird-routing-peers` → `configure-netbird-admin-access` | Self-hosted WireGuard VPN |

## Runtime Dependencies

- Proxmox settings from `.env`
- Bootstrap file tree under `/opt/twinbox/bootstrap`
- CLI tooling in the worker image: `bash`, `curl`, `jq`, `openssl`, `tofu`, `talosctl`, `kubectl`, `helm`
- Host backup tooling on the Management VM: `restic`

## Outputs

- Cluster metadata in `manager-data/clusters/`
- Job metadata in `manager-data/jobs/`
- Job logs in `manager-data/logs/`
- Per-cluster OpenTofu workdirs in `manager-data/clusters/<cluster-id>/iac/`
- Cluster-scoped Talos artifacts in `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`

## Notes

- Talos configs and kubeconfigs are runtime artifacts, not canonical files under `manager-data/`.
- OpenBao is the runtime secret backend for cluster workloads after `install-secret-sync`.
- Kubernetes secrets remain derived outputs of External Secrets Operator.
- The `twinbox-automation` service account and its non-expiring API token are created declaratively by an Authentik blueprint, avoiding brittle bootstrap token calls.
- All downstream steps that talk to the Authentik API source the bundled `scripts/manager/authentik-auth.sh` helper.
