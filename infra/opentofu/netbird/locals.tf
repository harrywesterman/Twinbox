locals {
  common_labels = merge(
    {
      managed-by = "opentofu"
      project    = "netbird"
    },
    var.labels
  )
}
