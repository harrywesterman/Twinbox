# AGENTS.md

Twinbox turns a Proxmox host into a Talos Linux Kubernetes cluster through a Management VM, a web wizard, queued manager jobs, and GitOps-managed cluster services.

## Source Of Truth

- Work on the current `main` branch. Do not create branches unless the user asks.
- GitHub `main` is the source of truth for code, container images, and GitOps manifests.
- The Management VM is runtime-only. It stores state under `/opt/twinbox`, but it does not carry a full repo checkout.
- Do not treat files under `manager-data/` as canonical source. They are runtime state.

## Architecture

1. `wizard/setup-wizard.sh` runs on Proxmox and creates the Management VM.
2. The Management VM runs Docker Compose from `/opt/twinbox/docker-compose.yml`.
3. `manager-web` serves the wizard on port `3000`.
4. `manager-api` serves the API on port `8080`, validates input, reads the catalog, persists state, and queues jobs.
5. `manager-worker` polls `manager-data/queue/` and executes bundled scripts from the container image.
6. `provision-nodes` creates the Talos VMs and writes cluster state.
7. Argo CD deploys platform services and the Twinbox Portal from `gitops/`.

## Important Paths

- `wizard/setup-wizard.sh` - Proxmox bootstrap entrypoint.
- `manager-web/src/` - React web wizard.
- `manager-api/src/` - Express API, validation, catalog, queueing, and state access.
- `manager-worker/src/` - queue polling, job execution, config refresh helpers.
- `scripts/manager/` - Talos, Proxmox, Argo CD, OpenBao, and platform install scripts.
- `categories/` - manifest-driven wizard steps and step runners.
- `gitops/` - Argo CD applications, Helm values, Kustomize manifests.
- `portal/` - Twinbox Portal app.
- `config/` - pinned defaults, Cilium values, portal content.
- `tests/` - Python integration/contract tests.
- `manager-data/` - local/runtime state only; do not edit as source.

## Editing Rules

- Prefer small, targeted changes in the relevant component.
- Use `apply_patch` for manual file edits.
- Do not rewrite unrelated files or revert user changes.
- Use `docker compose`, not `docker-compose`.
- On macOS, prefer `python3`.
- Keep generated, vendored, runtime, and dependency directories untouched unless the task specifically requires them:
  - `manager-data/`
  - `node_modules/`
  - `dist/`
  - `.venv/`
  - `.terraform/`
  - checked-in chart/vendor trees unless intentionally updating them

## Component Guidance

- UI changes usually belong in `manager-web/src/`.
- API changes usually belong in `manager-api/src/`.
- Worker/job execution changes usually belong in `manager-worker/src/`.
- Provisioning behavior usually belongs in `scripts/manager/`.
- Wizard step metadata or step execution usually belongs in `categories/*/steps/*/`.
- Portal changes belong in `portal/` and may also require `gitops/apps/twinbox-portal.yaml` or `gitops/platform-apps/twinbox-portal/`.

## Runtime And Deployment Model

- Manager images are built by GitHub Actions from `main`.
- The Management VM pulls updated images with:

  ```bash
  cd /opt/twinbox
  docker compose pull
  docker compose up -d
  ```

- The executable Twinbox code on the Management VM lives inside the manager container images.
- `/opt/twinbox` on the Management VM stores compose config, bootstrap files, secrets, and runtime state.
- The Twinbox Portal is deployed through Argo CD from GitOps manifests.
- For portal updates, change source, commit to `main`, wait for the image build, then let Argo CD/image updater roll out the new image.

## Remote Debugging

- Use the SSH remote-connection skill for Management VM debugging.
- `TWINBOX_VM_PREVIEW_TARGET` contains the SSH target.
- Connect as `twinbox@<management-vm-ip>` when needed.
- Use the Playwright skill to inspect the live web wizard.
- Debug host/runtime files under `/opt/twinbox`.
- Debug bundled executable files inside the relevant container image when needed.

## Verification

Run the smallest useful checks for the files changed.

- Shell scripts:

  ```bash
  bash -n <changed-script.sh>
  ```

- Node entrypoints/helpers:

  ```bash
  node --check <changed-file.js>
  node --check <changed-file.mjs>
  ```

- Portal build:

  ```bash
  npm run build --prefix portal
  ```

- Manager web build:

  ```bash
  npm run build --prefix manager-web
  ```

- Worker tests:

  ```bash
  node --test manager-worker/test/*.mjs
  ```

- Python test suite:

  ```bash
  python3 -m pytest -q tests
  ```

- Compose validation:

  ```bash
  cp .env.example .env
  docker compose config >/dev/null
  rm .env
  ```

## Commit And Deploy Policy

When the user asks for a complete production change:

1. Commit the change to `main`.
2. Push to GitHub.
3. Watch the relevant GitHub Actions workflow.
4. For the Management VM stack, SSH to the VM and run:

   ```bash
   cd /opt/twinbox
   docker compose pull
   docker compose up -d
   ```

5. Retest the changed behavior.
6. For portal changes, wait for the Docker image build and Argo CD rollout before final verification.

Do not commit, push, or deploy for exploratory analysis unless the user explicitly asks.

## Operational Notes

- Job files and logs live under `manager-data/`.
- Queue state lives under `manager-data/queue/{pending,running,completed}`.
- Cluster state lives under `manager-data/clusters/`.
- Step state lives under `manager-data/step-state/`.
- Talos configs and kubeconfigs are runtime artifacts, not canonical repo source.
- Secrets should never be printed in logs or committed.
