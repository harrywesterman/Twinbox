# lib

Shared Node.js (ESM) modules used by `manager-api`, `manager-worker`, and step scripts.

## Structure

```
lib/
├── catalog-definitions.mjs  # Load and merge category, step, and bundle manifests
├── cluster-public-zone.mjs  # Resolve public DNS zone for a cluster
├── dashy-config.mjs         # Generate and refresh Dashy configuration
├── portal-config.mjs        # Generate and refresh Twinbox Portal configuration
├── step-manifest.mjs        # Parse and validate step.yaml manifests
├── step-presentation.mjs    # Step icon, URL, and summary resolution for the UI
├── step-scope.mjs           # Determine if a step is cluster-scoped
└── secrets/
    ├── schema.mjs           # Secret ref normalization, bundle building, Proxmox helpers
    ├── filesystem-store.mjs # Read/write secrets on the filesystem under bootstrap/secrets/
    ├── redact.mjs           # String redactor for log output
    └── broker.mjs           # Secret resolution with caching and attachment support
```

## Modules

### catalog-definitions.mjs

Loads and merges catalog definitions from the filesystem:

- `loadCatalogDefinitions({ workspaceRoot, includeApps, includeBundles })` — returns merged category, step, and bundle definitions

### cluster-public-zone.mjs

Resolves the public DNS zone for a given cluster:

- `resolveClusterPublicZone(cluster)` — returns the public zone name (e.g., `*.example.com`)

### dashy-config.mjs

Generates and refreshes Dashy configuration based on installed steps:

- `refreshDashyConfig(...)` — writes Dashy `conf.yml` with active app links

### portal-config.mjs

Generates and refreshes Twinbox Portal configuration:

- `refreshPortalConfig(...)` — writes portal config with app catalog and cluster status

### step-manifest.mjs

Parses and validates `step.yaml` manifests:

- `loadStepManifest(path)` — reads and validates a step manifest

### step-presentation.mjs

Resolves presentation metadata for wizard steps:

- `resolveStepPresentation(step)` — returns `{ icon, project_url, github_url, positive_summary }`
- Built-in map of icons and URLs for all known steps
- Fallback icons by journey stage and step type

### secrets/schema.mjs

Secret reference and bundle schemas:

- `normalizeSecretBaseRef(ref)` — normalizes a `{ scope, item, cluster_id }` reference
- `normalizeSecretRef(ref)` — adds `field` and `format` normalization
- `normalizeSecretBundle(bundle)` — normalizes `{ env, files }` secret bundles
- `buildProxmoxApiSecretBundle()` — builds the standard Proxmox API secret bundle
- `buildClusterWorkerSecretBundle(cluster)` — builds the worker secret bundle from cluster metadata

### secrets/filesystem-store.mjs

Filesystem-based secret storage under `bootstrap/secrets/`:

- `secretRoot(env)` — returns the secrets root directory
- `clusterSecretDir(env, clusterId, item)` — returns a cluster-scoped secret directory
- `readItemRecord(env, ref, context)` — reads a secret item as a JSON object
- `writeItemRecord(env, ref, context, record)` — writes a secret item
- `resolveAttachmentPath(env, ref, context)` — resolves a file attachment path
- `writeAttachment(env, ref, context, filename, content)` — writes a file attachment

### secrets/redact.mjs

Simple string redactor for scrubbing secrets from log output:

- `buildRedactor(values)` — returns a function that replaces all `values` with `[REDACTED]`

### step-scope.mjs

Determines if a step requires a cluster context:

- `isClusterScopedStep(step)` — returns `true` if the step needs an active cluster

### secrets/broker.mjs

Higher-level secret resolution with TTL-based caching:

- Caches secret reads per item name
- Resolves text fields and file attachments
- Manages cleanup of temporary files
