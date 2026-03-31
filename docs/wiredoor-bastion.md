# Wiredoor Bastion Host

The `provision-wiredoor-bastion` step provisions a VM on Hetzner Cloud running [Wiredoor](https://github.com/twinbox/wiredoor). Wiredoor acts as a bastion host that establishes a WireGuard tunnel to the Talos cluster, enabling external access to services through Traefik.

## Prerequisites

- A Hetzner Cloud account with a project
- An API token with **Read & Write** permissions (create at https://console.hetzner.cloud/)
- A domain name for DNS routing
- The `provision-nodes` step must be completed first

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `hcloud_token` | Yes | — | Hetzner Cloud API token |
| `zone_name` | Yes | — | Domain name (e.g., `example.com`) |
| `hcloud_location` | No | `fsn1` | Datacenter: `fsn1`, `nbg1`, or `hel1` |
| `hcloud_server_type` | No | `cax11` | Server size: `cax11` (ARM64) or `cx22` (x86) |
| `wiredoor_network` | No | `10.200.0.0/24` | WireGuard subnet |
| `ssh_public_key` | No | — | Optional SSH public key; auto-generates if omitted |

## What It Does

1. Generates a Wiredoor FQDN: `wiredoor.<domain>` for production, `wiredoor-<slug>.<domain>` for other clusters
2. Generates a random admin password
3. If no SSH key is provided, generates an ed25519 keypair stored in `manager-data/ssh/wiredoor-<cluster-id>/`
4. Deploys a Debian 13 VM on Hetzner Cloud using OpenTofu (`infra/opentofu/wiredoor/`)
5. Writes secrets to `/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-<cluster-id>.json`

## Secret Output

Written to `/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-<cluster-id>.json`:

```json
{
  "HCLOUD_TOKEN": "...",
  "WIREDOOR_IP": "1.2.3.4",
  "WIREDOOR_ADMIN_PASSWORD": "...",
  "WIREDOOR_URL": "https://wiredoor.example.com",
  "WIREDOOR_FQDN": "wiredoor.example.com",
  "WIREDOOR_NETWORK": "10.200.0.0/24",
  "CLUSTER_ID": "prd",
  "SSH_PRIVATE_KEY": "..."
}
```

## OpenTofu Workspace

The step creates a per-cluster workspace at `manager-data/opentofu/wiredoor-<cluster-id>/` and runs `tofu init` + `tofu apply`.

## Downstream Steps

- `configure-cloudflare-dns` reads the `WIREDOOR_IP` from the bastion secrets to create A records
- `install-wiredoor-gateway` configures the WireGuard tunnel on the cluster side
