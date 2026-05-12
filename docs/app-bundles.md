# App Bundles

Twinbox groups applications into **bundles** that install multiple related apps in one step. Bundles provide a curated workspace experience for different use cases and organizational contexts.

## Available Bundles

| Bundle | Apps | Target Audience | Origin |
|--------|------|----------------|--------|
| **Twinbox Desktop** | OpenCloud, Outline, HedgeDoc, Zulip, Jitsi, Paperless, Immich, SearXNG, Audiobookshelf, Pixelfed, Stirling PDF | Complete sovereign workspace | Twinbox |
| **Mijn Bureau** | Nextcloud, Outline, Jitsi | Dutch government workspace | Netherlands (BZK) |
| **La Suite** | Outline, Nextcloud, Zulip, Jitsi | French government workspace | France (DINUM) |
| **openDesk** | OpenCloud, Nextcloud, Zulip, Jitsi | German government workspace | Germany (ZenDiS) |

## Bundle Definitions

Bundle definitions live in `categories/apps/bundles/*.yaml`. Each bundle declares:

- `id` — Unique identifier
- `title` — Display name
- `summary` — Short description
- `iconUrl` / `iconAlt` — Visual assets
- `description` — Full markdown description
- `apps` — List of step IDs to install

Example from `categories/apps/bundles/twinbox-desktop.yaml`:

```yaml
id: twinbox-desktop
title: Twinbox Desktop
summary: A sovereign desktop workspace bundle
iconUrl: /assets/step-icons/install-outline.svg
iconAlt: Twinbox Desktop icon
description: >
  Twinbox Desktop provides a complete sovereign workspace...
apps:
  - install-opencloud
  - install-outline
  - install-hedgedoc
  - install-zulip
  - install-jitsi
  - install-paperless
  - install-immich
  - install-searxng
  - install-audiobookshelf
  - install-pixelfed
  - install-stirling-pdf
```

## How Bundles Work

### Installation Flow

1. User selects a bundle in the wizard
2. The bundle step queues each app step in sequence
3. `manager-worker` executes each app step one by one
4. If an app step fails, the bundle step marks it as failed but continues with the next app
5. The portal updates to show newly installed apps

### State Tracking

Bundle installation state is tracked per-app, not per-bundle. Each app step has its own state file:

```
manager-data/step-state/clusters/<cluster-id>/install-opencloud.json
manager-data/step-state/clusters/<cluster-id>/install-outline.json
```

The bundle itself has no state file; it is a convenience wrapper.

## Creating a Custom Bundle

To create a custom bundle:

1. Create a new file `categories/apps/bundles/my-bundle.yaml`
2. Define the bundle metadata and app list
3. Commit and push to `main`
4. Wait for the Docker image build
5. Refresh the manager stack on the Management VM

### Example Custom Bundle

```yaml
id: my-team-bundle
title: My Team Workspace
summary: Curated apps for my team
iconUrl: /assets/step-icons/custom.svg
iconAlt: Custom bundle icon
description: >
  A curated set of applications for my team's daily workflow.

  **What's included**

  **Nextcloud** — File sync and share

  **Vaultwarden** — Team password manager

  **Immich** — Photo backup
apps:
  - install-nextcloud
  - install-vaultwarden
  - install-immich
```

## Bundle vs Individual Apps

| Aspect | Bundle | Individual App |
|--------|--------|---------------|
| Install action | One click | One click per app |
| State tracking | Per-app | Per-app |
| Dependencies | Per-app | Per-app |
| Portal display | Apps appear individually | App appears individually |
| Dashy display | Apps appear individually | App appears individually |
| Update | Re-run bundle or individual apps | Re-run individual app |
| Removal | Uninstall individual apps | Uninstall individual app |

Bundles are purely a UI convenience. They do not create any shared infrastructure or dependencies between apps.

## Government Workspace Bundles

### Mijn Bureau

The Dutch government's sovereign workspace initiative, developed by the Ministry of the Interior (BZK), Gemeente Amsterdam, and VNG-Realisatie. It provides a complete self-hosted digital workplace for public-sector teams.

**Included:** Nextcloud, Outline, Jitsi
**Coming soon:** Bureaublad (portal), Element (Matrix chat), Collabora (office suite), OpenProject, Grist, Meet, Docs, Drive, Ollama, OpenWebUI, ClamAV

### La Suite

The French government's sovereign workspace, created by DINUM (Direction interministérielle du numérique) for the French public sector. Used by over 500,000 agents across 15 ministries.

**Included:** Outline, Nextcloud, Zulip, Jitsi
**Coming soon:** Tchap (Matrix), Visio (video + AI), Docs, Drive, Grist, France Transfert, Messagerie, Projets, Recherche, Assistant IA

### openDesk

Germany's sovereign digital workplace, developed by ZenDiS (Zentrum für Digitale Souveränität der Öffentlichen Verwaltung GmbH). Built on the "Souveräner Arbeitsplatz" initiative of the Bundesministerium des Innern (BMI).

**Included:** OpenCloud, Nextcloud, Zulip, Jitsi
**Coming soon:** Collabora, CryptPad, Element, OX App Suite, OpenProject, XWiki, Notes, Nubus (IAM), Postfix, Dovecot, ClamAV, Coturn

## Verification

```bash
# List all bundles
ssh twinbox@<management-vm-ip> 'ls /opt/twinbox/categories/apps/bundles/'

# Check bundle content
cat categories/apps/bundles/twinbox-desktop.yaml

# Verify apps are installed
kubectl get application -n argocd
```

## Troubleshooting

### Bundle not appearing in UI

```bash
# Verify the bundle YAML is valid
ssh twinbox@<management-vm-ip> 'docker exec twinbox-manager-worker cat /opt/twinbox/categories/apps/bundles/<bundle>.yaml'

# Check the API response
curl -s http://<management-vm-ip>:8080/api/catalog | jq '.categories[] | select(.id == "apps")'
```

### Bundle install fails partway

```bash
# Check which app failed
ls /opt/twinbox/manager-data/step-state/clusters/<cluster-id>/

# Check the failed app's logs
cat /opt/twinbox/manager-data/logs/<job-id>.log
```

### App not appearing after bundle install

```bash
# Verify the app step state
jq '.status' /opt/twinbox/manager-data/step-state/clusters/<cluster-id>/install-<app>.json

# Verify the Argo CD application
kubectl get application -n argocd <app>
```
