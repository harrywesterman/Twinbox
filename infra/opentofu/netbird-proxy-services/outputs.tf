output "service_ids" {
  value = {
    for name, service in netbird_reverse_proxy_service.services : name => service.id
  }
}
