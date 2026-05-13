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
- `scripts/manager/` - Talos/Proxmox/Argo CD/OpenBao/platform logic.
- `categories/*/steps/*/` - wizard step manifests and runners.
- `gitops/` - Argo CD apps, Helm values, Kustomize.
- `portal/` - Twinbox Portal.
- `config/` - pinned defaults, Cilium values, portal content.
- `tests/` - Python integration/contract tests.

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

## Debug

- Use the SSH remote-connection skill for the Management VM.
- Use the browser-use skill for all live browser testing and inspection; do not substitute shell-based or external browser checks.
- Debug host state under `/opt/twinbox`; debug executable code inside the relevant container.
- Do not wait passively for deployments to finish; start inspecting pod logs right away so you can spot stalls and failures early.
- If Argo CD reports `Synced` but the live deployment is still stale, hard-refresh the application from the Management VM and re-check the deployment image before assuming GitHub is wrong.

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
