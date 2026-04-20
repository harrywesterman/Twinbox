# AGENTS.md

Twinbox is a Talos Linux based configuration for a Kubernetes cluster. Treat these documents as the source of truth:

- `README.md`
- `docs/architecture.md`
- `docs/getting-started.md`
- `docs/configuration.md`
- `docs/verification.md`

## Current State

- The repository’s active branch is `main`.
- `manager-data/` is runtime state only.

## Current Flow

1. Run `wizard/setup-wizard.sh` on Proxmox.
2. The wizard creates only the Management VM.
3. The Management VM gets a thin cloud-init bootstrap, Ansible installs Docker CE and the management tools, and the host keeps runtime/bootstrap state under `/opt/twinbox`; the step and manager scripts run from the manager container images, not from a host-side Twinbox checkout.
4. `manager-web` on port `3000` queues work through `manager-api` on port `8080`.
5. `manager-worker` polls the file queue under `manager-data/` and executes bundled step and manager scripts inside the container image.
6. `provision-nodes` starts the Talos journey, sizes the cluster, lands the VMs, and records the cluster state.
7. `install-secret-sync` installs External Secrets Operator and OpenBao after Longhorn.

## Key Components

- `wizard/setup-wizard.sh` - Proxmox bootstrap.
- `manager-web/` - React UI.
- `manager-api/` - catalog, validation, job queueing, and state reads/writes.
- `manager-worker/` - queue polling and script execution.
- `scripts/manager/` - cluster provisioning and management scripts.
- `categories/` - manifest-driven step catalog and step scripts.
- `docker-compose.yml` - Docker configuration for on the management VM, running the web wizard
- Code changes land in GitHub `main`, are built into container images by GitHub Actions, and are pulled onto the Management VM with `docker compose pull && docker compose up -d`.
- The `Twinbox Portal` is deployed by Argo CD from the GitOps manifests. Update it by:
  1. changing the portal code and committing to `main`
  2. letting GitHub Actions build a new portal Docker image
  3. letting the workflow bump the portal image tag in `gitops/platform-apps/twinbox-portal/deployment.yaml`
  4. letting Argo CD sync the manifest change and roll out the new pod
- Do not expect Argo CD to update the portal from a rebuilt `latest` image alone; the portal deployment needs a new version tag in Git to trigger a rollout.

## Editing Rules

- Use the SSH remote-connection skill to connect to the management VM for debugging. Ask the user for the IP address when needed. Connect as `twinbox@<management-vm-ip>`.
- Use the Playwright skill to look at the live web wizard.
- Try python3 first, especially when working on a mac
- Use `docker compose`, not legacy `docker-compose`.
- Keep `manager-data/` as runtime state only.
- The host does not carry a full repo checkout; the executable Twinbox code lives in the manager container images, while `/opt/twinbox` stores runtime and bootstrap state.
- docker-compose.yml on the management vm is in /opt/twinbox
- Use `apply_patch` for manual file edits.
- Prefer small, targeted changes in the relevant component:
  - UI: `manager-web/src/*`
  - API: `manager-api/src/*`
  - Worker: `manager-worker/src/*`
  - Provisioning scripts: `scripts/manager/*`
  - Step manifests/scripts: `categories/*`
  - After you made a change, always commit and push to `main` on github.com. Then watch the GitHub Action that builds the Docker images and wait until it is done. For the management VM stack, connect with the SSH connection skill to `twinbox@<ip-of-the-management-vm>` and do `docker compose pull && docker compose up -d` before retesting. For the portal, wait for the workflow to bump the image tag in GitOps and let Argo CD sync the deployment before retesting.

## Verification

Run the smallest useful checks for the area you changed:

- Shell: `bash -n` on touched scripts
- Node: `node --check` on touched entrypoints
- Compose: `docker compose config`
- Higher-level changes: the tests under `tests/`

## Operational Notes

- The worker writes job logs and step state to `manager-data/`.
