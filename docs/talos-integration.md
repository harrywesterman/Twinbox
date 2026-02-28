# Talos Integration

Talos lifecycle operations are triggered through the manager stack.

## Provisioning Flow

1. UI submits `POST /api/clusters`.
2. API validates payload and writes queue record.
3. Worker executes `scripts/manager/create-talos-vms.sh`.
4. Script calls Proxmox API to create/start Talos VMs.
5. Cluster record is updated with VM IDs and planned IPs.

## Bootstrap Flow

1. UI submits `POST /api/clusters/{cluster_id}/bootstrap`.
2. Worker executes `scripts/manager/bootstrap-talos.sh`.
3. Script runs:
   - `talosctl gen config`
   - `talosctl apply-config` (control-plane + worker)
   - `talosctl bootstrap`
   - `talosctl kubeconfig`
4. Cluster record is updated with config directory path.

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

## Environment Dependencies

At runtime, worker scripts require:

- Proxmox access env vars from `.env`
- CLI tools expected by scripts (`bash`, `curl`, `jq`, and for bootstrap also `talosctl`)

## Outputs

- Cluster metadata in `manager-data/clusters/`.
- Job metadata in `manager-data/jobs/`.
- Job logs in `manager-data/logs/`.
