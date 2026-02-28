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

## Runtime Integration

In production, the frontend is served by prebuilt GHCR image and proxies `/api/*` to `manager-api`.

Start full stack from repository root:

```bash
docker compose pull
docker compose up -d
```

Open:

- `http://<management-vm-ip>:3000`
