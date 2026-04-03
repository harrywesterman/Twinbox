terraform {
  required_version = ">= 1.7"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2025.12"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
