resource "hcloud_ssh_key" "default" {
  name       = "${var.server_name}-ssh-key"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "netbird" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image
  location    = var.location

  ssh_keys = [
    hcloud_ssh_key.default.id
  ]

  firewall_ids = [
    hcloud_firewall.netbird.id
  ]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  labels = local.common_labels

  user_data = templatefile("${path.module}/cloud-init/netbird.yaml.tftpl", {
    netbird_fqdn            = var.netbird_fqdn
    netbird_proxy_domain    = var.netbird_proxy_domain
    public_zone_name        = var.public_zone_name
    netbird_admin_email     = var.netbird_admin_email
    admin_token_expire_days = var.netbird_admin_token_expire_days
    netbird_version         = var.netbird_version
    dns_provider            = var.dns_provider
    dns_api_token           = var.dns_api_token
    dns_api_secret          = var.dns_api_secret
    opkssh_issuer_url       = var.opkssh_issuer_url
    opkssh_client_id        = var.opkssh_client_id
  })
}
