# Configuration

Runtime configuration is loaded from root `.env`.

## Required Variables

```dotenv
PROXMOX_HOST=192.168.1.10
PROXMOX_PORT=8006
PROXMOX_USER=root@pam
PROXMOX_PASSWORD=change-me
PROXMOX_NODE=pve
PROXMOX_STORAGE_POOL=local-lvm
PROXMOX_FILE_DATASTORE=local
KUBECTL_VERSION=v1.30.0
HELM_VERSION=v3.15.4
TWINBOX_IMAGE_TAG=latest
```

Tooling version notes:

- `kubectl` and `helm` come from `.env`.
- `tofu` and `talosctl` versions are pinned in `config/pinned-defaults.sh`.
- The management VM host install script and `manager-worker` resolve Talos images through `scripts/get-talos-image-factory.sh`, then download the resulting disk image locally before handing it to OpenTofu.
- To refresh a Talos Factory schematic or build a future-version URL, use `scripts/get-talos-image-factory.sh` with `--preset vanilla` or `--preset qemu-guest-agent`.
- The provisioning flow defaults to `qemu-guest-agent` so Proxmox can keep `QEMU Guest Agent` enabled on the Talos VMs.

## Cluster Payload Validation

`POST /api/clusters` validates core fields before queueing a job:

- `name`: non-empty string
- `bridge`: non-empty string
- `controlplane_count`: integer `1..15`
- `worker_count`: integer `0..200`
- `cpu_cores`: integer `1..64`
- `memory_mb`: integer `512..1048576`
- `disk_gb`: integer `10..8192`
- `start_vmid`: integer `100..999999`
- `vip_ip`: valid IPv4
- `start_ip`: valid IPv4
- `node_prefix_length`: integer `1..32`
- `gateway_ip`: valid IPv4
- `dns_servers`: comma-separated IPv4 list or IPv4 array
- `dns_domain`: non-empty string

## Compose Services

- `manager-web` on port `3000` (`ghcr.io/harrywesterman/twinbox-manager-web`)
- `manager-api` on port `8080` (`ghcr.io/harrywesterman/twinbox-manager-api`)
- `manager-worker` (no public port, `ghcr.io/harrywesterman/twinbox-manager-worker`)

## Persistent Data

`manager-data/` stores job and cluster state.

- `clusters/*.json`
- `clusters/<cluster_id>/iac/*`
- `jobs/*.json`
- `logs/*.log`
- `queue/pending/*.json`
- `queue/running/*.json`
- `queue/completed/*.json`

## Operational Recommendations

- Keep `.env` private and never commit it.
- Rotate Proxmox credentials regularly.
- Restrict access to manager host/network segment.
