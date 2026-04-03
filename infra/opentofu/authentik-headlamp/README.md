# Authentik Headlamp OIDC

OpenTofu module that creates an Authentik OAuth2/OIDC application for Headlamp.

## What it creates

- An Authentik OAuth2 provider
- An Authentik application bound to that provider
- A generated client ID and client secret stored in OpenTofu state

## Usage

```bash
cd infra/opentofu/authentik-headlamp
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
AUTHENTIK_TOKEN=... tofu init
AUTHENTIK_TOKEN=... tofu apply
```
