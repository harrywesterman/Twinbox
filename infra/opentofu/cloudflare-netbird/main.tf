resource "cloudflare_dns_record" "netbird" {
  zone_id = var.cloudflare_zone_id
  name    = var.netbird_record_name
  type    = "A"
  content = var.target_ipv4
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "proxy" {
  zone_id = var.cloudflare_zone_id
  name    = var.proxy_record_name
  type    = "A"
  content = var.target_ipv4
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "proxy_wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*.${var.proxy_record_name}"
  type    = "CNAME"
  content = "${var.proxy_record_name}.${var.zone_name}"
  ttl     = 1
  proxied = false
}
