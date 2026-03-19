# manager-web

React frontend for Twinbox manager runtime.

## Purpose

- Collect provisioning input.
- Start Talos provisioning jobs.
- Trigger bootstrap jobs.
- Display job state and logs.

## Local Development

```bash
npm ci
npm run dev
```

## Preferred Management VM Preview Flow

Normal visual testing for `manager-web` happens on the Management VM before commit/push:

```bash
# from the repository root
cp .env.vm-preview.local.example .env.vm-preview.local
# set TWINBOX_VM_PREVIEW_TARGET and TWINBOX_VM_PREVIEW_REMOTE_DIR
bash scripts/manager-web-preview.sh
```

This uploads only local `manager-web/` to a temporary directory on the VM, builds the `manager-web` image there, and recreates only the `manager-web` container. The remote git checkout is left alone. Full workflow: `docs/vm-dev.md`.

## Runtime Integration

In production, the frontend is served by prebuilt GHCR image and proxies `/api/*` to `manager-api`.

Start full stack from repository root:

```bash
docker compose pull
docker compose up -d
```

Open:

- `http://<management-vm-ip>:3000`
