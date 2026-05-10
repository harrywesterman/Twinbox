# GitOps Routes

Traefik route templates for the Twinbox cluster.

## Overview

This directory is a placeholder for Traefik `IngressRoute` and `Middleware` templates that can be applied to the cluster for custom routing rules.

## Structure

```
gitops/routes/
└── templates/       # Route template directory (currently empty)
```

## Current Status

The `templates/` directory is currently empty. Route definitions are typically managed in one of the following ways:

1. **Argo CD Applications** — Most apps define their ingress in their respective `gitops/apps/<app>.yaml` or `gitops/platform-apps/<app>/` directories
2. **Platform Overlays** — Shared routes and middleware live in `gitops/platform/traefik/`
3. **App Manifests** — Individual apps may include `IngressRoute` resources in their Kustomize bases

## Future Use

This directory may be used for:

- Shared Traefik middleware templates
- Canonical ingress route patterns
- Cluster-wide routing policies
