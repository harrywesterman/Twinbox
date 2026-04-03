# Ingress and Hostname Policy

Twinbox uses one canonical rule set for hostnames and ingress selection.
This policy is designed to work with the Cloudflare Free plan.

## Cluster Rules

- `prd` may choose all four ingress routes:
  - Wiredoor
  - Cloudflare Tunnel
  - MetalLB
  - Tailscale
- non-`prd` clusters may choose only:
  - Wiredoor
  - MetalLB
  - Tailscale
- Cloudflare Tunnel is **prd-only** on Cloudflare Free because delegated subdomain setup is Enterprise-only.

## Hostname Rules

- `prd` uses the base DNS domain directly:
  - `authentik.bierineenweek.nl`
  - `argocd.bierineenweek.nl`
  - `grafana.bierineenweek.nl`
- non-`prd` clusters use the slug-prefixed hostname model:
  - `headlamp.tst.bierineenweek.nl`
  - `whoami.dev.bierineenweek.nl`
  - `homepage.tst.bierineenweek.nl`

## Wizard Behavior

- `choose-ingress-route` asks for the base DNS domain.
- The dropdown hides Cloudflare Tunnel for non-`prd` clusters.
- The help text explains why Cloudflare is unavailable outside `prd`.
- The cluster state stores both the base domain and the derived public zone name.

## Why This Exists

Cloudflare’s subdomain delegation flow is Enterprise-only, so Twinbox cannot rely on delegated child zones on the Free plan. The wizard therefore keeps the policy explicit instead of failing later during ingress setup.
