# Apps Category

Application catalog and installable app steps for the Twinbox web wizard.

## Overview

The `apps` category (order: 30) contains standalone application steps that users can install on top of the Talos Kubernetes cluster through the Twinbox Portal or web wizard. Each app is deployed as an Argo CD Application with platform-app overlays and database resources where needed.

## Structure

```
categories/apps/
├── category.yaml       # Category metadata (id: apps, title: Apps)
├── bundles/            # App bundle definitions
│   ├── lasuite.yaml
│   ├── mijn-bureau.yaml
│   ├── opendesk.yaml
│   └── twinbox-desktop.yaml
└── steps/              # Individual app install steps
    ├── install-audiobookshelf/
    ├── install-freshrss/
    ├── install-hedgedoc/
    ├── install-immich/
    ├── install-jitsi/
    ├── install-karakeep/
    ├── install-n8n/
    ├── install-nextcloud/
    ├── install-opencloud/
    ├── install-openwebui/
    ├── install-outline/
    ├── install-paperless/
    ├── install-pixelfed/
    ├── install-searxng/
    ├── install-stirling-pdf/
    ├── install-vaultwarden/
    └── install-zulip/
```

## App Steps

Each app step contains a `step.yaml` manifest and a runner script:

| Step | Description |
|------|-------------|
| `install-audiobookshelf` | Audiobook and podcast server |
| `install-freshrss` | Self-hosted RSS feed aggregator |
| `install-hedgedoc` | Collaborative real-time markdown editor |
| `install-immich` | Photo and video backup solution |
| `install-jitsi` | Video conferencing with OpenID Connect |
| `install-karakeep` | Bookmark and web archiving tool |
| `install-n8n` | Workflow automation platform |
| `install-nextcloud` | Self-hosted file sync and collaboration |
| `install-opencloud` | Open source collaboration platform |
| `install-openwebui` | AI chat interface and model management |
| `install-outline` | Team knowledge base and wiki |
| `install-paperless` | Document management and OCR |
| `install-pixelfed` | Decentralized photo sharing (Instagram alternative) |
| `install-searxng` | Privacy-respecting metasearch engine |
| `install-stirling-pdf` | PDF manipulation and editing tools |
| `install-vaultwarden` | Bitwarden-compatible password manager |
| `install-zulip` | Threaded team chat with topics |

## Bundles

Bundles group related apps into curated sets:

| Bundle | Apps Included |
|--------|---------------|
| **Mijn Bureau** | Nextcloud, OnlyOffice, Zulip |
| **openDesk** | OpenCloud, Collabora, SearXNG |
| **La Suite** | Immich, Paperless, HedgeDoc |
| **Twinbox Desktop** | FreshRSS, Karakeep, Vaultwarden |

## Deployment Pattern

1. User selects an app in the Portal or wizard
2. `manager-api` queues a `run_step` job
3. `manager-worker` executes the step runner script
4. The script bootstraps any app-specific secrets and platform resources
5. The shared Argo CD helper applies the opt-in app `ApplicationSet` manifest
6. The helper labels the Argo CD cluster secret with `twinbox.io/app-<app>=enabled`
7. Argo CD creates the live `Application` from `gitops/optional-apps/<app>.yaml`
8. Platform-specific overlays are applied from `gitops/platform-apps/<app>/`
9. Database resources (CloudNativePG) are provisioned from `gitops/databases/<app>/` when needed, while the shared `databases` namespace is owned by `gitops/apps/databases.yaml`

From that point on, GitHub `main` owns the opt-in app definition and Argo CD keeps the generated `Application` up to date.

## Dependencies

Apps may depend on platform steps being complete first:

- **CloudNativePG** — required by apps with PostgreSQL databases
- **Authentik** — required by apps with SSO integration
- **Longhorn** — required by apps with persistent storage
- **Traefik** — required for ingress
