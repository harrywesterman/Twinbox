resource "cloudflare_dns_record" "wiredoor" {
  zone_id = var.cloudflare_zone_id
  name    = var.wiredoor_record_name
  type    = "A"
  content = var.target_ipv4
  ttl     = 1
  proxied = var.wiredoor_record_proxied
}

resource "cloudflare_dns_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  type    = "A"
  content = var.target_ipv4
  ttl     = 1
  proxied = var.wildcard_record_proxied
}