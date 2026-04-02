# Cloudflare Tunnel Configuration

The `configure-cloudflare-tunnel` step creates or reuses a Cloudflare Tunnel for
the selected cluster and publishes the public hostname through Cloudflare DNS.

## Prerequisites

- A Cloudflare account with the target zone added
- A single Cloudflare custom API token with both of these permissions:
  - `Account` → `Cloudflare Tunnel` → `Edit`
  - `Zone` → `DNS` → `Edit`
- The token must be scoped to the Cloudflare account and to the specific zone
  you selected in the ingress step
- The Cloudflare Account ID for the account that owns the tunnel
- The Cloudflare Zone ID for the zone that should receive the DNS record
- The DNS domain selected in the ingress step

## How to Create the Token

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

## What the Step Does

1. Reuses the existing tunnel if one already exists for the cluster name.
2. Requests a tunnel token from Cloudflare.
3. Verifies the selected Cloudflare zone when the token allows zone reads.
4. Creates or updates the wildcard CNAME that points to the tunnel.
5. Syncs the tunnel credentials into OpenBao.
6. Deploys the `cloudflare-tunnel-remote` Argo CD application.

## Troubleshooting

- If DNS record creation fails with an authorization error, check that the token
  has `Zone` → `DNS` → `Edit` on the correct zone.
- If the tunnel is healthy but the hostname does not resolve, confirm that the
  wildcard CNAME exists for the selected public domain.
- If Cloudflare reports an existing record with the same name, Twinbox now
  updates the record instead of failing.

