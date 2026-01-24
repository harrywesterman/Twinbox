# Talos VM provisioning module for Twinbox
resource "proxmox_vm_qemu" "talos_node" {
  count = var.node_count

  name        = "${var.cluster_name}-${var.node_type}-${count.index + 1}"
  target_node = var.proxmox_target_node
  clone       = var.vm_template_name
  full_clone  = true

  cores   = var.vm_cores
  memory  = var.vm_memory
  sockets = 1

  bios = "ovmf"  # Required for Talos Linux
  
  # EFI disk for Talos
  efi_disk {
    efi_type = "2m"
    storage  = var.storage_pool
    pre_enrolled_keys = true
  }

  # Primary disk
  disk {
    slot    = 0
    size    = var.disk_size
    type    = "scsi"
    storage = var.storage_pool
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
    tag    = var.vlan_id
  }

  # Cloud-init for initial boot
  ipconfig0 = "ip=dhcp"
  
  # Attach Talos ISO
  ide {
    ide2 {
      cdrom = true
      file  = var.talos_iso_path
    }
  }

  oncreate_timeout = 30
  clone_timeout    = 180
  start_timeout    = 120

  lifecycle {
    ignore_changes = [
      ide,
      disk,
    ]
  }
}

# Output VM information for cluster configuration
output "node_ips" {
  description = "IP addresses of Talos nodes"
  value       = [for vm in proxmox_vm_qemu.talos_node : vm.defaultip]
}

output "node_names" {
  description = "Names of Talos nodes"
  value       = [for vm in proxmox_vm_qemu.talos_node : vm.name]
}