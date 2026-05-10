# Cloudflare

Twinbox integrates with Cloudflare for DNS management and secure tunnel access. The integration is split into two wizard steps: DNS configuration and tunnel creation.

## DNS Configuration

The `configure-cloudflare-dns` step creates DNS records in Cloudflare to route traffic to the Wiredoor bastion host.

### Prerequisites

- A Cloudflare account with a domain added to the zone
- An API token with **Zone DNS Edit** permissions (create at https://dash.cloudflare.com/profile/api-tokens)
- The `provision-wiredoor-bastion` step must be completed first (it provides the target IP)

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `cloudflare_api_token` | Yes | — | Cloudflare API token with Zone DNS Edit |
| `zone_name` | Yes | — | Domain name (e.g., `example.com`) |

### What It Does

1. Reads `WIREDOOR_IP` from `/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-<cluster-id>.json`
2. Queries the Cloudflare API to get the zone ID
3. Deploys DNS records using OpenTofu (`infra/opentofu/cloudflare/`)
4. Creates two A records:
   - `wiredoor.<domain>` (or `wiredoor-<slug>.<domain>` for non-production)
   - `*.<domain>` wildcard (or `*.<slug>.<domain>`)
5. Saves credentials to `/opt/twinbox/bootstrap/secrets/global/cloudflare-<cluster-id>.json`

### Secret Output

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

### OpenTofu Workspace

Per-cluster workspace at `manager-data/opentofu/cloudflare-<cluster-id>/`.

### Cluster Slug Logic

For production (`prd`), records use bare names (`wiredoor`, `*`). For other slugs, records are prefixed (`wiredoor-<slug>`, `*.<slug>`).

---

## Tunnel Configuration

The `configure-cloudflare-tunnel` step creates or reuses a Cloudflare Tunnel for the selected cluster and publishes the public hostname through Cloudflare DNS.
On Cloudflare Free, Twinbox only shows this step for `prd` clusters. The canonical ingress policy lives in [docs/ingress-policy.md](./ingress-policy.md).

### Prerequisites

- A Cloudflare account with the target zone added
- A single Cloudflare custom API token with both of these permissions:
  - `Account` → `Cloudflare Tunnel` → `Edit`
  - `Zone` → `DNS` → `Edit`
- The token must be scoped to the Cloudflare account and to the specific zone you selected in the ingress step
- The Cloudflare Account ID for the account that owns the tunnel
- The Cloudflare Zone ID for the zone that should receive the DNS record
- The DNS domain selected in the ingress step
- The cluster must be `prd` when using Cloudflare Free

### How to Create the Token

1. Open the Cloudflare dashboard.
2. Go to **My Profile** → **API Tokens**.
3. Click **Create Token** → **Create Custom Token**.
4. Add these permissions:
   - **Account** → **Cloudflare Tunnel** → **Edit**
   - **Zone** → **DNS** → **Edit**
5. Under **Account Resources**, include the account that owns the tunnel.
6. Under **Zone Resources**, include the specific zone Twinbox should manage.
7. Copy the generated token into the Twinbox wizard.

Twinbox uses that single token for both tunnel creation and DNS record updates.
Do not create a second DNS-only token for this step.
If the cluster is not `prd`, the wizard will not show this step on Cloudflare Free.

### What the Step Does

1. Reuses the existing tunnel if one already exists for the cluster name.
2. Requests a tunnel token from Cloudflare.
3. Verifies the selected Cloudflare zone when the token allows zone reads.
4. Creates or updates the wildcard CNAME that points to the tunnel.
5. Configures the tunnel with an explicit wildcard hostname for the selected public zone and forwards it to Traefik inside the cluster over HTTP.
6. Syncs the tunnel credentials into OpenBao.
7. Deploys the `cloudflare-tunnel-remote` Argo CD application.

### Troubleshooting

- If DNS record creation fails with an authorization error, check that the token has `Zone` → `DNS` → `Edit` on the correct zone.
- If the tunnel is healthy but the hostname returns HTTP 503, confirm that the tunnel has an ingress rule pointing to Traefik and that the wildcard CNAME exists for the selected public domain.
- If the browser reports too many redirects, check whether Traefik is still forcing `web -> websecure`. Cloudflare already terminates client TLS for the tunnel, so the origin path should stay HTTP unless you explicitly preserve host headers and trust the origin certificate.
- If Cloudflare reports an existing record with the same name, Twinbox now updates the record instead of failing.
