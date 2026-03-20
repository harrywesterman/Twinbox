variable "proxmox_endpoint" {
  type = string
}

variable "proxmox_username" {
  type = string
}

variable "proxmox_password" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type = string
}

variable "vm_datastore" {
  type = string
}

variable "file_datastore" {
  type = string
}

variable "bridge" {
  type = string
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "prefix" {
  type = number
}

variable "cluster_name" {
  type = string
}

variable "cluster_slug" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "vip_ip" {
  type = string
}

variable "talos_version" {
  type = string
}

variable "talos_image_local_path" {
  type = string
}

variable "talos_image_cache_key" {
  type = string
}

variable "install_disk" {
  type    = string
  default = "/dev/vda"
}

variable "nodes" {
  type = map(object({
    ip      = string
    type    = string
    vmid    = number
    cpu     = number
    ram_mb  = number
    disk_gb = number
    mac     = string
  }))
}
