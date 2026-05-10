# Twinbox Portal

The user-facing application launcher and cluster dashboard for Twinbox.

## Overview

Twinbox Portal runs on the Kubernetes cluster (not the Management VM) and provides:

- **App Launcher** — Grid of installed and available applications with one-click access
- **Intranet Links** — Customizable quick links to internal and external services
- **Cluster Status** — Live view of cluster health, node resources, and step completion
- **Per-User Preferences** — Theme, layout, and personal bookmark storage
- **Admin Panel** — App installation/uninstallation, observability profile management

## Architecture

```
portal/
├── Dockerfile           # Production container image
├── package.json         # React 19 + Express dependencies
├── server.mjs           # Express server with JWT auth (jose)
├── vite.config.js       # Vite build configuration
├── index.html           # HTML entry point
├── public/              # Static assets
├── src/
│   ├── App.jsx              # Main React application
│   ├── main.jsx             # React DOM entry
│   ├── App.css              # Global styles
│   ├── admin-apps-install.js     # Admin app install logic
│   ├── admin-apps-model.js       # Admin app state model
│   ├── admin-observability-model.js # Observability profile model
│   └── user-admin-model.js       # User preference model
└── test/                # Portal tests
```

## Technology Stack

- **Frontend:** React 19, Vite 8, ESM
- **Backend:** Express 5, `jose` for JWT validation
- **Build:** Vite (`vite build`) + Docker multi-stage
- **Runtime:** Node.js container on Kubernetes via `gitops/platform-apps/twinbox-portal/`

## Scripts

```bash
npm run dev      # Development server
npm run build    # Production build
npm run start    # Start Express server
```

## Deployment

The Portal is deployed via Argo CD from `gitops/platform-apps/twinbox-portal/`.
Changes roll out through:

1. Git commit to `main`
2. Portal image publish workflow (`.github/workflows/docker-publish.yml`)
3. Argo CD sync

## Authentication

The Express server validates JWT tokens issued by Authentik via the `jose` library.
Unauthorized requests are redirected to the Authentik login flow.

## Data Storage

- **User preferences:** Kubernetes ConfigMap or PersistentVolume (per-user)
- **App catalog state:** Sourced from `manager-api` `/api/apps/catalog`
- **Cluster status:** Sourced from `manager-api` `/api/catalog` and `/api/proxmox/cluster-resources`
