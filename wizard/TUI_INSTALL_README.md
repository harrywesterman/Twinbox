# Twinbox TUI Manual Installation

This guide explains how to install `twinbox-tui` on a Proxmox VE host for **manual, one-time use** without autostart or systemd service.

## Overview

The `setup-tui-install.sh` script installs the Twinbox TUI application directly on the Proxmox host. After installation, you manually start the TUI when needed from the console or via SSH.

This is ideal for:
- Occasional use without wanting it to run continuously
- Testing and evaluation
- Environments where automatic startup is not desired
- Situations where you want full control over when the TUI runs

## Prerequisites

- **Proxmox VE 8.x** host
- **Root access** to the Proxmox host
- Internet connectivity
- ~500MB free disk space

## What Gets Installed

1. **System dependencies**: Python 3, venv, pip, git, curl
2. **Twinbox TUI code**: Either:
   - **Minimal**: Only the `twinbox-tui/` directory (sparse checkout, ~1MB)
   - **Full**: Complete Twinbox repository including manager, worker, docs, etc. (~50MB)
3. **Python virtual environment**: With all required packages

**No systemd service is created** - you start the TUI manually when needed.

## Installation

Run the installer directly on your Proxmox host:

### Option 1: One-liner (install and auto-start)

Use the `--start` flag to install and immediately launch the TUI:

```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-tui-install.sh -o /tmp/setup-tui-install.sh && chmod +x /tmp/setup-tui-install.sh && bash /tmp/setup-tui-install.sh --start
```

Or if you already have the Twinbox repository locally:

```bash
cd /path/to/Twinbox && bash wizard/setup-tui-install.sh --start
```

This will install the TUI and automatically start it after completion.

### Option 2: Standard installation (manual start later)

```bash
# One-command installation (clones repo and installs)
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-tui-install.sh -o /tmp/setup-tui-install.sh
chmod +x /tmp/setup-tui-install.sh
bash /tmp/setup-tui-install.sh

# Or if you already have the Twinbox repository locally:
cd /path/to/Twinbox
bash wizard/setup-tui-install.sh
```

The installer will:
1. Verify you're on a Proxmox host
2. Install required packages (python3, python3-venv, python3-pip, git, curl)
3. Ask for installation type:
   - **tui** (minimal): Only clones the `twinbox-tui/` directory using sparse checkout (~1MB)
   - **full**: Clones the entire Twinbox repository (~50MB) including manager, worker, docs
4. Create a Python virtual environment and install all dependencies
5. Show completion message with instructions (or auto-start if `--start` was used)

## Installation Type Comparison

| Aspect | Minimal (tui only) | Full Repository |
|--------|-------------------|-----------------|
| Size | ~1MB | ~50MB |
| Contents | Only twinbox-tui/ | Everything (manager, worker, docs, etc.) |
| Use case | Just running the TUI | Development, exploring full codebase |
| Update | `git -C /opt/twinbox pull` | `git -C /opt/twinbox pull` |

**Recommendation**: Choose **minimal** if you only want to run the TUI. Choose **full** if you plan to develop or need access to other components.

## Running the TUI

If you used `--start` during installation, the TUI is already running. Otherwise, after installation completes, you can start the TUI in two ways:

### Option 1: Via SSH (Recommended for remote management)

SSH into your Proxmox host and run:

```bash
# Direct execution
sudo /opt/twinbox/twinbox-tui/.venv/bin/twinbox-tui

# Or activate the virtual environment first
source /opt/twinbox/twinbox-tui/.venv/bin/activate
twinbox-tui
```

The TUI will start in your SSH terminal session. When done, press `q` or `Ctrl+C` to exit.

**Note**: The TUI requires a terminal with proper TTY support. Most SSH clients work fine, but some features may be limited depending on your terminal emulator.

### Option 2: On the physical console (tty1)

If you're at the Proxmox host physically or have console access via IPMI/iDRAC:

```bash
# Switch to tty1 (the physical console)
sudo chvt 1

# Log in if prompted, then start:
sudo /opt/twinbox/twinbox-tui/.venv/bin/twinbox-tui
```

The TUI will display on the physical monitor attached to the Proxmox host.

## Use Cases

- **SSH**: Most convenient for remote administration from your laptop/workstation
- **Physical console**: Useful when you're at the server or need direct KVM access
- **Both**: The TUI can be started from either method; they both work identically

## Updating the TUI

To update to the latest version:

```bash
# Pull latest changes from the repository
git -C /opt/twinbox pull origin main

# Reinstall dependencies (if requirements changed)
source /opt/twinbox/twinbox-tui/.venv/bin/activate
pip install -e /opt/twinbox/twinbox-tui
```

## Uninstalling

To remove the TUI completely:

```bash
# Remove the repository and virtual environment
rm -rf /opt/twinbox

# Remove user data (backup first if needed)
rm -rf /root/.local/share/twinbox

# Optionally remove installed packages (they're shared with system)
# apt-get remove python3-venv python3-pip git curl  # Only if you want to remove these
```

## Configuration

The TUI reads configuration from environment variables and defaults. Key options:

- **Database path**: `~/.local/share/twinbox/tui-state.db`
- **Log directory**: `~/.local/share/twinbox/logs`
- **SSH settings**: timeout, port, user, retries
- **Default VM resources**: cores, RAM, disk, bridge, storage

See `twinbox-tui/twinbox_tui/config.py` for all configuration options.

You can set environment variables or create a `.env` file in the repository root (`/opt/twinbox/twinbox-tui/.env`) to override defaults.

## Troubleshooting

### TUI fails to start

```bash
# Check if virtual environment exists and is complete
ls -la /opt/twinbox/twinbox-tui/.venv/bin/twinbox-tui

# Reinstall dependencies
source /opt/twinbox/twinbox-tui/.venv/bin/activate
pip install -e /opt/twinbox/twinbox-tui
```

### Permission errors

Ensure you're running as root or have appropriate permissions to access the database and log directories:

```bash
# Check directory permissions
ls -la /root/.local/share/twinbox/
```

### Python import errors

Make sure you've activated the virtual environment or are using the full path to the executable.

### Terminal issues over SSH

If the TUI doesn't display correctly over SSH:
- Ensure your terminal supports UTF-8 and has adequate size
- Try setting `TERM=xterm-256color` before running
- Use a different SSH client or terminal emulator
- As a fallback, use the physical console (tty1)

## Security Considerations

- The TUI runs with the privileges of the user who starts it (typically root)
- Store credentials securely; the TUI may access Proxmox API and SSH keys
- If multiple users have console/SSH access, consider who can start the TUI
- The TUI stores state in `~/.local/share/twinbox/` - protect this directory
- SSH access should be secured with key-based authentication

## Support

For issues, questions, or contributions:
https://github.com/harrywesterman/Twinbox
