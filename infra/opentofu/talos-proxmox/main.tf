locals {
  controlplanes = {
    for name, node in var.nodes : name => node if node.type == "controlplane"
  }

  workers = {
    for name, node in var.nodes : name => node if node.type == "worker"
  }

  vm_host_map = var.vm_node_map

  talos_image_nodes = toset(concat([var.proxmox_node], values(var.vm_node_map)))
}

resource "proxmox_virtual_environment_file" "talos_nocloud" {
  for_each     = local.talos_image_nodes
  content_type = "iso"
  datastore_id = var.file_datastore
  node_name    = each.value

  source_file {
    path      = var.talos_image_local_path
    file_name = "talos-${var.talos_image_cache_key}.iso"
  }
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

  boot_order = var.boot_from_disk ? ["virtio0"] : ["ide2", "virtio0"]

  memory {
    dedicated = each.value.ram_mb
    floating  = 2048
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "virtio0"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
  }

  # Keep the Talos ISO attached after bootstrap so the second apply only flips
  # boot order and does not require the extra Proxmox privilege to change CD-ROM media.
  cdrom {
    interface = "ide2"
    file_id   = proxmox_virtual_environment_file.talos_nocloud[local.vm_host_map[each.key]].id
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

  operating_system {
    type = "l26"
  }

  serial_device {}

  vga {
    type = "std"
  }
}
