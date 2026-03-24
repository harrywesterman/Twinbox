locals {
  common_labels = merge(
    {
      managed-by = "opentofu"
      project    = "wiredoor"
    },
    var.labels
  )
}