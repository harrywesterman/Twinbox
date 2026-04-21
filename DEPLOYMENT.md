# Twinbox Deployment Guide

This guide reflects the current manager-first deployment flow.

## Flow

1. Run `wizard/setup-wizard.sh` on Proxmox.
2. Wizard creates only the Management VM.
3. Cloud-init on that VM:
   - installs Docker CE from the official Docker repo,
   - writes runtime files under `/opt/twinbox`,
   - downloads the runtime start script into `/opt/twinbox/scripts`,
   - bootstraps the manager stack once from the published Docker images.
4. Open the UI and continue cluster provisioning from the browser.

## Run the Wizard

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

## Access

- UI: `http://<management-vm-ip>:3000`
- API health: `http://<management-vm-ip>:8080/api/health`

## Optional Recovery on Management VM

```bash
ssh ubuntu@<management-vm-ip>
cd /opt/twinbox
# edit .env if needed
docker compose pull
docker compose up -d
```

## Runtime Images

Twinbox uses prebuilt public images:

- `ghcr.io/harrywesterman/twinbox-manager-web`
- `ghcr.io/harrywesterman/twinbox-manager-api`
- `ghcr.io/harrywesterman/twinbox-manager-worker`

## Notes

- No TUI path is supported.
- No app-level authentication yet (LAN-only assumption in phase 1).
