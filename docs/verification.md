# Verification

Use this checklist after deployment or major changes.

## 1. Basic Structure

- `wizard/setup-wizard.sh` exists and passes syntax check.
- `scripts/manager/*.sh` exist and are executable.
- `docs/` contains current operational docs.
- Wizard cleanup uses Proxmox cluster inventory and can remove cluster VMs even when they are spread across multiple Proxmox hosts.

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

If the bootstrap stops after registering `twinbox@local` but before writing `vaultwarden-ready`, rerun it with `sudo bash scripts/bootstrap-vaultwarden.sh` from `/opt/twinbox` after Vaultwarden is healthy. That refreshes the Bitwarden CLI sync state and finishes the API-key bootstrap.

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
kubectl --kubeconfig <materialized-kubeconfig> get networkpolicy -n bitwarden
kubectl --kubeconfig <materialized-kubeconfig> get deployment bitwarden-cli -n bitwarden -o yaml | grep -E 'runAsNonRoot|allowPrivilegeEscalation|capabilities|seccompProfile|BITWARDENCLI_APPDATA_DIR|emptyDir'
KUBECONFIG_FILE=<materialized-kubeconfig> bash scripts/manager/refresh-bitwarden-cli.sh
kubectl --kubeconfig <materialized-kubeconfig> get pods -n external-secrets -o wide
kubectl --kubeconfig <materialized-kubeconfig> get pods -n bitwarden -o wide
kubectl --kubeconfig <materialized-kubeconfig> get secretstores,externalsecrets,secrets -n twinbox-system
```

Expected:

- `external-secrets` deployment available.
- `bitwarden-cli` deployment available.
- `NetworkPolicy/bitwarden-cli-allow-external-secrets` present in `bitwarden`.
- `bitwarden-cli` deployment shows restricted-compatible `securityContext` and writable appdata.
- `external-secrets`, `external-secrets-webhook`, `external-secrets-cert-controller`, and `bitwarden-cli` all run on the control-plane node.
- `SecretStore` resources present in `twinbox-system`.
- `Secret/proxmox-bootstrap` present.
- `ExternalSecret/proxmox-bootstrap` may still reconcile in the background, but the bootstrap secret itself must already exist.
- Running the refresh helper immediately re-syncs the in-cluster Bitwarden CLI bridge when new Vaultwarden-backed items need to be picked up.

For `install-argocd`:

```bash
kubectl --kubeconfig <materialized-kubeconfig> get application root -n argocd -o yaml | grep -E 'gitops/argocd/apps|traefik|routes'
kubectl --kubeconfig <materialized-kubeconfig> get namespace argocd
kubectl --kubeconfig <materialized-kubeconfig> get pods -A | egrep 'traefik'
```

Expected:

- `argocd` namespace exists.
- `Application/root` exists in `argocd`.
- The root Application points at `gitops/argocd/apps` and covers only the core bootstrap tree.
- Argo CD controller pods are scheduled and Running on the control-plane node, not stuck Pending on the node taint.
- The `traefik` and `routes` workloads are Running on the control-plane node, not stuck Pending on the node taint.
- `whoami`, `headlamp`, `grafana`, and `wiredoor` are enabled later through separate wizard steps.

For Grafana admin credentials:

```bash
! grep -q 'adminPassword:' gitops/values/grafana.yaml
test -f gitops/argocd/optional/apps/grafana-secret.yaml
test -f gitops/apps/grafana-secret/secretstore.yaml
test -f gitops/apps/grafana-secret/externalsecret.yaml
```

Expected:

- `gitops/values/grafana.yaml` no longer embeds a plaintext `adminPassword`.
- The Grafana admin secret is managed through a Vaultwarden-backed `SecretStore`/`ExternalSecret` pair.
- The Grafana secret Application exists in the optional Argo app manifests.

## 8. Data Integrity

- `manager-data/clusters/*.json` populated.
- `manager-data/jobs/*.json` populated.
- Queue files move from `pending` to `completed`.
