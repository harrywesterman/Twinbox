variable "proxmox_endpoint" { type = string }
variable "proxmox_username" { type = string }
variable "proxmox_password" {
  type      = string
  sensitive = true
}
variable "node_name" { type = string }
variable "vm_id" { type = number }
variable "vm_name" { type = string }
variable "datastore_id" { type = string }
variable "file_datastore_id" { type = string }
variable "bridge" { type = string }
variable "ip_address" { type = string }
variable "prefix_length" { type = number }
variable "gateway" { type = string }
variable "dns_servers" { type = list(string) }
variable "data_disk_gb" { type = number }
variable "cloud_init" {
  type      = string
  sensitive = true
}
