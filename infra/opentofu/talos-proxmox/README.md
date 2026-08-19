# Talos Proxmox Infrastructure

OpenTofu module for provisioning Talos Linux VMs on Proxmox VE.

## Overview

This module creates Talos Linux virtual machines on Proxmox, supporting both control plane and worker node types. The manager worker uploads a Talos bootable disk image as Proxmox `import` content on each target node, and this module imports it directly into the VM's first disk, so there is no ISO attach/detach step.

Static first-boot networking is configured through Proxmox's generated NoCloud initialization drive (`ip_config` plus DNS settings). Twinbox does not upload custom Proxmox snippets for Talos nodes, because Proxmox snippet uploads require SSH access to the target node.

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
| `nodes` | Map of node definitions (ip, type, vmid, cpu, ram_mb, disk_gb, datastore_id, mac) |
| `cluster_name` | Cluster name prefix for VM names |
| `cluster_slug` | Cluster slug used for tagging |
| `proxmox_endpoint` | Proxmox API endpoint |
| `nodes[*].datastore_id` | Per-VM datastore for the Talos system disk |
| `file_datastore` | Datastore for Talos disk image uploads; must allow Proxmox `import` content |
| `bridge` | Proxmox network bridge |
| `dns_domain` | Optional DNS search domain for the generated NoCloud initialization drive |
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
2. OpenTofu imports the image via the Proxmox API straight onto `virtio0`, configures generated NoCloud network data with the requested static IP, and starts the VM.
3. Talos boots in maintenance mode at the configured static address.
4. The manager worker applies the full Talos machine config through the Talos maintenance API, then bootstraps Kubernetes.
5. The Talos machine config still points at the matching installer image for future installs or upgrades.
