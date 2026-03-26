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
8. Cluster record is updated with VM IDs, planned and discovered node IPs, state/workdir paths, and secret refs. Talos access files are materialized only for the duration of the job.

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
- If `install-secret-sync` runs, the cluster gets `external-secrets`, a network-isolated Bitwarden CLI bridge, and a first Vaultwarden-backed Kubernetes Secret projection.
