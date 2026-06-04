# OpenTofu Infrastructure

OpenTofu modules for provisioning external infrastructure components used by Twinbox.

## Modules

| Module | Provider | Purpose |
|--------|----------|---------|
| `authentik-argocd/` | Authentik + Random | Argo CD OIDC application/client in Authentik |
| `authentik-dashy/` | Authentik | Proxy provider for the Dashy admin launcher in Authentik |
| `authentik-headlamp/` | Authentik + Random | Headlamp OIDC application/client in Authentik |
| `authentik-pgadmin4/` | Authentik + Random | pgAdmin 4 OIDC application/client in Authentik |
| `authentik-management-consoles/` | Authentik | Proxy applications for Traefik Dashboard and Longhorn in Authentik |
| `authentik-netbird/` | Authentik + Random | NetBird OIDC application/client in Authentik |
| `authentik-vaultwarden/` | Authentik | Proxy provider for Vaultwarden in Authentik |
| `netbird/` | Hetzner Cloud | Self-hosted NetBird VPS with dashboard, server, Traefik, and proxy |
| `netbird-idp/` | NetBird | Authentik identity provider registration in NetBird |
| `netbird-network/` | NetBird | Twinbox groups, setup keys, network resource, router, and policies |
| `netbird-proxy-services/` | NetBird | NetBird reverse proxy services targeting internal Traefik |
| `talos-proxmox/` | Proxmox (bpg) | Talos Linux VMs on Proxmox VE |

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

### talos-proxmox/

Creates Talos Linux VMs on Proxmox with:

- Per-node CPU, memory, and disk configuration
- Static MAC addresses for DHCP reservation
- Talos ISO attachment for initial bootstrap, disk boot after
- VM tagging for cluster identification

See [talos-proxmox/README.md](talos-proxmox/README.md) for full variable reference.

### netbird/

Provisions a Hetzner Cloud VM running self-hosted NetBird with:

- Official NetBird Docker Compose bootstrap
- Built-in Traefik for NetBird dashboard/API and TLS passthrough
- NetBird Reverse Proxy enabled for `proxy.<zone>` service domains
- Firewall rules for SSH, HTTP, HTTPS, and STUN
