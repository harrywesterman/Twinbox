terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.1.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.16.0"
    }
  }
}

provider "coder" {}
provider "kubernetes" {}

variable "namespace" {
  description = "Kubernetes namespace where Twinbox development workspaces run."
  type        = string
  default     = "coder-workspaces"
}

variable "image" {
  description = "Twinbox development workspace image."
  type        = string
  default     = "ghcr.io/harrywesterman/twinbox-dev-workspace:latest"
}

variable "netbird_version" {
  description = "NetBird client version used by the rootless sidecar."
  type        = string
  default     = "0.77.1"
}

variable "repo_url" {
  description = "Git repository cloned into the workspace."
  type        = string
  default     = "https://github.com/harrywesterman/Twinbox.git"
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  name = "twinbox-dev-${data.coder_workspace.me.id}"
  labels = {
    "app.kubernetes.io/name"       = "twinbox-dev-workspace"
    "app.kubernetes.io/managed-by" = "coder"
    "coder.com/workspace-id"       = data.coder_workspace.me.id
    "coder.com/user-id"            = data.coder_workspace_owner.me.id
  }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder/code/Twinbox"

  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    twinbox-dev-startup
  EOT

  metadata {
    key          = "cpu"
    display_name = "CPU"
    interval     = 10
    timeout      = 1
    script       = "coder stat cpu"
  }

  metadata {
    key          = "memory"
    display_name = "Memory"
    interval     = 10
    timeout      = 1
    script       = "coder stat mem"
  }

  metadata {
    key          = "home"
    display_name = "Home disk"
    interval     = 60
    timeout      = 1
    script       = "df -h /home/coder | awk 'NR==2 {print $5 \" used of \" $2}'"
  }
}

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code"
  url          = "http://localhost:13337/?folder=/home/coder/code/Twinbox"
  icon         = "/icon/code.svg"
  share        = "owner"
  subdomain    = false
}

resource "coder_app" "opencode" {
  agent_id     = coder_agent.main.id
  slug         = "opencode"
  display_name = "OpenCode"
  url          = "http://localhost:4096"
  icon         = "/icon/terminal.svg"
  share        = "owner"
  subdomain    = false
}

resource "coder_app" "playwright" {
  agent_id     = coder_agent.main.id
  slug         = "playwright"
  display_name = "Playwright"
  url          = "http://localhost:9323"
  icon         = "/icon/globe.svg"
  share        = "owner"
  subdomain    = false
}

resource "coder_app" "ssh_login" {
  agent_id     = coder_agent.main.id
  slug         = "ssh-login"
  display_name = "Twinbox SSH Login"
  url          = "http://localhost:11110"
  icon         = "/icon/key.svg"
  share        = "owner"
  subdomain    = false
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "${local.name}-home"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn-single"

    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "netbird" {
  metadata {
    name      = "${local.name}-netbird"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn-single"

    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        service_account_name = "twinbox-dev-admin"

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
        }

        container {
          name              = "dev"
          image             = var.image
          image_pull_policy = "Always"
          command           = ["sh", "-c", coder_agent.main.init_script]

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }

          env {
            name  = "TWINBOX_REPO_URL"
            value = var.repo_url
          }

          env {
            name  = "TWINBOX_REPO_DIR"
            value = "/home/coder/code/Twinbox"
          }

          env {
            name  = "TWINBOX_NETBIRD_SOCKS_HOST"
            value = "127.0.0.1"
          }

          env {
            name  = "TWINBOX_NETBIRD_SOCKS_PORT"
            value = "1080"
          }

          env_from {
            config_map_ref {
              name = "coder-workspace-access"
            }
          }

          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
          }

          volume_mount {
            name       = "opkssh-config"
            mount_path = "/opt/twinbox-opkssh/config.yml"
            sub_path   = "config.yml"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "4"
              memory = "8Gi"
            }
            limits = {
              cpu    = "4"
              memory = "8Gi"
            }
          }
        }

        container {
          name              = "netbird"
          image             = "netbirdio/netbird:${var.netbird_version}-rootless"
          image_pull_policy = "IfNotPresent"

          env {
            name  = "NB_HOSTNAME"
            value = local.name
          }

          env {
            name  = "NB_USE_NETSTACK_MODE"
            value = "true"
          }

          env {
            name  = "NB_SOCKS5_LISTENER_ADDRESS"
            value = "127.0.0.1"
          }

          env {
            name  = "NB_SOCKS5_LISTENER_PORT"
            value = "1080"
          }

          env {
            name  = "NB_LOG_LEVEL"
            value = "info"
          }

          env_from {
            secret_ref {
              name = "coder-workspace-netbird"
            }
          }

          volume_mount {
            name       = "netbird-state"
            mount_path = "/var/lib/netbird"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "home"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
          }
        }

        volume {
          name = "netbird-state"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.netbird.metadata[0].name
          }
        }

        volume {
          name = "opkssh-config"

          secret {
            secret_name = "coder-workspace-opkssh-config"

            items {
              key  = "config.yml"
              path = "config.yml"
            }
          }
        }
      }
    }
  }
}
