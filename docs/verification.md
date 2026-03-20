# Verification

Use this checklist after deployment or major changes.

## 1. Basic Structure

- `wizard/setup-wizard.sh` exists and passes syntax check.
- `scripts/manager/*.sh` exist and are executable.
- `docs/` contains current operational docs.

## 2. Syntax Checks

```bash
bash -n wizard/setup-wizard.sh scripts/manager/apply-cluster.sh scripts/manager/create-talos-vms.sh scripts/manager/bootstrap-talos.sh scripts/manager/collect-state.sh
node --check manager-api/src/server.js
node --check manager-worker/src/worker.js
```

## 3. Compose Check

```bash
cp .env.example .env
docker compose config
rm .env
```

Expected: compose config renders successfully.

## 4. Runtime Health

```bash
docker compose pull
docker compose up -d
docker compose ps
curl -fsS http://localhost:8080/api/health
```

Expected:

- `manager-web`, `manager-api`, `manager-worker` running.
- API health returns `{ "ok": true, ... }`.

## 5. Worker Runtime Tools

```bash
docker compose run --rm manager-worker bash -lc 'bash --version >/dev/null && jq --version >/dev/null && tofu version >/dev/null && talosctl version --client >/dev/null && kubectl version --client >/dev/null && helm version --short >/dev/null'
```

Expected: command exits with status 0.

## 6. Job Lifecycle

1. Submit provisioning from UI.
2. Verify state transitions: `pending` -> `running` -> `succeeded|failed`.
3. Confirm logs in `manager-data/logs/<job_id>.log`.

## 7. Data Integrity

- `manager-data/clusters/*.json` populated.
- `manager-data/jobs/*.json` populated.
- Queue files move from `pending` to `completed`.
