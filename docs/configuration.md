# Configuration

Runtime configuration is loaded from root `.env`, but runtime secrets are now resolved through Vaultwarden via the Twinbox secret broker. `.env` still carries bootstrap-only material and non-secret defaults.

## Bootstrap-Only Secrets

```dotenv
PROXMOX_HOST=192.168.1.10
PROXMOX_PORT=8006
PROXMOX_USER=root@pam
PROXMOX_PASSWORD=change-me
VAULTWARDEN_CLIENTID_FILE=/opt/twinbox/bootstrap/vaultwarden-client-id
VAULTWARDEN_CLIENTSECRET_FILE=/opt/twinbox/bootstrap/vaultwarden-client-secret
VAULTWARDEN_PASSWORD_FILE=/opt/twinbox/bootstrap/vaultwarden-password
```

`PROXMOX_PASSWORD` is used only to seed `twinbox/global/proxmox` during the initial Vaultwarden bootstrap. `manager-api` and `manager-worker` no longer receive it through Compose after the cutover.

## Current Runtime Variables

```dotenv
PROXMOX_NODE=pve
PROXMOX_STORAGE_POOL=local-lvm
PROXMOX_FILE_DATASTORE=local
KUBECTL_VERSION=v1.30.0
HELM_VERSION=v3.15.4
TWINBOX_IMAGE_TAG=latest
```

## Vaultwarden Bootstrap

```dotenv
TWINBOX_SECRET_BACKEND=vaultwarden
VAULTWARDEN_IMAGE_TAG=1.35.4
VAULTWARDEN_LOCAL_PORT=8222
VAULTWARDEN_DOMAIN=http://localhost:8222
VAULTWARDEN_SERVER_URL=http://vaultwarden:80
VAULTWARDEN_VAULT_EMAIL=twinbox@local
VAULTWARDEN_PASSWORD_FILE=/opt/twinbox/bootstrap/vaultwarden-password
VAULTWARDEN_CLIENTID_FILE=/opt/twinbox/bootstrap/vaultwarden-client-id
VAULTWARDEN_CLIENTSECRET_FILE=/opt/twinbox/bootstrap/vaultwarden-client-secret
VAULTWARDEN_READY_FILE=/opt/twinbox/bootstrap/vaultwarden-ready
VAULTWARDEN_SIGNUPS_ALLOWED=true
VAULTWARDEN_BOOTSTRAP_APPDATA_DIR=/opt/twinbox/bootstrap/bw-host
BITWARDENCLI_APPDATA_DIR=/opt/twinbox/bootstrap/bw-runtime
VAULTWARDEN_ITEM_PREFIX=twinbox
TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets
TWINBOX_SECRET_CACHE_TTL_SEC=60
```

The Management VM uses these values to bring up Vaultwarden locally, finish the first-user bootstrap over an SSH tunnel, and let the API/worker unlock Vaultwarden non-interactively with a personal API key plus password file.

Tooling version notes:

- `kubectl` and `helm` come from `.env`.
- `tofu` and `talosctl` versions are pinned in `config/pinned-defaults.sh`.
- The management VM host install script and `manager-worker` resolve Talos images through `scripts/get-talos-image-factory.sh`, then download the resulting disk image locally before handing it to OpenTofu.
- The same helper also resolves the matching Talos Image Factory installer image, and provisioning writes that into `machine.install.image` so boot-asset extensions persist after Talos installs to disk.
- To refresh a Talos Factory schematic or build a future-version URL, use `scripts/get-talos-image-factory.sh` with `--preset vanilla` or `--preset qemu-guest-agent`.
- The provisioning flow defaults to the `qemu-guest-agent` preset, which currently includes `siderolabs/qemu-guest-agent`, `siderolabs/iscsi-tools`, and `siderolabs/util-linux-tools` so Proxmox guest reporting and future Longhorn prerequisites are available on the Talos nodes.

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
- Rotate the Vaultwarden item fields and API key regularly.
- Restrict access to manager host/network segment.
- Treat `/opt/twinbox/bootstrap/*` as root/operator-only bootstrap material.
- Runtime queue payloads and cluster state should contain refs only, never secret values.
