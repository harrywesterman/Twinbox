# AGENTS.md

Twinbox builds a Talos Linux Kubernetes cluster on Proxmox through a Management VM, manager web UI/API/worker, and Argo CD GitOps.

## Rules

- Stay on `main`; do not branch unless asked.
- GitHub `main` is source of truth. 
- The Management VM runs the Web Wizard in a couple of docker containers. They are built from github actions to GHCR. 
- Update the web wizard: Edit the code, check to MAIN in github, **wait for the docker build actions to complete successfully**, pull the new version of the docker images on the management VM. 
- **Before refreshing the Management VM**, confirm the relevant GitHub Actions "Publish Docker Images" workflow succeeded for the pushed commit. Do not run `docker compose pull` until the new images are actually published.
- Als je iets wijzigt dat op de Management VM draait, zet je het eerst in GitHub `main`, wacht je tot de Docker images succesvol zijn gebouwd, en pull je daarna pas de nieuwe images op de Management VM.
- Use `apply_patch`, small scoped edits, `docker compose`, and `python3` on macOS.
- Do not revert unrelated/user changes.
- Do not edit runtime/generated/dependency state as source: `manager-data/`, `node_modules/`, `dist/`, `.venv/`, `.terraform/`, vendored charts.
- Never print or commit secrets.
- **When changing code, always update the corresponding tests** in the same commit. Run `python3 -m pytest -q tests` and `node --test manager-*/test/*.mjs` before pushing to verify.
- **For any new or changed code, always run the relevant lint and format checks before considering the work done.**
- Twinbox Portal runs on the Kubernetes cluster, not on the Management VM. Update it through `gitops/` and let Argo CD sync it.
- Run cluster checks from the Management VM. Use SSH to `twinbox@<management-vm-ip>` Look into .env.vm-preview.local to find the management-vm-ip.

## Map

- `wizard/setup-wizard.sh` - Proxmox bootstrap; creates the Management VM.
- `manager-web/src/` - React wizard on port `3000`.
- `manager-api/src/` - API on port `8080`, catalog, validation, state, job queueing.
- `manager-worker/src/` - queue polling and job execution.
- `scripts/manager/` - Talos/Proxmox/Argo CD/OpenBao/platform logic (including `ensure-netbird-service.sh` for auto-creating NetBird services).
- `categories/*/steps/*/` - wizard step manifests and runners.
- `gitops/` - Argo CD apps, Helm values, Kustomize.
- `portal/` - Twinbox Portal.
- `config/` - pinned defaults, Cilium values, portal content.
- `tests/` - Python integration/contract tests.
- `docs/` - Reference documentation (API, architecture, troubleshooting, etc.).

## Runtime

- Jobs/logs: `manager-data/jobs/`, `manager-data/logs/`.
- Queue: `manager-data/queue/{pending,running,completed}`.
- Cluster state: `manager-data/clusters/`.
- Step state: `manager-data/step-state/`.
- Talos configs and kubeconfigs are runtime artifacts, not canonical repo source.
- On the Management VM, cluster credentials usually live under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/`:
  - `kubeconfig/kubeconfig`
  - `talosconfig/talosconfig`
- On the Management VM, `/opt/twinbox/.env` is root-owned; when refreshing the stack there, run `docker compose` through `sudo` from `/opt/twinbox` instead of trying to read or edit that file as `twinbox`.
- On the Management VM, `/opt/twinbox` is the live deployment workspace, not a git checkout; refresh it with `docker compose pull && docker compose up -d`, not `git pull`.

## Debug

- Use the SSH remote-connection skill for the Management VM.
- Use the browser-use skill for all live browser testing and inspection; do not substitute shell-based or external browser checks.
- Debug host state under `/opt/twinbox`; debug executable code inside the relevant container.
- Do not wait passively for deployments to finish; start inspecting pod logs right away so you can spot stalls and failures early.
- If Argo CD reports `Synced` but the live deployment is still stale, hard-refresh the application from the Management VM and re-check the deployment image before assuming GitHub is wrong.

### SSH Authentication

- Normal SSH to the Management VM and bastion is through Termix using short-lived certificates issued by [opkssh](https://github.com/openpubkey/opkssh) and gated by Authentik + MFA.
- Break-glass credentials (Management VM password, bastion root SSH key) remain on the hosts but are not exposed in Termix after Phase 2/3. See `docs/operations.md`.

### Bastion Node

- The bastion is a Hetzner VPS, root user. IP is dynamic — find it from the Management VM secrets:
  ```bash
  # Find the cluster ID from step state
  cluster_id=$(ls /opt/twinbox/bootstrap/secrets/global/netbird-bastion-*.json 2>/dev/null | head -1 | sed 's/.*netbird-bastion-//;s/\.json//')

  # Or read from the secret file directly
  bastion_ip=$(sudo cat /opt/twinbox/bootstrap/secrets/global/netbird-bastion-${cluster_id}.json | python3 -c "import sys,json; print(json.load(sys.stdin)['NETBIRD_IP'])")
  bastion_key=$(sudo cat /opt/twinbox/bootstrap/secrets/global/netbird-bastion-${cluster_id}.json | python3 -c "import sys,json; print(json.load(sys.stdin)['SSH_PRIVATE_KEY'])")

  # Write key and connect
  echo "$bastion_key" > /tmp/bastion_key && chmod 600 /tmp/bastion_key
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i /tmp/bastion_key "root@${bastion_ip}"
  ```
- To run multi-line scripts on the bastion without shell escaping hell, use Python heredoc:
  ```bash
  ssh -i /tmp/bastion_key "root@${bastion_ip}" 'python3 << "PYEOF"'
  import json, urllib.request
  # ... any Python code here, no escaping needed ...
  PYEOF'
  ```
- Docker commands on bastion: `docker logs <container>`, `docker inspect <container>`, `docker exec <container> <cmd>`

### NetBird Debugging

- Management API at `https://netbird.bierineenweek.nl/api/` with Bearer token from the management container config.
- Proxy services are auto-created per-application by `scripts/manager/ensure-netbird-service.sh` during install steps.
- Key API endpoints: `/api/policies`, `/api/routes`, `/api/groups`, `/api/peers`.
- Management UI: `https://netbird.bierineenweek.nl` (dashboard).
- Management server + embedded relay runs in one container (`netbird-server`), no separate coturn/signal.
- Proxy container (`netbird-proxy`) runs eBPF wgProxy for tunnel backhaul to routing peers in-cluster.
- Proxy service targets a **NetBird resource** (the Traefik ClusterIP), not the upstream service directly.
- Routing peer container (`netbirdio/netbird:0.70.5`) runs in-cluster (namespace `netbird`), image pinned in both `config/pinned-defaults.sh` and `gitops/platform-apps/netbird-routing-peers/deployment.yaml`.
- To force ExternalSecret refresh: add annotation `force-sync: "1"` to the ExternalSecret and delete/recreate the pod.
- Route `10.96.0.0/12` has `groups=[proxy_group]`, `peer_groups=[k8s_routers_group]`.
- The proxy domain is now `<zone>` (e.g. `bierineenweek.nl`), not `proxy.<zone>`. Apps are addressed as `<app>.<zone>`.

## Verify

Run the smallest useful check for touched files:

- **Shell** → `bash -n <file.sh>`
- **Node** → `node --check <file.js|file.mjs>`
- **Lint/format** → `make lint && make format-check`
- **Portal** → `npm run build --prefix portal`
- **Manager web** → `npm run build --prefix manager-web`
- **Worker tests** → `node --test manager-worker/test/*.mjs`
- **Python tests** → `python3 -m pytest -q tests`
- **Compose** → `cp .env.example .env && docker compose config >/dev/null && rm .env`
- **Do not state that a change "works"** unless you have personally verified it in the relevant environment with one of the smallest useful checks above or a direct live inspection. If something is only inferred or not yet checked, say so plainly.

## Ship

- Commit/push/deploy only when the user asks for a complete production change.
- After pushing runtime changes, watch the relevant GitHub Actions workflow.
- Portal changes roll out through a Git commit to `main`, the portal image publish workflow, and Argo CD sync from `gitops/platform-apps/twinbox-portal`.
- Management VM refresh example: `sudo -n sh -lc 'cd /opt/twinbox && docker compose pull && docker compose up -d'`.
