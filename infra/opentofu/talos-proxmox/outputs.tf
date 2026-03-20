output "vip_ip" {
  value = var.vip_ip
}

output "controlplane_ips" {
  value = [for name in sort(keys(local.controlplanes)) : local.controlplanes[name].ip]
}

output "worker_ips" {
  value = [for name in sort(keys(local.workers)) : local.workers[name].ip]
}

output "controlplane_vm_ids" {
  value = [for name in sort(keys(local.controlplanes)) : local.controlplanes[name].vmid]
}

output "worker_vm_ids" {
  value = [for name in sort(keys(local.workers)) : local.workers[name].vmid]
}
