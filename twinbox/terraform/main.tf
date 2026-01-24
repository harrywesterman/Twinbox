terraform {
  required_version = ">= 1.0"
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.proxmox_api_url
  pm_user         = var.proxmox_user
  pm_password     = var.proxmox_password
  pm_tls_insecure = var.proxmox_tls_insecure
}

resource "proxmox_vm_qemu" "k8s_master" {
  count = var.master_count

  name        = "${var.cluster_name}-master-${count.index + 1}"
  target_node = var.target_node
  clone       = var.vm_template
  full_clone  = true

  cores   = var.master_cores
  memory  = var.master_memory
  scsihw  = "virtio-scsi-pci"

  disk {
    slot    = 0
    size    = var.master_disk_size
    type    = "scsi"
    storage = var.storage_pool
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      network,
    ]
  }
}

resource "proxmox_vm_qemu" "k8s_worker" {
  count = var.worker_count

  name        = "${var.cluster_name}-worker-${count.index + 1}"
  target_node = var.target_node
  clone       = var.vm_template
  full_clone  = true

  cores   = var.worker_cores
  memory  = var.worker_memory
  scsihw  = "virtio-scsi-pci"

  disk {
    slot    = 0
    size    = var.worker_disk_size
    type    = "scsi"
    storage = var.storage_pool
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      network,
    ]
  }
}