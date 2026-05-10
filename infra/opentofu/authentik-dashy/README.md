# Authentik Dashy Proxy

OpenTofu module that creates an Authentik proxy provider for the Dashy admin launcher.

## What it creates

- An Authentik proxy provider for Dashy
- An Authentik application bound to that provider
- Outpost integration for Traefik forward-auth

## Usage

```bash
cd infra/opentofu/authentik-dashy
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
AUTHENTIK_TOKEN=... tofu init
AUTHENTIK_TOKEN=... tofu apply
```

## Outputs

- Proxy provider ID and application slug for Traefik middleware configuration.
