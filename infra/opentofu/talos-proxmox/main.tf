locals {
  controlplanes = {
    for name, node in var.nodes : name => node if node.type == "controlplane"
  }

  workers = {
    for name, node in var.nodes : name => node if node.type == "worker"
  }
}

resource "proxmox_virtual_environment_download_file" "talos_nocloud" {
  content_type = "import"
  datastore_id = var.file_datastore
  node_name    = var.proxmox_node
  file_name    = "talos-${var.talos_image_cache_key}.raw.xz"
  url          = var.talos_image_url
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each  = var.nodes
  name      = "${var.cluster_name}-${each.key}"
  vm_id     = each.value.vmid
  node_name = var.proxmox_node
  started   = true
  on_boot   = true
  machine   = "q35"
  bios      = "seabios"
  tags      = ["twinbox", "talos", each.value.type, "cluster-${var.cluster_slug}"]

  cpu {
    cores = each.value.cpu
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.ram_mb
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "virtio0"
    import_from  = proxmox_virtual_environment_download_file.talos_nocloud.id
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
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
    type = "serial0"
  }
}
