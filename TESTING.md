# Twinbox Testing Guide

This project currently relies on operational verification for the manager-first runtime.

## 1. Static Checks

```bash
bash -n wizard/setup-wizard.sh scripts/wizard-dev-run.sh scripts/manager/apply-cluster.sh scripts/manager/create-talos-vms.sh scripts/manager/bootstrap-talos.sh scripts/manager/collect-state.sh
node --check manager-api/src/server.js
node --check manager-worker/src/worker.js
python3 -m pytest -q tests/scripts/test_wizard_dev_run.py tests/scripts/test_setup_wizard_cleanup.py tests/scripts/test_manager_scripts_args.py
```

## 2. Compose Validation

```bash
cp .env.example .env
docker compose config
rm .env
```

Expected: Compose config resolves without errors.

## 3. Runtime Smoke Test

```bash
cp .env.example .env
docker compose pull
docker compose up -d
docker compose ps
curl -fsS http://localhost:8080/api/health
```

Expected:

- `manager-web`, `manager-api`, `manager-worker` are running.
- Health endpoint returns JSON with `ok: true`.

## 4. Worker Runtime Tooling

```bash
docker compose run --rm manager-worker bash -lc 'bash --version >/dev/null && jq --version >/dev/null && tofu version >/dev/null && talosctl version >/dev/null'
```

Expected: exit code 0.

## 5. Job Lifecycle Check

1. Open UI at `http://<management-vm-ip>:3000`.
2. Submit a cluster deployment request.
3. Verify lifecycle: `pending -> running -> succeeded|failed`.
4. Verify logs in `manager-data/logs/<job_id>.log`.

## Scope Notes

- This document replaces older PostgreSQL/Redis/RQ-era testing instructions.
- No TUI test flow is supported.
