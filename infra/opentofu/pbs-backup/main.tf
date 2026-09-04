resource "proxmox_virtual_environment_download_file" "debian" {
  content_type = "iso"
  datastore_id = var.file_datastore_id
  node_name    = var.node_name
  file_name    = "debian-13-genericcloud-amd64.qcow2"
  url          = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = var.file_datastore_id
  node_name    = var.node_name
  source_raw {
    data      = var.cloud_init
    file_name = "${var.vm_name}-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "pbs" {
  name      = var.vm_name
  vm_id     = var.vm_id
  node_name = var.node_name
  started   = true
  on_boot   = true
  tags      = ["twinbox", "backup", "pbs"]

  cpu {
    cores = 4
    type  = "host"
  }
  memory {
    dedicated = 8192
    floating  = 8192
  }
  agent { enabled = true }
  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  disk {
    datastore_id = var.datastore_id
    import_from   = proxmox_virtual_environment_download_file.debian.id
    interface     = "scsi0"
    size         = 32
    discard      = "on"
    iothread     = true
  }
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi1"
    size         = var.cache_disk_gb
    discard      = "on"
    iothread     = true
  }

  initialization {
    datastore_id      = var.datastore_id
    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id
    dns { servers = var.dns_servers }
    ip_config {
      ipv4 {
        address = "${var.ip_address}/${var.prefix_length}"
        gateway = var.gateway
      }
    }
  }
  operating_system { type = "l26" }
  serial_device {}
  vga { type = "serial0" }

  lifecycle {
    prevent_destroy = true
  }
}

output "vm_id" { value = proxmox_virtual_environment_vm.pbs.vm_id }
output "node_name" { value = proxmox_virtual_environment_vm.pbs.node_name }
