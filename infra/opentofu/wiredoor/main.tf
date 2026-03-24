resource "hcloud_ssh_key" "default" {
  name       = "${var.server_name}-ssh-key"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "wiredoor" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image
  location    = var.location

  ssh_keys = [
    hcloud_ssh_key.default.id
  ]

  firewall_ids = [
    hcloud_firewall.wiredoor.id
  ]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = local.common_labels

  user_data = templatefile("${path.module}/cloud-init/wiredoor.yaml.tftpl", {
    wiredoor_fqdn                   = var.wiredoor_fqdn
    wiredoor_admin_email            = var.wiredoor_admin_email
    wiredoor_admin_password         = var.wiredoor_admin_password
    wiredoor_vpn_port               = var.wiredoor_vpn_port
    wiredoor_tcp_service_port_range = var.wiredoor_tcp_service_port_range
  })
}