# CLAUDE.md

This repository currently follows a manager-first architecture.

## Source of Truth

- Root `README.md`
- `docs/architecture.md`
- `docs/getting-started.md`
- `docs/configuration.md`
- `docs/verification.md`

## Current Runtime Components

- `wizard/setup-wizard.sh`
- `manager-web/`
- `manager-api/`
- `manager-worker/`
- `scripts/manager/`
- root `docker-compose.yml`

## Current Flow

1. Run wizard on Proxmox.
2. Wizard creates only Management VM.
3. Cloud-init installs Docker CE (official Docker repo), clones repo, writes `.env`, and starts stack.
4. Use browser UI on port `3000` to provision/bootstrap Talos nodes.

## Notes

- Do not use historical TUI instructions.
- Do not use historical PostgreSQL/Redis/RQ manager docs as active guidance.
- Prefer `docker compose` (space), not legacy `docker-compose`.
