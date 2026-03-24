# Wiredoor on Hetzner with OpenTofu

This stack creates:

- a Hetzner Cloud VM for Wiredoor
- a Hetzner firewall
- cloud-init bootstrap that installs Docker and Wiredoor

DNS is managed separately in `infra/opentofu/cloudflare`, using the `zone_name` variable for the active domain.

## Files

- `versions.tf` provider and OpenTofu version constraints
- `providers.tf` provider configuration
- `variables.tf` input variables
- `locals.tf` derived values
- `main.tf` Hetzner server and SSH key
- `firewall.tf` Hetzner firewall rules
- `outputs.tf` useful outputs
- `cloud-init/wiredoor.yaml.tftpl` cloud-init template

## Required inputs

At minimum set:

- `hcloud_token`
- `ssh_public_key`
- `wiredoor_fqdn`
- `wiredoor_admin_email`
- `wiredoor_admin_password`

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
tofu init
tofu plan
tofu apply