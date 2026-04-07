# Talos Integration

Talos lifecycle operations are triggered through the manager stack.

## Deployment Flow

1. The UI executes `provision-nodes`.
2. `manager-api` validates inputs and queues the job.
3. `manager-worker` runs `scripts/manager/apply-cluster.sh`.
4. The worker renders a per-cluster OpenTofu workspace.
5. The worker downloads the Talos ISO locally and uploads it to each Proxmox node that will host a Talos VM.
6. OpenTofu creates the VMs and applies the requested VM placement map.
7. The worker discovers DHCP addresses, generates Talos configs, applies them with `talosctl`, and bootstraps the first control plane.
8. Talos access files are stored as cluster-scoped bootstrap artifacts under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`.
9. `provision-nodes` renders the pinned Cilium Helm chart against the cluster VIP/API endpoint and stores it under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`.
10. The rendered Cilium manifest enables Hubble Relay and the Hubble UI so flow visibility is present as soon as Cilium comes up.
11. `provision-nodes` injects the rendered Cilium manifest into the control-plane Talos machine configs as inline manifests, while leaving worker configs CNI-free.
12. `provision-nodes` also sets `cluster.network.cni.name: none`, `cluster.proxy.disabled: true`, `machine.features.kubePrism.enabled: true`, `machine.features.kubePrism.port: 7445`, `machine.features.hostDNS.forwardKubeDNSToHost: false`, `machine.time.servers: [TWINBOX_TIME_SERVER]`, and node labels that mark control planes and workers explicitly for Longhorn scheduling.
13. The management VM bootstrap and maintenance flow pin Ubuntu's `systemd-timesyncd` to the same `TWINBOX_TIME_SERVER` value.
14. The worker waits for `cilium`, `cilium-operator`, `coredns`, `hubble-relay`, and `hubble-ui` to become healthy and verifies that `kube-proxy` is not deployed.
15. `install-argocd` installs Argo CD after the cluster networking layer is already available.
16. `install-cloudtty` installs Cloudtty and creates a browser shell on the cluster so operators can open an interactive terminal from the same environment.
17. `install-longhorn-storage` applies the Longhorn Argo CD application, makes `StorageClass/longhorn` the default, and waits for it to be ready. Longhorn is configured to run on worker nodes only, so its managers, UI, and CSI components stay off control planes.
18. `install-secret-sync` installs External Secrets Operator and OpenBao, seeds OpenBao from management-local bootstrap JSON, and creates `Secret/proxmox-bootstrap`.
 19. `install-authentik-idp` provisions the PostgreSQL cluster for Authentik, installs Authentik, seeds the Authentik bootstrap secret into OpenBao, and deletes the temporary local seed file after sync.
20. `create-users-and-groups` creates the first Authentik user, creates the `admins` group, and adds the user to that group using the Authentik bootstrap secret from OpenBao and the Management VM login password stored under `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`.
21. `install-velero-backup` deploys Velero and points it at the SeaweedFS S3 target running on the Management VM as the default backup storage location for cluster backups.
22. Later wizard steps apply one Argo CD `Application` at a time for Traefik and the remaining workloads.

## Runtime Dependencies

- Proxmox settings from `.env`
- Bootstrap file tree under `/opt/twinbox/bootstrap`
- CLI tooling in the worker image: `bash`, `curl`, `jq`, `openssl`, `tofu`, `talosctl`, `kubectl`, `helm`

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
