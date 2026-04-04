# Secrets Library

Shared Node.js (ESM) modules under `lib/secrets/` that handle secret storage, schema normalization, log redaction, and cached resolution for both `manager-api` and `manager-worker`.

## Modules

### `schema.mjs`

Normalizes secret references and builds standard bundles.

| Function | Purpose |
|----------|---------|
| `normalizeSecretBaseRef(ref)` | Normalizes `{ scope, item, cluster_id }` |
| `normalizeSecretRef(ref)` | Adds `field`, `attachment`, `format` normalization |
| `normalizeSecretBundle(bundle)` | Normalizes `{ env, files }` secret bundles |
| `buildSecretFieldRef(item, field, scope)` | Builds a field-level ref |
| `buildSecretAttachmentRef(item, attachment, scope)` | Builds an attachment ref |
| `buildProxmoxApiSecretBundle()` | Standard Proxmox API secret bundle |
| `buildTalosWorkerSecretBundle(cluster)` | Worker bundle with talosconfig and kubeconfig attachments |
| `buildClusterWorkerSecretBundle(cluster)` | Combined worker bundle from cluster metadata |
| `mergeSecretBundles(...bundles)` | Merges multiple bundles |

### `filesystem-store.mjs`

Read/write secrets on the Management VM filesystem under `bootstrap/secrets/`.

| Function | Purpose |
|----------|---------|
| `secretRoot(env)` | Returns the secrets root directory (`TWINBOX_BOOTSTRAP_DIR`) |
| `clusterSecretDir(env, clusterId, item)` | Returns a cluster-scoped secret directory |
| `readItemRecord(env, ref, context)` | Reads a secret item as a JSON object |
| `writeItemRecord(env, ref, context, record)` | Writes a secret item |
| `resolveAttachmentPath(env, ref, context)` | Resolves a file attachment path on disk |
| `writeAttachment(env, ref, context, filename, content)` | Writes a file attachment |
| `listSecretItems(env, scope, clusterId)` | Lists item names in a scope |
| `createSecretItem(env, ref, context, record)` | Creates a new secret item |
| `itemPrefix(env)` | Returns the `TWINBOX_SECRET_ITEM_PREFIX` value |

### `redact.mjs`

Simple string redactor for scrubbing secrets from log output.

| Function | Purpose |
|----------|---------|
| `buildRedactor(values)` | Returns a function that replaces all `values` with `[REDACTED]` |

### `broker.mjs`

Higher-level secret resolution with TTL-based caching.

| Function | Purpose |
|----------|---------|
| `createSecretBroker(env)` | Factory that returns a `SecretBroker` instance |
| `broker.resolveField(ref, context)` | Resolves a text field from a secret |
| `broker.resolveAttachment(ref, context)` | Materializes a file attachment to a temp path |
| `broker.resolveBundle(bundle, context)` | Resolves an entire `{ env, files }` bundle |
| `broker.upsertAttachment(ref, sourcePath, context)` | Writes/updates an attachment |

## Secret Scope Layout

```
bootstrap/secrets/
├── global/
│   ├── proxmox.json
│   ├── traefik-dashboard.json
│   ├── grafana.json
│   ├── wiredoor-gateway.json
│   ├── velero.json
│   └── authentik.json  # seed-only; deleted after sync into OpenBao
└── cluster/
    └── <cluster-id>/
        ├── talos-secrets/secrets.yaml
        ├── talosconfig/talosconfig
        └── kubeconfig/kubeconfig
```

## Field Aliases

The API server resolves field values with aliases for known items:

- **proxmox**: `host`, `port`, `username`/`user`, `password`, `endpoint`
- **grafana**: `admin-user`/`username`, `admin-password`/`password`
- **traefik-dashboard**: `username`, `password`, `users`
- **wiredoor-gateway**: `WIREDOOR_URL`/`url`, `TOKEN`/`token`

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TWINBOX_BOOTSTRAP_DIR` | `/opt/twinbox/bootstrap` | Root of the bootstrap tree |
| `TWINBOX_SECRET_ITEM_PREFIX` | `twinbox` | Prefix for secret item names |
| `TWINBOX_SECRET_TEMP_DIR` | `/tmp/twinbox-secrets` | Temp dir for materialized files |
| `TWINBOX_SECRET_CACHE_TTL_SEC` | `60` | Broker cache TTL in seconds |
