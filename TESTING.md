# Twinbox Testing Guide

This document covers all validation layers for the Twinbox stack: static checks, unit tests, build verification, and runtime smoke tests.

## 1. Static Checks

### Shell scripts

```bash
bash -n wizard/setup-wizard.sh
bash -n scripts/manager/apply-cluster.sh
bash -n scripts/manager/bootstrap-talos.sh
bash -n scripts/manager/create-talos-vms.sh
bash -n scripts/manager/collect-state.sh
```

> Run `bash -n` on any `.sh` file you touch before committing.

### Node.js modules

```bash
node --check manager-api/src/server.js
node --check manager-api/src/index.mjs
node --check manager-worker/src/worker.js
```

> Run `node --check` on any `.js` or `.mjs` file you modify.

## 2. Lint & Format

Twinbox uses ESLint + Prettier for JavaScript/Ract and Ruff for Python.

### JavaScript / Node (all packages)

```bash
# Lint all JS/React/Node code
make lint

# Auto-fix lint issues
make lint-fix

# Format all code
make format

# Check formatting only (CI mode)
make format-check
```

Per-package (run from each package directory):
```bash
npm run lint          # Check for lint errors
npm run lint:fix      # Auto-fix lint errors
npm run format        # Format code with Prettier
npm run format:check  # Check formatting without writing
```

### Python (tests)

```bash
# Check Python code
ruff check tests/

# Auto-fix Python issues
ruff check --fix tests/

# Format Python code
ruff format tests/
```

## 3. Python Tests

Integration and contract tests for API behavior, script contracts, worker lifecycle, and secret resolution.

### Install dependencies

```bash
python3 -m pip install -r requirements-test.txt
```

### Run all Python tests

```bash
python3 -m pytest -q tests
```

### Run a specific module

```bash
python3 -m pytest -q tests/scripts/test_setup_wizard_cleanup.py
python3 -m pytest -q tests/api/test_catalog_api.py
python3 -m pytest -q tests/worker/test_worker_lifecycle.py
```

### Test categories

| Directory | Focus |
|-----------|-------|
| `tests/api/` | API contract tests (catalog, clusters, jobs, secrets) |
| `tests/scripts/` | Shell script argument parsing, env validation, secret broker contracts |
| `tests/worker/` | Job queue lifecycle and worker behavior |

## 4. Node.js Tests

Native `node --test` suites for the manager and portal codebases.

### Manager Worker

```bash
node --test manager-worker/test/*.mjs
```

Covers:
- Portal config rendering (`portal-config.test.mjs`, `refresh-portal-config.test.mjs`)
- Dashy config rendering (`dashy-config.test.mjs`, `refresh-dashy-config.test.mjs`)
- Grafana dashboard refresh (`refresh-grafana-dashboard.test.mjs`)

### Manager API

```bash
node --test manager-api/test/*.mjs
```

Covers:
- Catalog behavior (`catalog.test.mjs`)
- Karakeep integration (`karakeep.test.mjs`)

### Manager Web

```bash
node --test manager-web/test/*.mjs
```

Covers:
- Journey state, provision defaults, network and scaling logic
- App layout, step icons, catalog refresh
- Cluster public zone derivation (`cluster-public-zone.test.mjs`)
- Nginx proxy configuration (`nginx-proxy.test.mjs`)

### Portal

```bash
node --test portal/test/*.mjs
```

Covers:
- Server routes and middleware (`server.test.mjs`)
- Admin apps install and model (`admin-apps-*.test.mjs`)
- User-admin and observability models (`user-admin-model.test.mjs`, `admin-observability-model.test.mjs`)

## 5. Build Checks

Verify frontend bundles compile without errors.

### Manager Web

```bash
npm run build --prefix manager-web
```

### Portal

```bash
npm run build --prefix portal
```

## 6. Docker Compose Validation

Validate that the compose file resolves with the example environment:

```bash
cp .env.example .env && docker compose config >/dev/null && rm .env
```

Expected: silent exit (`0`).

## 7. Runtime Smoke Tests

Start the local stack and verify health.

```bash
cp .env.example .env
docker compose pull
docker compose up -d
docker compose ps
curl -fsS http://localhost:8080/api/health
```

Expected:
- `manager-web`, `manager-api`, `manager-worker` containers are running.
- Health endpoint returns JSON with `ok: true`.

### Worker toolchain check

```bash
docker compose run --rm manager-worker bash -lc 'bash --version >/dev/null && jq --version >/dev/null && tofu version >/dev/null && talosctl version >/dev/null'
```

Expected: exit code `0`.

## 8. Quick Pre-Commit Checklist

Before pushing changes, run the smallest relevant check from the list above:

- **Shell changes** → `bash -n <file>`
- **Node changes** → `node --check <file>`
- **Lint/format changes** → `make lint && make format-check`
- **Manager web changes** → `npm run build --prefix manager-web`
- **Portal changes** → `npm run build --prefix portal`
- **Worker module changes** → `node --test manager-worker/test/*.mjs`
- **API module changes** → `node --test manager-api/test/*.mjs`
- **Python testable changes** → `python3 -m pytest -q tests`
- **Compose or env changes** → `cp .env.example .env && docker compose config >/dev/null && rm .env`

## Scope Notes

- Talos cluster-level verification is covered in [`docs/verification.md`](docs/verification.md).
