# Twinbox Summary

## Platform Shape

Twinbox is a manager-first deployment flow for Talos on Proxmox.

- Proxmox wizard provisions infrastructure baseline.
- Management VM hosts the manager stack.
- UI/API/Worker coordinate async provisioning and bootstrap jobs.
- Runtime services use prebuilt public GHCR images.

## Core Components

- `wizard/setup-wizard.sh`
- `docker-compose.yml`
- `manager-web/`
- `manager-api/`
- `manager-worker/`
- `scripts/manager/`
- `manager-data/`

## Phase 1 Delivered

- Job-driven Talos VM provisioning.
- Job-driven Talos bootstrap.
- Persistent job state + logs.

## Planned Next Phase

- ArgoCD workflow integration.
- Application sync workflows.
- Authentication and RBAC for manager access.
