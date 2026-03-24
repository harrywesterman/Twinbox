locals {
  wiredoor_fqdn = "${var.wiredoor_record_name}.${var.zone_name}"
  wildcard_fqdn = "*.${var.zone_name}"
}