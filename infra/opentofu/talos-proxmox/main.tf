locals {
  controlplanes = {
    for name, node in var.nodes : name => node if node.type == "controlplane"
  }

  workers = {
    for name, node in var.nodes : name => node if node.type == "worker"
  }

  bootstrap_controlplane = sort(keys(local.controlplanes))[0]

  machine_patches = {
    for name, node in var.nodes : name => yamlencode({
      machine = {
        network = {
          hostname    = name
          nameservers = var.dns_servers
          interfaces = [
            merge({
              deviceSelector = {
                hardwareAddr = node.mac
              }
              dhcp      = false
              addresses = ["${node.ip}/${var.prefix}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = var.gateway
                }
              ]
            }, node.type == "controlplane" ? {
              vip = {
                ip = var.vip_ip
              }
            } : {})
          ]
        }
        install = {
          disk = var.install_disk
        }
      }
    })
  }
}

resource "talos_machine_secrets" "cluster" {}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint
  machine_type     = each.value.type
  machine_secrets  = talos_machine_secrets.cluster.machine_secrets
  config_patches   = [local.machine_patches[each.key]]
}

resource "proxmox_virtual_environment_download_file" "talos_nocloud" {
  content_type = "import"
  datastore_id = var.file_datastore
  node_name    = var.proxmox_node
  file_name    = "talos-${var.talos_image_cache_key}.raw.xz"
  url          = var.talos_image_url
}

resource "proxmox_virtual_environment_file" "user_data" {
  for_each     = var.nodes
  content_type = "snippets"
  datastore_id = var.file_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${var.cluster_slug}-${each.key}-user-data.yaml"
    data      = data.talos_machine_configuration.node[each.key].machine_configuration
  }
}

resource "proxmox_virtual_environment_file" "meta_data" {
  for_each     = var.nodes
  content_type = "snippets"
  datastore_id = var.file_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${var.cluster_slug}-${each.key}-meta-data.yaml"
    data = templatefile("${path.module}/templates/meta-data.tftpl", {
      hostname = each.key
    })
  }
}

resource "proxmox_virtual_environment_file" "network_data" {
  for_each     = var.nodes
  content_type = "snippets"
  datastore_id = var.file_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${var.cluster_slug}-${each.key}-network-data.yaml"
    data = templatefile("${path.module}/templates/network-data.tftpl", {
      mac         = each.value.mac
      ip          = each.value.ip
      prefix      = var.prefix
      gateway     = var.gateway
      dns_servers = var.dns_servers
    })
  }
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

  initialization {
    datastore_id         = var.file_datastore
    user_data_file_id    = proxmox_virtual_environment_file.user_data[each.key].id
    meta_data_file_id    = proxmox_virtual_environment_file.meta_data[each.key].id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
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

resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  node                         = each.value.ip
  endpoint                     = each.value.type == "controlplane" ? each.value.ip : local.controlplanes[local.bootstrap_controlplane].ip
  client_configuration         = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input  = data.talos_machine_configuration.node[each.key].machine_configuration

  depends_on = [
    proxmox_virtual_environment_vm.node,
  ]
}

resource "talos_machine_bootstrap" "cluster" {
  node                 = local.controlplanes[local.bootstrap_controlplane].ip
  endpoint             = local.controlplanes[local.bootstrap_controlplane].ip
  client_configuration = talos_machine_secrets.cluster.client_configuration

  depends_on = [
    talos_machine_configuration_apply.node,
  ]
}

resource "talos_cluster_kubeconfig" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoint             = var.vip_ip
  node                 = local.controlplanes[local.bootstrap_controlplane].ip

  depends_on = [
    talos_machine_bootstrap.cluster,
  ]
}
