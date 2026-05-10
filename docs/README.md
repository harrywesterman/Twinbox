# docs/

Operational documentation for Twinbox.

## Contents

### Architecture & Overview

- [`architecture.md`](./architecture.md) — System architecture with 5 Mermaid diagrams, component overview, and data flows.
- [`app-pattern.md`](./app-pattern.md) — Standardized app deployment pattern (Longhorn, Traefik, CloudNativePG, Authentik).
- [`app-bundles.md`](./app-bundles.md) — App bundle system: Twinbox Desktop, Mijn Bureau, La Suite, openDesk.
- [`portal.md`](./portal.md) — Twinbox Portal architecture, authentication, and customization.

### Getting Started

- [`getting-started.md`](./getting-started.md) — Initial setup and deployment guide.
- [`wizard-guide.md`](./wizard-guide.md) — Proxmox setup wizard usage walkthrough.
- [`vm-dev.md`](./vm-dev.md) — VM development workflow and frontend preview guide.

### Configuration

- [`configuration.md`](./configuration.md) — Bootstrap file layout, secret contracts, and namespace baseline.
- [`env-reference.md`](./env-reference.md) — Complete `.env` variable reference.
- [`ingress-policy.md`](./ingress-policy.md) — Canonical ingress and hostname policy for `prd` vs non-`prd`.
- [`ip-allocation.md`](./ip-allocation.md) — IP and VMID allocation logic.

### Platform Components

- [`talos-integration.md`](./talos-integration.md) — Talos Linux integration and deployment flow.
- [`secrets-library.md`](./secrets-library.md) — Shared secret library (`lib/secrets/`) internals.
- [`scripts-reference.md`](./scripts-reference.md) — `scripts/manager/` script reference.
- [`api-reference.md`](./api-reference.md) — `manager-api` REST endpoint reference.

### Storage & Backup

- [`seaweedfs-s3.md`](./seaweedfs-s3.md) — SeaweedFS S3 storage for Velero, Longhorn, and Management VM backups.

### Networking & Ingress

- [`wiredoor-bastion.md`](./wiredoor-bastion.md) — Wiredoor bastion host provisioning.
- [`cloudflare.md`](./cloudflare.md) — Cloudflare DNS and Tunnel configuration.
- [`netbird.md`](./netbird.md) — NetBird self-hosted VPN: bastion, routing peers, admin access.

### Security

- [`crowdsec.md`](./crowdsec.md) — CrowdSec intrusion detection and Traefik bouncer.

### Observability

- [`ntfy.md`](./ntfy.md) — ntfy push notifications for cluster alerts.

### Utilities

- [`cloudtty.md`](./cloudtty.md) — Browser-based Kubernetes shell.
- [`argocd-image-updater.md`](./argocd-image-updater.md) — Automated image updates through Argo CD.
- [`management-consoles.md`](./management-consoles.md) — Operator web consoles (Proxmox, Longhorn, SeaweedFS).

### Operations

- [`verification.md`](./verification.md) — Cluster verification procedures.
- [`troubleshooting.md`](./troubleshooting.md) — Common issues and fixes.
