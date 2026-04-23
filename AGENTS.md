# AGENTS.md

Twinbox builds a Talos Linux Kubernetes cluster on Proxmox through a Management VM, manager web UI/API/worker, and Argo CD GitOps.

## Rules

- Stay on `main`; do not branch unless asked.
- GitHub `main` is source of truth. The Management VM is runtime-only under `/opt/twinbox`.
- Manager containers carry executable Twinbox code; the VM host does not keep a full repo checkout.
- Use `apply_patch`, small scoped edits, `docker compose`, and `python3` on macOS.
- Do not revert unrelated/user changes.
- Do not edit runtime/generated/dependency state as source: `manager-data/`, `node_modules/`, `dist/`, `.venv/`, `.terraform/`, vendored charts.
- Never print or commit secrets.
- Twinbox Portal runs on the k8s cluster, and is managed by argocd. 

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

## Debug

- Use the SSH remote-connection skill for the Management VM.
- `TWINBOX_VM_PREVIEW_TARGET` contains the SSH target; connect as `twinbox@<management-vm-ip>` when needed.
- Use the Playwright skill for the live web wizard.
- Debug host state under `/opt/twinbox`; debug executable code inside the relevant container.

## Verify

Run the smallest useful check for touched files:

- Shell: `bash -n <file.sh>`
- Node: `node --check <file.js|file.mjs>`
- Portal: `npm run build --prefix portal`
- Manager web: `npm run build --prefix manager-web`
- Worker tests: `node --test manager-worker/test/*.mjs`
- Python tests: `python3 -m pytest -q tests`
- Compose: `cp .env.example .env && docker compose config >/dev/null && rm .env`

## Ship

- Commit/push/deploy only when the user asks for a complete production change.
- After pushing runtime changes, watch the relevant GitHub Actions workflow.
- Management VM refresh: `cd /opt/twinbox && docker compose pull && docker compose up -d`.
- Portal changes roll out through image build plus Argo CD sync.
