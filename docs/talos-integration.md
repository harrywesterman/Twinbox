# Talos Integration

Talos lifecycle operations are triggered through the manager stack.

## Deployment Flow

1. UI submits `POST /api/clusters`.
2. API validates payload and writes queue record.
3. Worker executes `scripts/manager/apply-cluster.sh`.
4. Script renders a per-cluster OpenTofu workspace and tfvars payload.
5. The worker downloads the Talos disk image locally, then OpenTofu uploads/imports it into Proxmox and creates the VMs.
6. The worker discovers the DHCP addresses, generates per-node Talos configs, applies them with `talosctl`, bootstraps the first control plane, and fetches kubeconfig.
7. Cluster record is updated with VM IDs, planned and discovered node IPs, state/workdir paths, and kubeconfig metadata.

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
- Talos configs and kubeconfig in `manager-data/clusters/<cluster_id>/talos/`.
- Cluster state stores planned and discovered node IPs plus the kubeconfig path.
