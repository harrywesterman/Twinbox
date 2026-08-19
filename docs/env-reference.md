# Environment Variables

Complete reference for the `.env` file used by the Twinbox manager stack.

## Proxmox Connection

| Variable | Example | Description |
|----------|---------|-------------|
| `PROXMOX_HOST` | `192.168.1.10` | Proxmox host IP or hostname |
| `PROXMOX_PORT` | `8006` | Proxmox API port |
| `PROXMOX_USER` | `root@pam` | Proxmox API username |
| `PROXMOX_PASSWORD` | `change-me` | Proxmox API password (bootstrap only; canonical copy lives under `bootstrap/secrets/`) |
| `PROXMOX_NODE` | `pve` | Default Proxmox node name |
| `PROXMOX_STORAGE_POOL` | `local-lvm` | Storage pool for VM disks |
| `PROXMOX_FILE_DATASTORE` | `local` | Datastore for Talos disk-image uploads and NoCloud snippets; the setup wizard enables Proxmox `import` and `snippets` content here |

## Talos

| Variable | Example | Description |
|----------|---------|-------------|
| `TALOS_IMAGE_PRESET` | `qemu-guest-agent` | Talos image factory preset applied to generated machine configs. Common values: `qemu-guest-agent` (enables the QEMU guest agent for Proxmox VM management), or empty for no preset. |
| `TALOS_IMAGE_PLATFORM` | `nocloud` | Talos image platform selector for the bootable disk image. Twinbox defaults to `nocloud` so Proxmox-provided user-data and network-data are applied before the Talos API is contacted. |
| `TALOS_IMAGE_ARCH` | `amd64` | Talos image architecture (`amd64` or `arm64`) |

## Image

| Variable | Example | Description |
|----------|---------|-------------|
| `TWINBOX_IMAGE_TAG` | `sha-1df4326` | GHCR image tag for all three manager services |

## Pinned Tool Versions

CLI tools pinned in [`config/pinned-defaults.sh`](https://github.com/harrywesterman/Twinbox/blob/main/config/pinned-defaults.sh):

| Tool | Pinned Version |
|------|----------------|
| `talosctl` | `v1.13.0` |
| `tofu` | `v1.11.6` |
| `k9s` | `v0.50.18` |
| `kubectl` | `v1.36.0` |
| `helm` | `v4.1.4` |
| Talos version | `v1.13.0` |
| Argo CD | `v3.3.9` |
| Cilium chart | `1.19.3` |
| Cloudtty chart | `0.8.9` |
| NetBird | `0.73.2` |

`restic` is installed from the Management VM package repositories for host backups and is not pinned in [`config/pinned-defaults.sh`](https://github.com/harrywesterman/Twinbox/blob/main/config/pinned-defaults.sh).

## Manager

| Variable | Example | Description |
|----------|---------|-------------|
| `TWINBOX_HOST_REPO_ROOT` | `/opt/twinbox` | Runtime root used by the manager stack on the Management VM; not a full repo checkout on the host |
| `TWINBOX_BOOTSTRAP_DIR` | `/opt/twinbox/bootstrap` | Root of the bootstrap secrets tree |
| `MANAGEMENT_VM_IP` | `192.168.1.50` | The Management VM's own IP address. Used as the anchor for IP allocation scanning (`/api/ip-suggestions`) and for detecting network defaults (gateway, DNS, prefix length). |

## SeaweedFS

| Variable | Example | Description |
|----------|---------|-------------|
| `SEAWEEDFS_ACCESS_KEY_ID` | `velero` | S3 access key used by SeaweedFS and Velero |
| `SEAWEEDFS_SECRET_ACCESS_KEY` | `generated-secret` | S3 secret key used by SeaweedFS and Velero |
| `SEAWEEDFS_BUCKET` | `twinbox-velero` | Default bucket for Velero, Longhorn, CloudNativePG, and Management VM backups |
| `SEAWEEDFS_REGION` | `seaweedfs` | Compatibility region label for the SeaweedFS S3 endpoint |

## Secrets

| Variable | Example | Description |
|----------|---------|-------------|
| `TWINBOX_SECRET_BACKEND` | `filesystem` | Secret storage backend (currently only `filesystem`) |
| `TWINBOX_SECRET_ITEM_PREFIX` | `twinbox` | Prefix for secret item names |
| `TWINBOX_SECRET_TEMP_DIR` | `/tmp/twinbox-secrets` | Temp directory for materialized secret files |
| `TWINBOX_SECRET_CACHE_TTL_SEC` | `60` | Secret broker cache TTL in seconds |

## GitOps Chart Versions

Helm chart versions are declared in the Argo CD `Application` manifests under `gitops/apps/` and in [`config/pinned-defaults.sh`](https://github.com/harrywesterman/Twinbox/blob/main/config/pinned-defaults.sh). These versions drift with every release, so the canonical source is the repository itself. Check those files directly rather than relying on a static table.
