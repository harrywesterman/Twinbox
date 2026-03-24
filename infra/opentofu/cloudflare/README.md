# Cloudflare DNS with OpenTofu

This stack creates DNS records for a single Cloudflare zone.

By default it is intended to manage:

- `wiredoor.<zone_name>`
- `*.<zone_name>`

Both point to the public IPv4 of the Wiredoor server.

## Required inputs

At minimum set:

- `cloudflare_api_token`
- `cloudflare_zone_id`
- `zone_name`
- `target_ipv4`

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
tofu init
tofu plan
tofu apply