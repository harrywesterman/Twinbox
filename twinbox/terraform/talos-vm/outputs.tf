output "node_ids" {
  description = "IDs of created Talos VMs"
  value       = [for vm in proxmox_vm_qemu.talos_node : vm.id]
}

output "node_fqdns" {
  description = "FQDNs of Talos nodes"
  value       = [for vm in proxmox_vm_qemu.talos_node : "${vm.name}.${var.cluster_name}.local"]
}

output "connection_info" {
  description = "Connection information for Talos nodes"
  value = {
    for i, vm in proxmox_vm_qemu.talos_node :
    vm.name => {
      id  = vm.id
      ip  = vm.defaultip
      mac = vm.network[0]["macaddr"]
    }
  }
}