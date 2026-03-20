# Talos Static IP Nocloud Design

**Problem:** The current Talos provisioning flow records planned node IPs, but does not configure those IPs on the VMs themselves. The first boot therefore falls back to DHCP, while the bootstrap flow assumes the nodes are already reachable on their reserved static addresses.

**Decision:** Move the Proxmox Talos provisioning flow to Talos `nocloud` with per-node static network configuration. Each node will receive its final management IP, gateway, prefix length, DNS servers, and DNS domain on first boot, without relying on DHCP.

## Why This Approach

- Kernel `ip=` boot arguments are possible, but fragile to automate safely for multiple VMs in Proxmox.
- Talos `nocloud` is the supported path for delivering both machine config and network config without prior network access.
- Proxmox already supports attaching per-VM cloud-init snippets, which maps cleanly onto Talos `nocloud`.

## Inputs And Defaults

The Talos provisioning step will accept these additional user-editable fields:

- `node_prefix_length`
- `gateway_ip`
- `dns_servers`
- `dns_domain`

Defaults are derived from the existing management host:

- prefix length from the first global IPv4 address
- gateway from the default route
- DNS from `/etc/resolv.conf`
- domain from the existing local default when no better value is present

## Provisioning Flow

1. The UI requests allocation suggestions and also receives detected network defaults.
2. The API validates and persists the expanded network payload.
3. VM provisioning generates Talos configs and `nocloud` artifacts per node.
4. Proxmox VMs are created with a cloud-init drive plus `cicustom` snippets pointing at the generated Talos configs.
5. Nodes boot directly onto their assigned static IPs.

## Bootstrap Flow

- The bootstrap step no longer applies machine config over insecure maintenance-mode networking.
- It only bootstraps Talos and retrieves kubeconfig using the known control-plane IPs.

## Expected Outcome

- `cp-1` and every subsequent node come up on the configured static IP immediately.
- The reserved addresses shown in Twinbox match the effective addresses visible in Talos and Proxmox.
- The flow no longer depends on DHCP leases or external reservations.
