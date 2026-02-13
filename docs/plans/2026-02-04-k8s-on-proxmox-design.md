# Kubernetes on Proxmox Design Document

## Overview
This system provides a fully automated, self-updating Kubernetes platform on Proxmox, designed to be the de facto standard for homelabs and small businesses. It abstracts hardware complexity through VM isolation, enables zero-touch node management, and enforces best practices with built-in observability, backup, and compliance.

## Architecture
- **Admin VM**: Central control node with SSO, Tailscale access, and CLI. Runs only essential services: API server, UI backend, and agent.
- **Talos VMs**: Immutable K8s worker nodes. Provisioned, scaled, and reset via Proxmox API. All state is ephemeral; node resets are safe and complete.
- **Storage**: Longhorn as the CSI driver, providing distributed block storage with native K8s integration, snapshots, and replication.
- **Network**: Traefik as ingress with Cloudflare Tunnels for secure public access. All services are mesh-secured.
- **Backup**: Dual-layer—Velero for K8s resources, Proxmox Backup Server for full-VM state. Backups are coordinated in sequence.

## Key Workflows
### Node Lifecycle
- Provisioning: Admin VM calls Proxmox API → spins up new Talos VM → auto-joins cluster.
- Reset: UI click triggers confirmation modal → VM deleted → new one recreated from template.
- Maintenance: One-click toggle drains workloads, prevents scheduling, and locks node for maintenance.

### Updates
- System checks for Proxmox updates nightly. Notifies admin with changelog. Waits for explicit approval before applying.
- K8s and Longhorn updates are managed via Helm, with rollback capability on failure.

### Health & Audit
- Node health is scored 0–100 from CPU, memory, disk, network metrics.
- Weekly system audit scans for misconfigurations against CIS benchmarks and suggests fixes.
- All actions (deploys, resets, backups) are logged with user, time, and result.

## UI / UX Principles
- Single, persistent system status banner (green/yellow/red) at top of all pages.
- Node health score visible in cluster view—color-coded, clickable for details.
- Network map renders live topology: services → pods → ingress → policies.
- Every action requires explicit confirmation, except automated backups and health checks.
- No AI agents. No auto-repair. All changes are user-driven, auditable, and reversible.

## Security Model
- Admin VM: SSH key-only + Tailscale VPN. No passwords.
- SSO via Keycloak/Google for role-based access (admin, edit, view).
- All APIs are mTLS-secured. No anonymous access.
- Immutable cores—no runtime modification of Talos VMs.

## Extensibility
- Plugins: Built-in toggle to enable/disable modules (e.g., UI, metrics).
- CLI: Full kubectl compatibility—every UI action has an API equivalent.
- Config-as-code: All system state is declarative, version-controlled in Git.

## Compliance & Auditability
- Every action: Who, when, what, outcome.
- All logs are stored in /var/log/ and retained for 90 days.
- Weekly audit reports export as PDF, JSON, or CSV.

## Future Evolution
- Support for bare-metal deployment: Same toolchain—just skip VM layer.
- Multi-cluster management via central admin.
- API-first: Full OpenAPI spec for 3rd-party integrations.

## TODO for Implementation
- [ ] Write Helm chart to deploy Talos VMs from template
- [ ] Implement Proxmox API client in Go (for node lifecycle)
- [ ] Build UI dashboard with Node Health, Network Map, Deployment History
- [ ] Integrate Longhorn via Helm in K8s cluster
- [ ] Set up Velero + PBX sync workflow
- [ ] Add system status banner and update flow with confirmation modal
- [ ] Write CLI wrapper for all UI actions
- [ ] Add audit logging and retention policy
