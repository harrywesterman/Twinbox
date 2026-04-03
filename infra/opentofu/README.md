# OpenTofu Infrastructure

OpenTofu modules for provisioning external infrastructure components used by Twinbox.

## Modules

| Module | Provider | Purpose |
|--------|----------|---------|
| `authentik-argocd/` | Authentik + Random | Argo CD OIDC application/client in Authentik |
| `authentik-headlamp/` | Authentik + Random | Headlamp OIDC application/client in Authentik |
| `cloudflare/` | Cloudflare | DNS records (wiredoor + wildcard A records) |
| `talos-proxmox/` | Proxmox (bpg) | Talos Linux VMs on Proxmox VE |
| `wiredoor/` | Hetzner Cloud | Wiredoor bastion VM with cloud-init bootstrap |

## Usage

Each module is self-contained with its own `providers.tf`, `variables.tf`, `versions.tf`, and `terraform.tfvars.example`.

```bash
cd infra/opentofu/<module>
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
tofu init
tofu plan
tofu apply
```

## Module Details

### cloudflare/

Creates DNS records in a Cloudflare zone:

- `wiredoor.<zone>` — A record pointing to the Wiredoor server
- `*.<zone>` — Wildcard A record for all subdomains

### talos-proxmox/

Creates Talos Linux VMs on Proxmox with:

- Per-node CPU, memory, and disk configuration
- Static MAC addresses for DHCP reservation
- Talos ISO attachment for initial bootstrap, disk boot after
- VM tagging for cluster identification

See [talos-proxmox/README.md](talos-proxmox/README.md) for full variable reference.

### wiredoor/

Provisions a Hetzner Cloud VM running Wiredoor with:

- Cloud-init bootstrap (Docker + Wiredoor install)
- Firewall rules
- SSH key management

See [wiredoor/README.md](wiredoor/README.md) for details.
