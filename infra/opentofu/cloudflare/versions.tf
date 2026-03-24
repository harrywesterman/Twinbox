terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "opentofu/cloudflare"
      version = "~> 5.0"
    }
  }
}
