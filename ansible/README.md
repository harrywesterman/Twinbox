# Ansible

Ansible playbooks for Management VM configuration and maintenance.

## Overview

The Management VM baseline and ongoing maintenance are applied through Ansible after the initial cloud-init bootstrap. Playbooks in this directory are invoked by scripts in `scripts/`.

## Files

| File | Purpose |
|------|---------|
| `management-vm-maintenance.yml` | Nightly patching, Docker updates, NTP sync, and host hardening |

## Usage

### Manual Run

```bash
ansible-playbook -i localhost, -c local ansible/management-vm-maintenance.yml
```

### Automated (via systemd)

The `scripts/install-management-vm-maintenance.sh` script installs a systemd timer that runs this playbook periodically:

- **Service:** `twinbox-management-maintenance.service`
- **Timer:** `twinbox-management-maintenance.timer`

## What It Does

The maintenance playbook ensures the Management VM stays healthy and secure:

- Updates Ubuntu packages (`apt update && apt upgrade`)
- Ensures Docker CE is installed and running
- Pins NTP to the configured time server
- Applies host hardening rules (SSH, firewall, fail2ban where applicable)
- Cleans up old Docker images and volumes

## Related

- `scripts/management-vm-maintenance.sh` — Wrapper script that installs `ansible-core` if needed and runs the playbook
- `systemd/twinbox-management-maintenance.service` — systemd service unit
- `systemd/twinbox-management-maintenance.timer` — systemd timer unit
