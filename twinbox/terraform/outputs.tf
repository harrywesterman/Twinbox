output "master_nodes" {
  description = "Master node information"
  value = {
    for i, vm in proxmox_vm_qemu.k8s_master :
    "master-${i}" => {
      id        = vm.id
      name      = vm.name
      ip_address = vm.default_ipv4_address
      node      = vm.target_node
    }
  }
  sensitive = true
}

output "worker_nodes" {
  description = "Worker node information"
  value = {
    for i, vm in proxmox_vm_qemu.k8s_worker :
    "worker-${i}" => {
      id        = vm.id
      name      = vm.name
      ip_address = vm.default_ipv4_address
      node      = vm.target_node
    }
  }
  sensitive = true
}

output "cluster_info" {
  description = "Cluster summary information"
  value = {
    name          = var.cluster_name
    master_count  = var.master_count
    worker_count  = var.worker_count
    total_nodes   = var.master_count + var.worker_count
  }
}