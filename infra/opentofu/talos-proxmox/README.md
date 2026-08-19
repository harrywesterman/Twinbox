# Talos Proxmox Infrastructure

OpenTofu module for provisioning Talos Linux VMs on Proxmox VE.

## Overview

This module creates Talos Linux virtual machines on Proxmox, supporting both control plane and worker node types. The manager worker uploads a Talos bootable disk image as Proxmox `import` content on each target node, and this module imports it directly into the VM's first disk.

Static first-boot networking is configured through a per-node NoCloud `cidata` ISO that contains the Talos machine config and matching static `network-config`. The manager worker uploads those ISOs as normal Proxmox `iso` content through the Proxmox API. Twinbox does not upload custom Proxmox snippets for Talos nodes.

Control plane and worker nodes are provisioned with fixed RAM equal to their assigned memory so Proxmox ballooning cannot pull them below their configured size.

## Resources

- `proxmox_virtual_environment_vm.node` – VMs for each node defined in the `nodes` map

## Files

| File | Purpose |
|------|---------|
| `main.tf` | VM resource definitions |
| `variables.tf` | Input variables |
| `outputs.tf` | Cluster IPs and VM IDs |
| `providers.tf` | Proxmox provider configuration |
| `versions.tf` | Provider version constraints |

## Key Variables

| Variable | Description |
|----------|-------------|
| `nodes` | Map of node definitions (ip, type, vmid, cpu, ram_mb, disk_gb, datastore_id, mac, nocloud_iso_file_id) |
| `cluster_name` | Cluster name prefix for VM names |
| `cluster_slug` | Cluster slug used for tagging |
| `proxmox_endpoint` | Proxmox API endpoint |
| `nodes[*].datastore_id` | Per-VM datastore for the Talos system disk |
| `file_datastore` | Datastore for Talos disk image and NoCloud ISO uploads; must allow Proxmox `import` and `iso` content |
| `bridge` | Proxmox network bridge |
| `dns_domain` | Optional DNS search domain for the Talos machine configs |
| `talos_version` | Talos version to deploy |

## Outputs

| Output | Description |
|--------|-------------|
| `vip_ip` | Virtual IP for the control plane |
| `controlplane_ips` | List of control plane node IPs |
| `worker_ips` | List of worker node IPs |
| `controlplane_vm_ids` | List of control plane VM IDs |
| `worker_vm_ids` | List of worker VM IDs |

## Bootstrap Flow

1. The manager worker downloads and decompresses the Talos disk image, then uploads it as Proxmox `import` content on each target node.
2. The manager worker renders full Talos machine configs, builds per-node `cidata` ISOs with static network config, and uploads those ISOs as Proxmox `iso` content on each target node.
3. OpenTofu imports the Talos image via the Proxmox API straight onto `virtio0`, attaches the matching `cidata` ISO, and starts the VM.
4. Talos reads its machine config and static network config during first boot, then the manager worker bootstraps Kubernetes through the configured static control-plane address.
5. The Talos machine config still points at the matching installer image for future installs or upgrades.
