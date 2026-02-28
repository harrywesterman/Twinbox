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

3. **Execution Layer (inside worker image)**
   - `scripts/manager/create-talos-vms.sh`
   - `scripts/manager/bootstrap-talos.sh`
   - `scripts/manager/collect-state.sh`

4. **State Layer**
   - `manager-data/clusters/*.json`
   - `manager-data/jobs/*.json`
   - `manager-data/logs/*.log`
   - `manager-data/queue/{pending,running,completed}/*.json`

## Request Flow

1. UI sends API request (`/api/clusters` or `/api/clusters/{id}/bootstrap`).
2. API writes cluster/job records and queue file.
3. Worker picks queued job and runs allowlisted script from the image.
4. Worker streams command output to job logs.
5. UI polls job status and logs.

## API Contracts (Current)

- `POST /api/clusters`
- `POST /api/clusters/{cluster_id}/bootstrap`
- `GET /api/jobs/{job_id}`
- `GET /api/jobs/{job_id}/logs`
- `GET /api/health`

## Security Baseline

- LAN-only operational assumption.
- Credentials loaded from `.env`.
- No built-in auth/RBAC yet.
