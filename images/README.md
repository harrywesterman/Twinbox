# Custom Images

Custom container images built for Twinbox-specific use cases.

## Overview

Some upstream images require patches or custom configuration to work correctly in the Twinbox environment. This directory contains Dockerfiles and patches for building those images.

## Images

### Jitsi with OpenID Connect

**Directory:** `images/jitsi-openid/`

| File | Purpose |
|------|---------|
| `Dockerfile` | Custom Jitsi Meet image build |
| `0001-room-scoped-short-lived-jwt.patch` | Patch adding room-scoped short-lived JWT support for OpenID Connect authentication |

The patch enables Jitsi to authenticate users via an external OpenID Connect provider (Authentik) using short-lived JWT tokens scoped to specific meeting rooms.

## Building

```bash
cd images/jitsi-openid
docker build -t twinbox/jitsi-openid:latest .
```

## Usage

Custom images are referenced in their respective Argo CD Application manifests or platform-app overlays under `gitops/platform-apps/<app>/`.
