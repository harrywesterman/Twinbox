# AGENTS.md

Twinbox is a Talos Linux based configuration for a Kubernetes cluster. Treat these documents as the source of truth:

- `README.md`
- `docs/architecture.md`
- `docs/getting-started.md`
- `docs/configuration.md`
- `docs/verification.md`

## Current State

- The repository’s active branch is `main`. Only big redesigned get their own branch.
- `manager-data/` is runtime state only.

## Current Flow

1. Run `wizard/setup-wizard.sh` on Proxmox.
2. The wizard creates only the Management VM.
3. The Management VM installs Docker CE, clones Twinbox into `/opt/twinbox`, loads `.env`, and starts `docker compose`.
4. `manager-web` on port `3000` queues work through `manager-api` on port `8080`.
5. `manager-worker` polls the file queue under `manager-data/` and runs repo-owned scripts.
6. `provision-nodes` starts the Talos journey, sizes the cluster, lands the VMs, and records the cluster state.
7. `install-secret-sync` installs External Secrets Operator and OpenBao after Longhorn.

## Key Components

- `wizard/setup-wizard.sh` - Proxmox bootstrap.
- `manager-web/` - React UI.
- `manager-api/` - catalog, validation, job queueing, and state reads/writes.
- `manager-worker/` - queue polling and script execution.
- `scripts/manager/` - cluster provisioning and management scripts.
- `categories/` - manifest-driven step catalog and step scripts.
- `docker-compose.yml` - local/runtime service wiring.

## Editing Rules

- use the ssh connection skill to connect to the management VM for debugging.
- Use the Playwright skill to look at the live web wizard.
- Use `docker compose`, not legacy `docker-compose`.
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

- The worker writes job logs and step state to `manager-data/`.
