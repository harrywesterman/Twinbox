locals {
  controlplanes = {
    for name, node in var.nodes : name => node if node.type == "controlplane"
  }

  workers = {
    for name, node in var.nodes : name => node if node.type == "worker"
  }

  vm_host_map           = var.vm_node_map
  talos_image_file_name = "talos-${var.cluster_slug}-${var.talos_image_cache_key}.raw"
  talos_image_file_id   = "${var.file_datastore}:import/${local.talos_image_file_name}"
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each  = var.nodes
  name      = "${var.cluster_name}-${each.key}"
  vm_id     = each.value.vmid
  node_name = local.vm_host_map[each.key]
  started   = true
  on_boot   = true
  bios      = "seabios"
  tags      = ["twinbox", "talos", each.value.type, "cluster-${var.cluster_slug}"]

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  boot_order = ["virtio0"]

  memory {
    dedicated = each.value.ram_mb
    floating  = each.value.ram_mb
  }

  disk {
    datastore_id = each.value.datastore_id
    import_from  = local.talos_image_file_id
    interface    = "virtio0"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
  }

  agent {
    enabled = true

    wait_for_ip {
      ipv4 = true
    }
  }

  network_device {
    bridge      = var.bridge
    model       = "virtio"
    mac_address = each.value.mac
  }

  # Keep VM updates from waiting on long-running Proxmox reboot tasks that can
  # time out on slower nodes.
  reboot_after_update = false

  operating_system {
    type = "l26"
  }

  serial_device {}

  vga {
    type = "std"
  }
}
