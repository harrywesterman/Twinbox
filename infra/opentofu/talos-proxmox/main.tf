locals {
  controlplanes = {
    for name, node in var.nodes : name => node if node.type == "controlplane"
  }

  workers = {
    for name, node in var.nodes : name => node if node.type == "worker"
  }

  vm_host_map = var.vm_node_map
  talos_image_file_name = "talos-${var.talos_image_cache_key}.iso"
  talos_image_file_id   = "${var.file_datastore}:iso/${local.talos_image_file_name}"
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
    file_id   = local.talos_image_file_id
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

  # Talos nodes are rebooted explicitly from the provisioning script after the
  # second apply. Keeping this false avoids waiting on long-running Proxmox
  # reboot tasks that can time out on slower nodes.
  reboot_after_update = false

  operating_system {
    type = "l26"
  }

  serial_device {}

  vga {
    type = "std"
  }
}
