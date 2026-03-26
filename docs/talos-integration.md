# Talos Integration

Talos lifecycle operations are triggered through the manager stack.

## Deployment Flow

1. UI submits `POST /api/clusters`.
2. API validates payload and writes queue record.
3. Worker executes `scripts/manager/apply-cluster.sh`.
4. Script renders a per-cluster OpenTofu workspace and tfvars payload.
5. The worker downloads the Talos disk image locally, then OpenTofu uploads/imports it into Proxmox and creates the VMs.
6. The worker discovers the DHCP addresses, generates per-node Talos configs, applies them with `talosctl`, bootstraps the first control plane, and materializes the runtime Talos access files from Vaultwarden-backed refs.
7. The optional `install-secret-sync` follow-up step installs External Secrets Operator, deploys a Bitwarden CLI bridge against Vaultwarden, and creates the first SecretStore/ExternalSecret pair inside the cluster.
8. The separate `install-argocd` follow-up installs Argo CD, patches the Argo workloads with the standard control-plane tolerations needed for a single-node Talos control plane, and applies the bootstrap root Application from `gitops/argocd/bootstrap/root.yaml`. That root Application is intentionally limited to safe non-secret workloads such as `whoami` and `headlamp`; anything that depends on Vaultwarden-backed material should stay behind the ESO/Bitwarden path.
9. Cluster record is updated with VM IDs, planned and discovered node IPs, state/workdir paths, and secret refs. Talos access files are materialized only for the duration of the job.

## Compatibility Rerun

- `POST /api/clusters/{cluster_id}/bootstrap` now queues the same `apply_cluster` job type as a compatibility resume hook.
- The primary UI no longer exposes a separate bootstrap step.

## Input Fields

Provisioning request body includes:

- `name`
- `controlplane_count`
- `worker_count`
- `cpu_cores`
- `memory_mb`
- `disk_gb`
- `bridge`
- `start_vmid`
- `vip_ip`
- `start_ip`
- `node_prefix_length`
- `gateway_ip`
- `dns_servers`
- `dns_domain`

## Environment Dependencies

At runtime, worker scripts require:

- Proxmox access env vars from `.env` for bootstrap and secret resolution
- Vaultwarden access through the local secret broker for Talos file materialization
- CLI tools expected by scripts (`bash`, `jq`, `tofu`, `talosctl`)

## Outputs

- Cluster metadata in `manager-data/clusters/`.
- Job metadata in `manager-data/jobs/`.
- Job logs in `manager-data/logs/`.
- Per-cluster OpenTofu workdirs and state in `manager-data/clusters/<cluster_id>/iac/`.
- Talos access files are materialized into a temporary runtime directory and cleaned up after the job.
- Cluster state stores planned and discovered node IPs plus secret refs, not Talos file paths.
- If `install-secret-sync` runs, the cluster gets `external-secrets`, a network-isolated Bitwarden CLI bridge, and a first Vaultwarden-backed Kubernetes Secret projection. The install path tolerates the standard control-plane `NoSchedule` taint so single-node Talos clusters can run the secret-sync stack.
- If `install-argocd` runs, Argo CD is installed as a separate follow-up after ESO/Bitwarden, the Argo workloads are patched with control-plane tolerations, and the bootstrap root Application is applied from `gitops/argocd/bootstrap/root.yaml`. The root Application only manages safe non-secret workloads like `whoami` and `headlamp`, and those bootstrap workloads also carry the standard control-plane tolerations so they can schedule on a single-node Talos control plane.
