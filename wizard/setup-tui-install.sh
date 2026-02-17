#!/usr/bin/env bash
set -euo pipefail

# Twinbox TUI Installer for Proxmox Host
# Usage: setup-tui-install.sh [--start] [--help]
#   --start    Automatically start the TUI after installation completes
#   --help     Show this help message
#
# Without --start: installs and shows manual start instructions
# With --start: installs and immediately launches the TUI

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
REPO_URL="${TWINBOX_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
INSTALL_DIR="${TWINBOX_INSTALL_DIR:-/opt/twinbox}"
VENV_DIR="$INSTALL_DIR/twinbox-tui/.venv"

# Determine log file location - ensure writable
if [[ -w "/var/log" ]]; then
    LOG_FILE="/var/log/twinbox-tui-install.log"
else
    LOG_FILE="/tmp/twinbox-tui-install.log"
    warn "/var/log not writable, using $LOG_FILE"
fi

# Non-interactive mode flag
NONINTERACTIVE="${NONINTERACTIVE:-false}"

# Parse command line arguments
AUTO_START=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --start)
            AUTO_START=true
            shift
            ;;
        --help)
            echo "Twinbox TUI Installer"
            echo "Usage: $0 [--start]"
            echo "  --start    Automatically start the TUI after installation"
            echo "  --help     Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

log() { echo -e "${YELLOW}[*] $*${NC}" | tee -a "$LOG_FILE" >&2; }
ok() { echo -e "${GREEN}[✓] $*${NC}" | tee -a "$LOG_FILE" >&2; }
err() { echo -e "${RED}[✗] $*${NC}" | tee -a "$LOG_FILE" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!] $*${NC}" | tee -a "$LOG_FILE" >&2; }

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "Run as root."
    fi
}

check_proxmox() {
    [[ -d /etc/pve ]] || { err "This script must run on a Proxmox VE host"; exit 1; }
    command -v qm &>/dev/null || { err "qm command not found. Is Proxmox installed?"; exit 1; }
    ok "Proxmox environment verified"
}

install_dependencies() {
    log "Installing dependencies..."
    apt-get update >>"$LOG_FILE" 2>&1 || err "apt-get update failed"
    apt-get install -y \
        python3 \
        python3-venv \
        python3-pip \
        git \
        curl \
        cloud-image-utils \
        cloud-utils \
        >>"$LOG_FILE" 2>&1 || err "Failed to install packages"
    ok "Dependencies installed"
}

clone_tui_only() {
    # Minimal installation: only clone twinbox-tui directory using sparse-checkout
    local temp_dir="/tmp/twinbox-temp-$$"
    local tui_target_dir="$INSTALL_DIR/twinbox-tui"
    
    # Ensure cleanup on exit
    trap 'rm -rf "$temp_dir"' EXIT
    
    if [[ -d "$tui_target_dir" ]]; then
        log "Existing installation found at $tui_target_dir, removing..."
        rm -rf "$tui_target_dir"
    fi

    log "Cloning only twinbox-tui directory (sparse checkout)..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$temp_dir"
    
    # Initialize git repository properly
    if git init --initial-branch=main "$temp_dir" 2>/dev/null; then
        true  # success
    else
        git init "$temp_dir" 2>/dev/null
        git -C "$temp_dir" branch -m main 2>/dev/null || true
    fi
    
    git -C "$temp_dir" remote add origin "$REPO_URL"
    git -C "$temp_dir" config core.sparseCheckout true
    echo "twinbox-tui/" > "$temp_dir/.git/info/sparse-checkout"
    git -C "$temp_dir" pull --depth=1 origin main
    
    # Move twinbox-tui to target location
    if [[ -d "$temp_dir/twinbox-tui" ]]; then
        mv "$temp_dir/twinbox-tui" "$tui_target_dir"
    else
        err "Failed to clone twinbox-tui directory. Check REPO_URL and repository structure."
        exit 1
    fi
    
    ok "twinbox-tui cloned to $tui_target_dir"
}

setup_runtime() {
    log "Setting up Python virtual environment..."
    local tui_dir="$INSTALL_DIR/twinbox-tui"
    [[ -d "$tui_dir" ]] || { err "twinbox-tui directory not found at $tui_dir"; exit 1; }

    if [[ -d "$VENV_DIR" ]]; then
        log "Virtual environment already exists at $VENV_DIR"
        if [[ "$NONINTERACTIVE" = "true" ]] || [[ -n "${NONINTERACTIVE:-}" && "$NONINTERACTIVE" == "true" ]]; then
            RECREATE="n"
        else
            read -p "Recreate virtual environment? [y/N]: " -r RECREATE
        fi
        if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
            rm -rf "$VENV_DIR"
            python3 -m venv "$VENV_DIR" >>"$LOG_FILE" 2>&1 || err "venv creation failed"
            ok "Virtual environment recreated"
        else
            ok "Using existing virtual environment"
            return 0
        fi
    else
        python3 -m venv "$VENV_DIR" >>"$LOG_FILE" 2>&1 || err "venv creation failed"
        ok "Virtual environment created at $VENV_DIR"
    fi

    log "Installing Python dependencies..."
    # Use venv's pip directly to avoid activation issues
    "$VENV_DIR/bin/pip" install --upgrade pip >>"$LOG_FILE" 2>&1 || err "pip upgrade failed"
    "$VENV_DIR/bin/pip" install -e "$tui_dir" >>"$LOG_FILE" 2>&1 || err "editable install failed"
    ok "Python dependencies installed"
}

show_completion() {
    cat <<EOF

==========================================
 Twinbox TUI Installation Complete!
==========================================

The Twinbox TUI has been installed and is ready to use.

Repository: $INSTALL_DIR
Virtual Environment: $VENV_DIR
EOF

    if $AUTO_START; then
        echo ""
        echo "Starting the TUI automatically..."
        echo ""
        exec "$VENV_DIR/bin/twinbox-tui"
    else
        cat <<EOF

To start the TUI:

  # Switch to tty1 (physical console)
  sudo chvt 1

  # Start the TUI
  sudo $VENV_DIR/bin/twinbox-tui

  # Or activate the virtual environment and run:
  # source $VENV_DIR/bin/activate
  # twinbox-tui

To update to the latest version:

  git -C $INSTALL_DIR pull origin main
  source $VENV_DIR/bin/activate
  pip install -e $INSTALL_DIR/twinbox-tui

To uninstall:

  rm -rf $INSTALL_DIR
  rm -rf /root/.local/share/twinbox

==========================================
EOF
    fi
}

main() {
    require_root
    check_proxmox
    
    # Validate repository URL
    if [[ ! "$REPO_URL" =~ ^https://github.com/.*\.git$ ]]; then
        err "Invalid REPO_URL: must be a GitHub URL ending in .git"
        exit 1
    fi
    
    # Check git is available
    if ! command -v git &>/dev/null; then
        err "git is required but not installed"
        exit 1
    fi
    
    install_dependencies
    
    log "Installing twinbox-tui (minimal installation)..."
    clone_tui_only
    
    setup_runtime
    show_completion
}

main "$@"
