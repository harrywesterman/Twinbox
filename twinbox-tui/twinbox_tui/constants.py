"""
Application constants for Twinbox TUI.

Centralized values for defaults, status codes, messages, and UI configuration.
"""

from enum import Enum
from pathlib import Path

# Default configuration values
DEFAULT_CPU_CORES = 2
DEFAULT_RAM_MB = 4096
DEFAULT_DISK_GB = 32
DEFAULT_BRIDGE = "vmbr0"
DEFAULT_STORAGE = "local-lvm"
DEFAULT_CP_COUNT = 3
DEFAULT_WORKER_COUNT = 0

# VM ID allocation
VMID_START_RANGE = 100
VMID_MAX_ATTEMPTS = 1000

# SSH configuration
SSH_DEFAULT_USER = "twinbox"
SSH_DEFAULT_PORT = 22
SSH_TIMEOUT = 30
SSH_MAX_RETRIES = 3

# Deployment phases
PHASE_1_NAME = "Management VM Creation"
PHASE_2_NAME = "Manager Installation"

PHASE_1_PERCENT = 50  # Phase 1 covers 0-50%
PHASE_2_PERCENT = 50  # Phase 2 covers 50-100%

# Deployment step definitions for progress tracking
PHASE_1_STEPS = [
    "Discovering available VM IDs",
    "Creating Proxmox user and token",
    "Generating API token",
    "Downloading Ubuntu cloud image",
    "Uploading image to storage",
    "Creating cloud-init snippet",
    "Creating management VM",
    "Importing and attaching disk",
    "Configuring cloud-init",
    "Starting VM",
    "Waiting for VM IP address",
]

PHASE_2_STEPS = [
    "Waiting for SSH to become available",
    "Cloning Twinbox repository",
    "Creating environment configuration",
    "Installing Python dependencies",
    "Initializing database",
    "Starting PostgreSQL and Redis",
    "Starting Web and Worker services",
    "Verifying service health endpoints",
    "Finalizing deployment",
]

# Cluster status values
class ClusterStatus(str, Enum):
    PENDING = "pending"
    INSTALLING = "installing"
    DEPLOYED = "deployed"
    FAILED = "failed"

STATUS_COLORS = {
    ClusterStatus.PENDING: "yellow",
    ClusterStatus.INSTALLING: "blue",
    ClusterStatus.DEPLOYED: "green",
    ClusterStatus.FAILED: "red",
}

STATUS_LABELS = {
    ClusterStatus.PENDING: "Pending",
    ClusterStatus.INSTALLING: "Installing",
    ClusterStatus.DEPLOYED: "Deployed",
    ClusterStatus.FAILED: "Failed",
}

# Deployment status values
class DeploymentStatus(str, Enum):
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"
    CANCELLED = "cancelled"

# Log levels
class LogLevel(str, Enum):
    DEBUG = "DEBUG"
    INFO = "INFO"
    WARNING = "WARNING"
    ERROR = "ERROR"
    SUCCESS = "SUCCESS"

# UI Text constants
APP_TITLE = "Twinbox"
APP_SUBTITLE = "Kubernetes on Proxmox"

# Keyboard shortcuts
KEY_NEW_DEPLOYMENT = "n"
KEY_VIEW_LOGS = "v"
KEY_RETRY = "r"
KEY_DELETE = "d"
KEY_REFRESH = "f5"
KEY_HELP = "?"
KEY_QUIT = "q"

# Dashboard refresh interval (seconds)
DASHBOARD_REFRESH_INTERVAL = 30

# Cloud-init configuration template (simplified)
CLOUD_INIT_TEMPLATE = """#cloud-config
growpart:
  mode: auto
  devices:
    - "/"
  ignore_growroot_disabled: true
package_update: true
package_upgrade: true
packages: [docker.io, git, qemu-guest-agent]
runcmd:
  - [groupadd, -r, twinbox]
  - [useradd, -r, -g, twinbox, -m, -s, /bin/bash, twinbox]
  - echo "twinbox:{password}" | chpasswd
  - [usermod, -aG, docker, twinbox]
  - [usermod, -aG, sudo, twinbox]
  - [systemctl, enable, qemu-guest-agent]
  - [systemctl, start, qemu-guest-agent]
  - [systemctl, enable, docker]
  - [systemctl, start, docker]
  - [systemctl, daemon-reload]
  - [systemctl, restart, ssh]
write_files:
  - path: /etc/ssh/sshd_config.d/00-twinbox.conf
    permissions: '0644'
    content: |
      PasswordAuthentication yes
      PermitRootLogin no
  - path: /etc/motd
    permissions: '0644'
    content: |
      Twinbox Management VM

      SSH: twinbox@<this-ip>
      Docker: Installed

      Phase 1 complete. SSH into this VM and install the Twinbox platform manually.
"""

# URLs
TWINBOX_REPO_URL = "https://github.com/yourorg/Twinbox.git"
TWINBOX_INSTALL_DIR = "/opt/twinbox"

# Paths (relative to home)
DEFAULT_CONFIG_DIR = Path.home() / ".config" / "twinbox"
DEFAULT_DATA_DIR = Path.home() / ".local" / "share" / "twinbox"
DEFAULT_LOG_DIR = DEFAULT_DATA_DIR / "logs"

# File names
CONFIG_FILE = DEFAULT_CONFIG_DIR / "config.yaml"
STATE_DB_FILE = DEFAULT_DATA_DIR / "tui-state.db"
