locals {
  bootstrap_script_path = fileexists("${path.module}/cloud-init/netbird-bastion-bootstrap-template.sh") ? "${path.module}/cloud-init/netbird-bastion-bootstrap-template.sh" : "${path.module}/../../../scripts/manager/netbird-bastion-bootstrap-template.sh"
  crowdsec_helper_path  = "${path.module}/../../../scripts/manager/configure-netbird-crowdsec.py"

  common_labels = merge(
    {
      managed-by = "opentofu"
      project    = "netbird"
    },
    var.labels
  )
}
