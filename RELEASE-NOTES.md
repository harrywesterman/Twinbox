# Release Notes

## 2026-02-28

### Manager-first Runtime

- Added root `docker-compose.yml` for manager runtime.
- Added `manager-api` for job and cluster endpoints.
- Added `manager-worker` for async job execution.
- Added manager scripts under `scripts/manager/`:
  - `create-talos-vms.sh`
  - `bootstrap-talos.sh`
  - `collect-state.sh`

### Docker Image Publishing

- Added GitHub Actions workflow `.github/workflows/docker-publish.yml`.
- Workflow publishes public GHCR images for:
  - `twinbox-manager-api`
  - `twinbox-manager-worker`
  - `twinbox-manager-web`
- Compose now pulls prebuilt images instead of local builds.

### Wizard and Infra

- `wizard/setup-wizard.sh` uses Docker CE from official Docker apt repository on Management VM.
- Embedded static dashboard payload from wizard was removed.

### Repository Cleanup

- Removed historical plans under `docs/plans/`.
- Removed legacy `twinbox/` directory tree.
- Migrated active docs and metadata to root locations.

### Documentation

- Rewrote README and operational docs under `docs/` to match current manager-first structure and paths.
