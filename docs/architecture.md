# Architecture

Twinbox uses a manager-first architecture centered on a Management VM.

## Components

1. **Wizard Layer**
   - `wizard/setup-wizard.sh` on Proxmox.
   - Creates and bootstraps only the Management VM.

2. **Manager Runtime Layer**
   - `manager-web` (UI, served via Nginx).
   - `manager-api` (REST API and job metadata).
   - `manager-worker` (queue polling + script execution).
   - `categories/` (manifest-driven catalog mounted into the API and worker).

3. **Execution Layer (inside worker image)**
   - `scripts/manager/apply-cluster.sh`
   - `scripts/manager/collect-state.sh`
   - `categories/*/steps/*/*.sh`

4. **State Layer**
   - `manager-data/clusters/*.json`
   - `manager-data/jobs/*.json`
   - `manager-data/logs/*.log`
   - `manager-data/step-state/*.json`
   - `manager-data/queue/{pending,running,completed}/*.json`
   - Talos configs and kubeconfig are runtime artifacts only and are not stored canonically under `manager-data/`.

## Request Flow

1. UI loads `/api/catalog` to discover categories, steps, saved inputs, and latest job state.
2. UI sends a step execution request (`/api/steps/{step_id}/execute`) or uses the compatibility cluster endpoints.
3. API validates inputs, persists step state, and writes the queue file.
4. Worker picks the queued job and runs the project-owned script for that step.
5. Worker streams command output to job logs and updates `manager-data/step-state`.
6. UI polls catalog, cluster, and log state to keep the operator view current.

## API Contracts (Current)

- `POST /api/clusters`
- `POST /api/clusters/{cluster_id}/bootstrap` (compatibility rerun hook)
- `GET /api/catalog`
- `POST /api/steps/{step_id}/execute`
- `GET /api/jobs/{job_id}`
- `GET /api/jobs/{job_id}/logs`
- `GET /api/health`

## Security Baseline

- LAN-only operational assumption.
- Vaultwarden runs on the Management VM and is exposed on the trusted LAN address of that VM so the host bootstrap and manager containers can resolve the same secret store.
- `manager-api` and `manager-worker` resolve secret refs through the broker at runtime; queued jobs and cluster state persist refs only.
- Talos file secrets are materialized into temporary runtime files and cleaned up after the job completes.
- The Management VM bootstraps the Vaultwarden service account and CLI API key automatically during first startup.
- No built-in auth/RBAC yet.
