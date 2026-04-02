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
| `PROXMOX_FILE_DATASTORE` | `local` | Datastore for ISO uploads and snippets |

## Talos

| Variable | Example | Description |
|----------|---------|-------------|
| `TALOS_IMAGE_PRESET` | `qemu-guest-agent` | Talos image factory preset applied to generated machine configs. Common values: `qemu-guest-agent` (enables the QEMU guest agent for Proxmox VM management), or empty for no preset. |

## Image

| Variable | Example | Description |
|----------|---------|-------------|
| `TWINBOX_IMAGE_TAG` | `latest` | GHCR image tag for all three manager services |

## Pinned Tool Versions

CLI tools pinned in `config/pinned-defaults.sh`:

| Tool | Pinned Version |
|------|----------------|
| `talosctl` | `v1.12.6` |
| `tofu` | `v1.8.8` |
| `k9s` | `v0.50.18` |
| `kubectl` | `v1.35.1` |
| `helm` | `v4.1.3` |
| Talos version | `v1.12.6` |

## Manager

| Variable | Example | Description |
|----------|---------|-------------|
| `TWINBOX_HOST_REPO_ROOT` | `/opt/twinbox` | Path to the Twinbox checkout on the Management VM |
| `TWINBOX_BOOTSTRAP_DIR` | `/opt/twinbox/bootstrap` | Root of the bootstrap secrets tree |
| `MANAGEMENT_VM_IP` | `192.168.1.50` | The Management VM's own IP address. Used as the anchor for IP allocation scanning (`/api/ip-suggestions`) and for detecting network defaults (gateway, DNS, prefix length). |

## Secrets

| Variable | Example | Description |
|----------|---------|-------------|
| `TWINBOX_SECRET_BACKEND` | `filesystem` | Secret storage backend (currently only `filesystem`) |
| `TWINBOX_SECRET_ITEM_PREFIX` | `twinbox` | Prefix for secret item names |
| `TWINBOX_SECRET_TEMP_DIR` | `/tmp/twinbox-secrets` | Temp directory for materialized secret files |
| `TWINBOX_SECRET_CACHE_TTL_SEC` | `60` | Secret broker cache TTL in seconds |

## GitOps Chart Versions

Helm chart versions are pinned in the Argo CD `Application` manifests under `gitops/apps/`:

| Application | Chart Version | Manifest |
|-------------|---------------|----------|
| External Secrets | `0.20.1` | `gitops/apps/external-secrets.yaml` |
| OpenBao | `0.26.2` | Generated `install-secret-sync.sh` Application manifest |
