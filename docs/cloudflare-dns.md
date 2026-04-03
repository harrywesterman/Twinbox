# Cloudflare DNS Configuration

The `configure-cloudflare-dns` step creates DNS records in Cloudflare to route traffic to the Wiredoor bastion host.

## Prerequisites

- A Cloudflare account with a domain added to the zone
- An API token with **Zone DNS Edit** permissions (create at https://dash.cloudflare.com/profile/api-tokens)
- The `provision-wiredoor-bastion` step must be completed first (it provides the target IP)

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `cloudflare_api_token` | Yes | — | Cloudflare API token with Zone DNS Edit |
| `zone_name` | Yes | — | Domain name (e.g., `example.com`) |

## What It Does

1. Reads `WIREDOOR_IP` from `/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-<cluster-id>.json`
2. Queries the Cloudflare API to get the zone ID
3. Deploys DNS records using OpenTofu (`infra/opentofu/cloudflare/`)
4. Creates two A records:
   - `wiredoor.<domain>` (or `wiredoor-<slug>.<domain>` for non-production)
   - `*.<domain>` wildcard (or `*.<slug>.<domain>`)
5. Saves credentials to `/opt/twinbox/bootstrap/secrets/global/cloudflare-<cluster-id>.json`

## Secret Output

Written to `/opt/twinbox/bootstrap/secrets/global/cloudflare-<cluster-id>.json`:

```json
{
  "CLOUDFLARE_API_TOKEN": "...",
  "CLOUDFLARE_ZONE_ID": "...",
  "ZONE_NAME": "example.com",
  "WIREDOOR_FQDN": "wiredoor.example.com",
  "WILDCARD_FQDN": "*.example.com",
  "TARGET_IPV4": "1.2.3.4",
  "CLUSTER_ID": "prd"
}
```

## OpenTofu Workspace

Per-cluster workspace at `manager-data/opentofu/cloudflare-<cluster-id>/`.

## Cluster Slug Logic

For production (`prd`), records use bare names (`wiredoor`, `*`). For other slugs, records are prefixed (`wiredoor-<slug>`, `*.<slug>`).
