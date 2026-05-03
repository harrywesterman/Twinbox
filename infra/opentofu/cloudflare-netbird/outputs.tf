output "netbird_record_name" {
  value = cloudflare_dns_record.netbird.name
}

output "proxy_record_name" {
  value = cloudflare_dns_record.proxy.name
}

output "proxy_wildcard_record_name" {
  value = cloudflare_dns_record.proxy_wildcard.name
}
