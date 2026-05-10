# Systemd Units

Systemd service and timer units for the Twinbox Management VM.

## Overview

These units automate recurring maintenance tasks on the Management VM, primarily running the Ansible maintenance playbook for patching and hardening.

## Files

| File | Type | Purpose |
|------|------|---------|
| `twinbox-management-maintenance.service` | Service unit | Executes the Management VM maintenance playbook |
| `twinbox-management-maintenance.timer` | Timer unit | Triggers the service on a schedule |

## Installation

The units are installed by `scripts/install-management-vm-maintenance.sh`:

```bash
bash scripts/install-management-vm-maintenance.sh
```

This copies the units to `/etc/systemd/system/` and enables the timer.

## Timer Schedule

By default, the maintenance timer triggers nightly. Check the timer file for the exact `OnCalendar` schedule.

## Manual Trigger

```bash
sudo systemctl start twinbox-management-maintenance.service
```

## Logs

```bash
sudo journalctl -u twinbox-management-maintenance.service
```

## Related

- `ansible/management-vm-maintenance.yml` — The playbook executed by the service
- `scripts/management-vm-maintenance.sh` — Script that installs ansible-core and runs the playbook
- `scripts/install-management-vm-maintenance.sh` — Installation script for these units
