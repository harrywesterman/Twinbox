# GitOps

Argo CD manifests, platform overlays, and values for the Twinbox Kubernetes cluster.

## Directory Layout

```
gitops/
├── apps/                  # Argo CD bootstrap apps and parent Application resources
├── databases/             # CloudNativePG cluster templates and bootstrap resources
├── install.sh             # Argo CD bootstrap script
├── platform/              # Cluster and platform overlays
├── platform-apps/         # App-specific manifests applied by manager scripts
├── optional-apps/         # Label-driven ApplicationSets for opt-in apps
└── values/                # Helm values overrides per app
```

## `apps/`

Argo CD `Application` resources that bootstrap the GitOps graph itself.

The most important bootstrap resource is [`gitops/apps/optional-apps-root.yaml`](apps/optional-apps-root.yaml). It points Argo CD at `gitops/optional-apps/`, where the opt-in app `ApplicationSet` manifests live.

[`gitops/apps/databases.yaml`](apps/databases.yaml) owns only the shared `databases` namespace. App-specific CloudNativePG resources stay owned by their app Applications.

The other files in this directory are still cluster bootstrap or platform entrypoints. They are seeded once and then reconciled by Argo CD.

## `optional-apps/`

Label-driven `ApplicationSet` manifests for user-installable apps.

Each optional app is enabled by adding a `twinbox.io/app-<name>: enabled` label to the Argo CD cluster secret. The bootstrap script or installer seeds the manifest once, then Argo CD owns the generated `Application` and continues reconciling it from GitHub `main`.

The current opt-in apps are:

- `audiobookshelf`
- `freshrss`
- `hedgedoc`
- `immich`
- `jitsi`
- `karakeep`
- `n8n`
- `nextcloud`
- `opencloud`
- `openwebui`
- `outline`
- `paperless`
- `pixelfed`
- `searxng`
- `stirling-pdf`
- `vaultwarden`
- `zulip`

Bootstrap-facing `ExternalSecret` resources live under `gitops/platform-apps/<app>/` and pull credentials from OpenBao via the `openbao` ClusterSecretStore.

## `databases/`

- `_template/` - CloudNativePG cluster, poolers, scheduled backup, and ExternalSecret templates.
- `authentik/` - Authentik database resources.
- `immich/` - Immich database resources.
- `longhorn-single-storageclass.yaml` - StorageClass used by single-replica clusters.
- `shared/` - Argo CD source for shared database resources; currently only the `databases` namespace.
- `shared/namespace.yaml` - shared `databases` namespace definition, owned by [`gitops/apps/databases.yaml`](apps/databases.yaml).

## `platform/`

Cluster-scoped and shared platform overlays. Common contents:

- `argocd/` - Argo CD ingress and cluster access resources.
- `authentik/` - Authentik ingress and callback resources.
- `management-consoles/` - Shared console resources and callbacks.
- `traefik/` - Traefik ingress and dashboard resources.
- `velero/` - Backup-related resources.

## `values/`

Helm values files referenced by the Argo CD Applications via `ref: values`. Named after their app (`grafana.yaml`, etc.). See [values/README.md](values/README.md) for the full list.

Special-case apps can keep their values next to a repo-controlled subtree under `gitops/apps/<app>/` so chart output can be patched deterministically before Argo CD applies it.

## `routes/`

Traefik route templates. See [routes/README.md](routes/README.md).

## `platform-apps/`

App-specific Kubernetes manifests. Some are still rendered or applied directly by the manager scripts during bootstrap, but the long-term target is for these resources to be owned by Argo CD Applications in `gitops/apps/`. Common examples include:

- `audiobookshelf/` - Audiobookshelf deployment, service, ingress, and PVC.
- `cloudnativepg-barman-cloud/` - CloudNativePG Barman Cloud backup configuration.
- `dashy/` - Dashy deployment, service, ingress, PVC, and kustomization.
- `freshrss/` - FreshRSS deployment, service, ingress, and database wiring.
- `garage/` - Garage S3-compatible object storage deployment.
- `grafana/` - Grafana ingress and secret wiring.
- `headlamp/` - Headlamp ingress and secret wiring.
- `hedgedoc/` - HedgeDoc deployment, service, ingress, and database wiring.
- `immich/` - Immich namespace, PVC, ingress, and database secret wiring.
- `jitsi/` - Jitsi deployment, service, ingress, and OpenID configuration.
- `karakeep/` - Karakeep deployment, service, ingress, and database wiring.
- `loki/` - Loki ingress and auth middleware.
- `n8n/` - n8n deployment, service, ingress, and database wiring.
- `netbird-routing-peers/` - NetBird routing peer deployment.
- `nextcloud/` - Nextcloud deployment, service, ingress, and database wiring.
- `ntfy/` - ntfy ingress and kustomization.
- `mastodon/` - Mastodon namespace, Redis, ingress, and secret wiring.
- `opencloud/` - OpenCloud deployment, collaboration services, ingress, and bootstrap config.
- `openwebui/` - OpenWebUI deployment, service, ingress, and PVC.
- `outline/` - Outline deployment, service, ingress, and database wiring.
- `paperless/` - Paperless deployment, service, ingress, and database wiring.
- `pgadmin4/` - pgAdmin 4 namespace, deployment, service, PVC, ingress, and secret wiring.
- `pixelfed/` - Pixelfed deployment, service, ingress, and database wiring.
- `prometheus/` - Prometheus ingress and alert rules.
- `searxng/` - SearXNG deployment, service, and ingress.
- `stirling-pdf/` - Stirling PDF deployment, service, and ingress.
- `twinbox-portal/` - Twinbox Portal deployment, service, ingress, config, and per-user preference storage.
- `vaultwarden/` - Vaultwarden deployment, service, ingress, and database wiring.
- `velero-ui/` - Velero UI namespace, ingress, and secret wiring.
- `zulip/` - Zulip deployment, service, ingress, and database wiring.

## `install.sh`

Bootstraps ArgoCD into the cluster:

1. Creates the `argocd` namespace.
2. Installs ArgoCD using the pinned version from `config/pinned-defaults.sh` via server-side apply.
3. Patches workloads for control-plane tolerations, liveness probes, and idempotent init containers.
4. Waits for all ArgoCD deployments and the application controller StatefulSet to become ready.
