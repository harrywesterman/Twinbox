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

## 4. Vaultwarden Bootstrap

```bash
docker compose pull
docker compose up -d
docker compose ps vaultwarden
curl -fsS "http://${MANAGEMENT_VM_IP}:8222"
bw --version
bash scripts/bootstrap-vaultwarden.sh
```

Expected:

- Vaultwarden is reachable on the Management VM LAN IP and the manager containers can resolve the same URL.
- `bw` is installed on the host.
- The bootstrap run exits cleanly without requiring a browser or SSH tunnel to the Vaultwarden web UI.
- `/opt/twinbox/bootstrap/vaultwarden-client-id` and `/opt/twinbox/bootstrap/vaultwarden-client-secret` exist.
- `/opt/twinbox/bootstrap/vaultwarden-ready` exists.

## 5. Runtime Health

```bash
docker compose ps
curl -fsS http://localhost:8080/api/health
docker compose exec manager-worker env | grep PROXMOX_PASSWORD
```

Expected:

- `manager-web`, `manager-api`, `manager-worker` running.
- API health returns `{ "ok": true, ... }`.
- `PROXMOX_PASSWORD` is not present in the worker container environment.

## 6. Worker Runtime Tools

```bash
docker compose run --rm manager-worker bash -lc 'bash --version >/dev/null && jq --version >/dev/null && tofu version >/dev/null && talosctl version --client >/dev/null && kubectl version --client >/dev/null && helm version --short >/dev/null'
```

Expected: command exits with status 0.

## 7. Job Lifecycle

1. Submit provisioning from UI.
2. Verify state transitions: `pending` -> `running` -> `succeeded|failed`.
3. Confirm logs in `manager-data/logs/<job_id>.log`.

For `install-secret-sync`:

```bash
kubectl --kubeconfig <materialized-kubeconfig> get pods -n external-secrets
kubectl --kubeconfig <materialized-kubeconfig> get pods -n bitwarden
kubectl --kubeconfig <materialized-kubeconfig> get secretstores,externalsecrets,secrets -n twinbox-system
```

Expected:

- `external-secrets` deployment available.
- `bitwarden-cli` deployment available.
- `SecretStore` resources present in `twinbox-system`.
- `ExternalSecret/proxmox-bootstrap` ready.
- `Secret/proxmox-bootstrap` present.

## 8. Data Integrity

- `manager-data/clusters/*.json` populated.
- `manager-data/jobs/*.json` populated.
- Queue files move from `pending` to `completed`.
