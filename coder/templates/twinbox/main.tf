terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  username      = "coder"
  image_repo    = "ghcr.io/harrywesterman/twinbox-coder-workspace"
  cpu_cores     = data.coder_parameter.cpu_cores.value
  memory_gb     = data.coder_parameter.memory_gb.value
  disk_size     = data.coder_parameter.disk_size.value
  image_tag     = data.coder_parameter.image_tag.value
  storage_class = data.coder_parameter.storage_class.value
  namespace     = "coder-workspaces"
}

data "coder_parameter" "cpu_cores" {
  name         = "CPU Cores"
  type         = "number"
  description  = "Number of CPU cores for the workspace"
  default      = 4
  mutable      = false
  order        = 1
  validation {
    min       = 1
    max       = 16
    monotonic = "increasing"
  }
}

data "coder_parameter" "memory_gb" {
  name         = "Memory (GB)"
  type         = "number"
  description  = "Amount of RAM for the workspace"
  default      = 8
  mutable      = false
  order        = 2
  validation {
    min       = 2
    max       = 64
    monotonic = "increasing"
  }
}

data "coder_parameter" "disk_size" {
  name         = "Disk (GB)"
  type         = "number"
  description  = "Persistent home directory size"
  default      = 50
  mutable      = false
  order        = 3
  validation {
    min       = 10
    max       = 500
    monotonic = "increasing"
  }
}

data "coder_parameter" "image_tag" {
  name         = "Image Tag"
  type         = "string"
  description  = "Workspace image version tag from GHCR"
  default      = "latest"
  mutable      = true
  order        = 4
}

data "coder_parameter" "storage_class" {
  name         = "Storage Class"
  type         = "string"
  description  = "Kubernetes storage class for the home volume"
  default      = "longhorn-single"
  mutable      = false
  order        = 5
  option {
    name  = "Longhorn (single replica)"
    value = "longhorn-single"
  }
  option {
    name  = "Longhorn (3 replicas)"
    value = "longhorn"
  }
}

data "coder_workspace_preset" "small" {
  name = "Small"
  parameters = {
    cpu_cores = "2"
    memory_gb = "4"
    disk_size = "20"
  }
}

data "coder_workspace_preset" "medium" {
  name = "Medium"
  parameters = {
    cpu_cores = "4"
    memory_gb = "8"
    disk_size = "50"
  }
}

data "coder_workspace_preset" "large" {
  name = "Large"
  parameters = {
    cpu_cores = "8"
    memory_gb = "32"
    disk_size = "100"
  }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = data.coder_provisioner.me.arch

  env = {
    GIT_AUTHOR_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL = data.coder_workspace_owner.me.email
    TWINBOX_REPO     = "https://github.com/harrywesterman/Twinbox.git"
    WORKSPACE_NAME   = data.coder_workspace.me.name
  }

  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    if ! command -v code-server &>/dev/null; then
      curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server 2>/dev/null
    fi

    /tmp/code-server/bin/code-server \
      --auth none \
      --port 13337 \
      --disable-telemetry \
      /home/${local.username} >/tmp/code-server.log 2>&1 &
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Disk Usage"
    key          = "2_disk"
    script       = "coder stat disk /home/${local.username}"
    interval     = 10
    timeout      = 1
  }
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/${local.username}"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "coder_script" "clone-twinbox" {
  agent_id     = coder_agent.main.id
  display_name = "Clone Twinbox repo"
  icon         = "/icon/git.svg"
  script       = <<-EOT
    if [ ! -d /home/${local.username}/Twinbox/.git ]; then
      git clone https://github.com/harrywesterman/Twinbox.git /home/${local.username}/Twinbox
    fi
  EOT
  run_on_start = true
  log_path     = "/tmp/clone-twinbox.log"
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = local.namespace
    labels = {
      "coder.workspace_id"   = data.coder_workspace.me.id
      "coder.workspace_name" = data.coder_workspace.me.name
      "app.kubernetes.io/name" = "twinbox-workspace"
    }
  }
  wait_until_bound = true
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${local.disk_size}Gi"
      }
    }
    storage_class_name = local.storage_class != "" ? local.storage_class : null
  }
  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
    namespace = local.namespace
    labels = {
      "coder.workspace_id"       = data.coder_workspace.me.id
      "coder.workspace_name"     = data.coder_workspace.me.name
      "coder.workspace_owner"    = data.coder_workspace_owner.me.name
      "app.kubernetes.io/name"   = "twinbox-workspace"
      "app.kubernetes.io/part-of" = "twinbox"
    }
  }

  spec {
    security_context {
      run_as_user  = 1000
      run_as_group = 1000
      fs_group     = 1000
    }

    container {
      name    = "coder"
      image   = "${local.image_repo}:${local.image_tag}"
      command = ["sh", "-c", coder_agent.main.init_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      resources {
        requests = {
          cpu    = "${local.cpu_cores}"
          memory = "${local.memory_gb}Gi"
        }
        limits = {
          cpu    = "${local.cpu_cores}"
          memory = "${local.memory_gb}Gi"
        }
      }

      volume_mount {
        mount_path = "/home/${local.username}"
        name       = "home"
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }

    dns_config {
      option {
        name  = "ndots"
        value = "1"
      }
    }
  }
}
