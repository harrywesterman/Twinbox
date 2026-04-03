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
10. `provision-nodes` injects the rendered Cilium manifest into the control-plane Talos machine configs as inline manifests, while leaving worker configs CNI-free.
11. `provision-nodes` also sets `cluster.network.cni.name: none`, `cluster.proxy.disabled: true`, `machine.features.kubePrism.enabled: true`, `machine.features.kubePrism.port: 7445`, `machine.features.hostDNS.forwardKubeDNSToHost: false`, and `machine.time.servers: [TWINBOX_TIME_SERVER]`.
12. The management VM bootstrap and maintenance flow pin Ubuntu's `systemd-timesyncd` to the same `TWINBOX_TIME_SERVER` value.
13. The worker waits for `cilium`, `cilium-operator`, and `coredns` to become healthy and verifies that `kube-proxy` is not deployed.
14. `install-argocd` installs Argo CD after the cluster networking layer is already available.
15. `install-longhorn-storage` applies the Longhorn Argo CD application, makes `StorageClass/longhorn` the default, and waits for it to be ready.
16. `install-secret-sync` installs External Secrets Operator and OpenBao, seeds OpenBao from management-local bootstrap JSON, and creates `Secret/proxmox-bootstrap`.
17. `install-velero-backup` deploys Velero, a Twinbox-managed Garage bucket or an external S3-compatible target, and the default backup storage location used for cluster backups.
18. Later wizard steps apply one Argo CD `Application` at a time for Traefik and the remaining workloads.

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
