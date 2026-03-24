# AGENTS.md

Twinbox is currently **manager-first**. Treat the repository docs below as the source of truth:

- `README.md`
- `docs/architecture.md`
- `docs/getting-started.md`
- `docs/configuration.md`
- `docs/verification.md`

## Current Flow

1. Run `wizard/setup-wizard.sh` on Proxmox.
2. The wizard creates only the Management VM.
3. The VM installs Docker CE, clones this repo, loads `.env`, and starts `docker compose`.
4. The web UI on port `3000` queues jobs through the API on port `8080`.
5. `manager-worker` polls the file queue under `manager-data/` and runs repo-owned scripts.

## Key Components

- `wizard/setup-wizard.sh` - Proxmox bootstrap.
- `manager-web/` - React UI.
- `manager-api/` - catalog, validation, job queueing, and state reads/writes.
- `manager-worker/` - queue polling and script execution.
- `scripts/manager/` - cluster provisioning and management scripts.
- `categories/` - manifest-driven step catalog and step scripts.
- `docker-compose.yml` - local/runtime service wiring.

## Editing Rules

- Use `docker compose`, not legacy `docker-compose`.
- Do not rely on historical TUI, PostgreSQL, Redis, or RQ docs.
- Keep `manager-data/` as runtime state only.
- Use `apply_patch` for manual file edits.
- Prefer small, targeted changes in the relevant component:
  - UI: `manager-web/src/*`
  - API: `manager-api/src/*`
  - Worker: `manager-worker/src/*`
  - Provisioning scripts: `scripts/manager/*`
  - Step manifests/scripts: `categories/*`

## Verification

Run the smallest useful checks for the area you changed:

- Shell: `bash -n` on touched scripts
- Node: `node --check` on touched entrypoints
- Compose: `docker compose config`
- Higher-level changes: the tests under `tests/`

## Operational Notes

- This is intended for trusted LAN use.
- Runtime secrets come from `.env`.
- The worker writes job logs and step state to `manager-data/`.
