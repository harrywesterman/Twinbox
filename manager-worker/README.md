# manager-worker

Node.js worker that polls the job queue under `manager-data/` and executes provisioning scripts.

## Structure

```
manager-worker/
├── Dockerfile
├── package.json
└── src/
    └── worker.js   # Queue poller, job handler, secret resolution
```

## Runtime

- Node 20, ESM (`"type": "module"`)
- Polls `MANAGER_DATA_DIR/queue/pending/` every 2 seconds (configurable via `WORKER_POLL_MS`)
- Reads workspace from `WORKSPACE_ROOT` (default `/opt/twinbox`)
- Dependencies: `yaml`

## Job Types

| Type | Description |
|------|-------------|
| `apply_cluster` | Runs `scripts/manager/apply-cluster.sh` with cluster parameters |
| `create_cluster` | Alias for apply_cluster |
| `bootstrap_cluster` | Alias for apply_cluster |
| `run_step` | Executes a step script from `categories/` |

## Startup Sequence

1. Recovers orphaned running jobs (marks them as failed).
2. Validates installed tool versions against `config/pinned-defaults.sh` (talosctl, tofu, kubectl, helm).
3. Starts polling loop.

## Container Image

The Dockerfile bundles:

- `talosctl`, `tofu` (OpenTofu), `kubectl`, `helm` — installed at build time with pinned versions from `ARG`s.
- `scripts/manager/`, `scripts/get-talos-image-factory.sh` — provisioning scripts.
- `config/pinned-defaults.sh` — version pin definitions.
- `infra/`, `lib/` — OpenTofu modules and shared libraries.

## Secret Handling

Resolves secrets from the filesystem store under `manager-data/`, materializes them as temporary files when needed, and cleans up after job completion. Builds a redactor to strip secrets from log output.
