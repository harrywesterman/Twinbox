# Talos Proxmox Infrastructure

OpenTofu module for provisioning Talos Linux VMs on Proxmox VE.

## Overview

This module creates Talos Linux virtual machines on Proxmox, supporting both control plane and worker node types. It handles VM creation with the Talos ISO attached for initial bootstrap and disk-based boot after installation.

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
| `templates/meta-data.tftpl` | Cloud-init hostname metadata |
| `templates/network-data.tftpl` | Cloud-init static network config |

## Key Variables

| Variable | Description |
|----------|-------------|
| `nodes` | Map of node definitions (ip, type, vmid, cpu, ram_mb, disk_gb, mac) |
| `cluster_name` | Cluster name prefix for VM names |
| `cluster_slug` | Cluster slug used for tagging |
| `proxmox_endpoint` | Proxmox API endpoint |
| `vm_datastore` | Datastore for VM disks |
| `file_datastore` | Datastore for ISO files |
| `bridge` | Proxmox network bridge |
| `talos_version` | Talos version to deploy |
| `boot_from_disk` | Boot from disk instead of ISO (set after bootstrap) |

## Outputs

| Output | Description |
|--------|-------------|
| `vip_ip` | Virtual IP for the control plane |
| `controlplane_ips` | List of control plane node IPs |
| `worker_ips` | List of worker node IPs |
| `controlplane_vm_ids` | List of control plane VM IDs |
| `worker_vm_ids` | List of worker VM IDs |
| `controlplane_ipv4_addresses` | Control plane IPs from Proxmox agent |
| `worker_ipv4_addresses` | Worker IPs from Proxmox agent |

## Bootstrap Flow

1. VMs are created with the Talos ISO attached (`ide2` CD-ROM).
2. On first apply, boot order targets the ISO for Talos installation.
3. After bootstrap, set `boot_from_disk = true` to flip boot order to `virtio0`.
4. The ISO remains attached to avoid requiring extra Proxmox privileges for CD-ROM changes.
