# Talos Integration

Talos lifecycle operations are triggered through the manager stack.

## Deployment Flow

1. UI submits `POST /api/clusters`.
2. API validates payload and writes queue record.
3. Worker executes `scripts/manager/apply-cluster.sh`.
4. Script renders a per-cluster OpenTofu workspace and tfvars payload.
5. OpenTofu downloads the Talos Image Factory asset on demand, uploads NoCloud snippets, creates Proxmox VMs, applies Talos machine configs, bootstraps the first control plane, and fetches kubeconfig.
6. Cluster record is updated with VM IDs, static node IPs, state/workdir paths, and kubeconfig metadata.

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

- Proxmox access env vars from `.env`
- CLI tools expected by scripts (`bash`, `jq`, `tofu`, `talosctl`)

## Outputs

- Cluster metadata in `manager-data/clusters/`.
- Job metadata in `manager-data/jobs/`.
- Job logs in `manager-data/logs/`.
- Per-cluster OpenTofu workdirs and state in `manager-data/clusters/<cluster_id>/iac/`.
