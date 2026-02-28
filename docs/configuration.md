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
PROXMOX_ISO_STORAGE=local
TALOS_ISO_FILE=talos-v1.7.4.iso
TWINBOX_IMAGE_TAG=latest
```

## Compose Services

- `manager-web` on port `3000` (`ghcr.io/harrywesterman/twinbox-manager-web`)
- `manager-api` on port `8080` (`ghcr.io/harrywesterman/twinbox-manager-api`)
- `manager-worker` (no public port, `ghcr.io/harrywesterman/twinbox-manager-worker`)

## Persistent Data

`manager-data/` stores job and cluster state.

- `clusters/*.json`
- `jobs/*.json`
- `logs/*.log`
- `queue/pending/*.json`
- `queue/running/*.json`
- `queue/completed/*.json`

## Operational Recommendations

- Keep `.env` private and never commit it.
- Rotate Proxmox credentials regularly.
- Restrict access to manager host/network segment.
