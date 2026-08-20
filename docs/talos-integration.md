# Talos Integration

Talos lifecycle operations are triggered through the manager stack.

## Deployment Flow

1. The UI executes `provision-nodes`.
2. `manager-api` validates inputs and queues the job.
3. `manager-worker` runs `scripts/manager/apply-cluster.sh`.
4. The worker renders a per-cluster OpenTofu workspace.
5. The worker verifies that the configured Proxmox file datastore allows `import` and `iso` content, then downloads and decompresses the Talos NoCloud disk image. The Image Factory schematic explicitly includes `talos.platform=nocloud` so Talos boots in the datasource mode that reads the attached `cidata` ISO.
6. The worker uploads the disk image as Proxmox `import` content on each node that will host a Talos VM, then renders full Talos machine configs and per-node NoCloud `cidata` ISOs.
7. The worker uploads each `cidata` ISO as normal Proxmox `iso` content on the node that will host the matching VM. Twinbox does not upload custom Proxmox snippets for Talos nodes.
8. OpenTofu creates the VMs, applies the requested VM placement map, imports the Talos image directly into the VM disk through the Proxmox API, and attaches the matching `cidata` ISO.
9. Talos reads its machine config and static network config during first boot, then the worker bootstraps the first control plane through the configured static address.
10. Talos access files are stored as cluster-scoped bootstrap artifacts under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`.
11. `provision-nodes` renders the pinned Cilium Helm chart against the cluster VIP/API endpoint and stores it under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`.
12. The rendered Cilium manifest enables Hubble Relay and the Hubble UI so flow visibility is present as soon as Cilium comes up.
13. `provision-nodes` injects the rendered Cilium manifest into the control-plane Talos machine configs as inline manifests, while leaving worker configs CNI-free.
14. `provision-nodes` also sets `cluster.network.cni.name: none`, `cluster.proxy.disabled: true`, `machine.features.kubePrism.enabled: true`, `machine.features.kubePrism.port: 7445`, `machine.features.hostDNS.forwardKubeDNSToHost: false`, `machine.time.servers: [TWINBOX_TIME_SERVER]`, and node labels that mark control planes and workers explicitly for Longhorn scheduling.
15. The management VM bootstrap and maintenance flow pin Ubuntu's `systemd-timesyncd` to the same `TWINBOX_TIME_SERVER` value.
16. The worker waits for `cilium`, `cilium-operator`, `coredns`, `hubble-relay`, and `hubble-ui` to become healthy and verifies that `kube-proxy` is not deployed.
17. `install-argocd` installs Argo CD after the cluster networking layer is already available.
18. `install-longhorn-storage` applies the Longhorn Argo CD application, makes `StorageClass/longhorn` the default, configures SeaweedFS as the default Longhorn backup target, and installs recurring snapshot/backup jobs for new Longhorn PVCs. Longhorn is configured to run on worker nodes only, so its managers, UI, and CSI components stay off control planes. Twinbox also sets Longhorn's drain policy for maintenance-friendly Talos upgrades on the fixed worker pool.
19. `install-prometheus` installs the kube-prometheus-stack through Argo CD, enabling Prometheus, Alertmanager, node-exporter, and kube-state-metrics on Longhorn-backed storage.
20. `install-loki` installs Loki so Grafana can query cluster logs.
21. `install-tempo` installs Tempo so Grafana can query traces.
22. `install-alloy` installs Grafana Alloy as the shared collection pipeline for logs, events, and traces.
23. `install-grafana` installs Grafana, provisions Prometheus, Loki, and Tempo datasources, and seeds the default observability dashboards.
24. `install-secret-sync` installs External Secrets Operator and OpenBao, seeds OpenBao from management-local bootstrap JSON, and creates `Secret/proxmox-bootstrap`.
25. `install-cloudnativepg` installs the CloudNativePG operator on top of Longhorn so PostgreSQL-backed workloads can share one database platform.
26. `install-authentik-idp` provisions the PostgreSQL cluster for Authentik, installs Authentik, seeds the Authentik bootstrap secret into OpenBao, and deletes the temporary local seed file after sync.
27. `create-users-and-groups` creates the first Authentik user, creates the `admins` group, and adds the user to that group using the Authentik bootstrap secret from OpenBao and the Management VM login password stored under `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`.
28. `install-traefik` installs the Traefik ingress controller through Argo CD.
29. `install-velero-backup` deploys Velero and points it at the SeaweedFS S3 target running on the Management VM as the default backup storage location for daily cluster backups.
30. `install-velero-ui` deploys the Velero UI dashboard on top of the Velero install and gates access through Authentik.
31. `install-management-backup` installs host cron jobs on the Management VM for daily Talos etcd snapshots and daily `/opt/twinbox` restic backups to SeaweedFS.
32. `install-crowdsec` deploys CrowdSec security engine and seeds the Traefik bouncer key into OpenBao.
33. `install-ntfy` deploys the ntfy push notification service for cluster alerts.
34. `install-browser-ssh` deploys Termix browser SSH access and creates the opkssh Authentik OAuth2 application. `install-opkssh` installs opkssh on the Management VM and bastion so admins authenticate with Authentik + MFA.
35. `install-headlamp` deploys the Kubernetes dashboard with native Authentik OIDC login.
36. `install-twinbox-portal` renders the user portal config from step metadata and cluster state, writing it to `Secret/portal-config`.
37. `install-dashy-dashboard` renders the legacy admin launcher config into `ConfigMap/dashy-config`.
38. `install-management-consoles` publishes Proxmox, Longhorn, Forgejo, and SeaweedFS web UIs behind Traefik. Forgejo uses native Authentik/OIDC login; the other management consoles use Authentik proxy protection.
39. `install-pgadmin4` deploys pgAdmin 4 with Longhorn-backed persistence and Authentik OIDC.
40. `configure-argocd-oidc` configures Argo CD to use Authentik for SSO.
41. Later wizard steps apply one Argo CD `Application` at a time for ingress configuration, NetBird, Cloudflare, and user applications.

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
