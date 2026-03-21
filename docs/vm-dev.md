# VM Development Workflow

Use this workflow when the Twinbox Management VM is your primary development machine.

## Goal

- Git and code review still happen locally.
- Docker/runtime stay on the Management VM.
- Normal frontend preview happens by syncing only `manager-web/` to the VM and rebuilding `manager-web` there before commit or push.

## Prerequisites

- Management VM is created by `wizard/setup-wizard.sh`.
- You can SSH into the VM:

```bash
ssh <management-vm-user>@<management-vm-ip>
```

- You know the repo path on the VM. Default installs use `/opt/twinbox`. Older VMs may still use `/opt/twinbox-<cluster-slug>`.

## One-Time Bootstrap on the VM

Run this on the Management VM:

```bash
cd /opt/twinbox
bash scripts/bootstrap-vm.sh
```

What it does:

- Ensures required tools exist (`git`, `docker`, `docker compose`).
- Ensures the repo exists at `/opt/twinbox`.
- Updates to latest `main`.
- Ensures `.env` exists.
- Starts the stack with `docker compose up -d --build`.

## Default Frontend Preview Flow

This is the normal way to work on `manager-web` before the change is committed or pushed.

### 1. Configure the local preview target

```bash
cp .env.vm-preview.local.example .env.vm-preview.local
```

Set at least:

- `TWINBOX_VM_PREVIEW_TARGET=<management-vm-user>@<management-vm-ip>`
- `TWINBOX_VM_PREVIEW_REMOTE_DIR=/opt/twinbox`

Optional:

- `TWINBOX_VM_PREVIEW_PASSWORD=...` if the VM still uses password auth locally and you want `sshpass` automation.
- `TWINBOX_VM_PREVIEW_IMAGE_TAG=...` if the VM `.env` uses a non-default `TWINBOX_IMAGE_TAG`.

### 2. Edit locally and run local checks

Typical frontend loop:

```bash
cd manager-web
npm run build
node --test test/*.mjs
```

Run the checks relevant to the files you changed. The preview script does not replace local verification.

### 3. Push a preview build to the Management VM

From the repository root:

```bash
bash scripts/manager-web-preview.sh
```

What this does:

- archives only local `manager-web/`;
- uploads it to `/tmp/twinbox-manager-web-preview` on the Management VM;
- builds `ghcr.io/harrywesterman/twinbox-manager-web:<tag>` on the VM from that temporary tree;
- recreates only the `manager-web` container with `docker compose up -d --no-deps --force-recreate manager-web`;
- removes the temporary upload directory again.

Important:

- The remote git checkout is not modified.
- You do not need to push to GitHub first.
- This is the preferred way to visually test `manager-web` changes on a real Management VM.

### 4. Inspect the live UI

Open directly:

- `http://<management-vm-ip>:3000`

Or use a tunnel:

```bash
ssh -L 3000:localhost:3000 -L 8080:localhost:8080 <management-vm-user>@<management-vm-ip>
```

Then open:

- `http://localhost:3000`
- `http://localhost:8080/api/health`

Use normal local browser DevTools for frontend inspection.

## Move the VM Back to Repo State After Push

Once the change is merged or pushed and you want the VM to run from the repo checkout again:

```bash
ssh <management-vm-user>@<management-vm-ip>
cd /opt/twinbox
git pull --ff-only origin main

image_tag="$(awk -F= '/^TWINBOX_IMAGE_TAG=/{print $2}' .env | tail -n1)"
image_tag="${image_tag:-latest}"

docker build -t "ghcr.io/harrywesterman/twinbox-manager-web:${image_tag}" manager-web
docker compose up -d --no-deps --force-recreate manager-web
```

That makes the running `manager-web` container come from the repo-backed code on the VM instead of the temporary preview upload.

## Optional Full Remote Editing Flow

If you really want to edit on the VM itself, you still can.

On the VM:

```bash
cd /opt/twinbox
git checkout main
git pull --ff-only
git checkout -b codex/<feature-name>
docker compose up -d
```

After changes:

```bash
docker compose logs -f manager-api manager-web
# run tests for changed parts
git add .
git commit -m "feat: <summary>"
```

## Recommended Editor Setup

- Prefer local editing plus `scripts/manager-web-preview.sh` for frontend work.
- Use an editor with Remote SSH support only when you need to inspect or debug files directly on the VM.
- Keep Docker/runtime on the VM; keep browser/DevTools local.

## Troubleshooting

If Docker access fails:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

If services fail to start:

```bash
cd /opt/twinbox
docker compose ps
docker compose logs --tail=200 manager-api manager-web manager-worker
```

If the preview script must use password auth:

- install `sshpass` locally;
- set `TWINBOX_VM_PREVIEW_PASSWORD` in `.env.vm-preview.local`;
- rerun `bash scripts/manager-web-preview.sh`.

If the preview build is using the wrong tag:

- check `TWINBOX_IMAGE_TAG` in the VM `.env`;
- set the same value in `TWINBOX_VM_PREVIEW_IMAGE_TAG`;
- rerun the preview script.
