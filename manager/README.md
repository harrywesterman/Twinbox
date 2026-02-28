# manager/ (Legacy)

This directory documents a legacy architecture and is not part of the active runtime path.

## Active Runtime

Use these components instead:

- `manager-web/`
- `manager-api/`
- `manager-worker/`
- root `docker-compose.yml`
- `scripts/manager/`

## Active Deployment Flow

1. Run `wizard/setup-wizard.sh` on Proxmox.
2. Wizard creates Management VM and auto-starts stack via cloud-init.
3. Open UI at `http://<management-vm-ip>:3000`.

For current instructions, use root `README.md` and `docs/*`.
