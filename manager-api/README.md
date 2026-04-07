# manager-api

Express.js API server that backs the Twinbox web wizard. Handles catalog, validation, job queueing, secret resolution, and state reads/writes.

## Structure

```
manager-api/
├── Dockerfile
├── package.json
└── src/
    ├── server.js        # Express app and route definitions
    └── lib/
        ├── catalog.js       # Step/category catalog builder
        ├── clusters.js      # Cluster construction, normalization, persistence
        ├── common.js        # Shared utilities (dirs, JSON I/O, parsing)
        ├── ip-allocation.js # IP block calculation and suggestion
        └── jobs.js          # Job queueing (writes to manager-data/)
```

## Runtime

- Node 20, ESM (`"type": "module"`)
- Listens on port `8080` (configurable via `MANAGER_API_PORT`)
- Reads/writes runtime state under `MANAGER_DATA_DIR` (default `/data`)
- Bundles the repo catalog under `categories/` so `/api/catalog` can serve the wizard from inside the container
- Dependencies: `express`, `yaml`

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/health` | Health check |
| `GET` | `/api/catalog` | Step catalog with status |
| `GET` | `/api/ip-suggestions` | VMID and IP suggestions |
| `GET` | `/api/secrets/*` | Secret item lookup |
| `GET` | `/api/proxmox/cluster-resources` | Proxmox node/VM summary |
| `POST` | `/api/clusters` | Create cluster and queue apply |
| `POST` | `/api/clusters/:clusterId/bootstrap` | Queue bootstrap |
| `GET` | `/api/clusters/:clusterId` | Cluster state |
| `POST` | `/api/steps/:stepId/execute` | Execute a step |
| `POST` | `/api/steps/:stepId/skip` | Skip a step |
| `POST` | `/api/steps/:stepId/unskip` | Unskip a step |
| `GET` | `/api/jobs/:jobId` | Job status |
| `GET` | `/api/jobs/:jobId/logs` | Job log lines |

## Key Behaviors

- Resolves secrets from the filesystem store under `manager-data/`, with environment variable fallbacks for Proxmox credentials.
- Probes IPs via `ping` and reads Proxmox resources via `pvesh` or the Proxmox HTTP API.
- Validates VMID ranges and IP allocations before queueing jobs.
- Writes job files to `manager-data/queue/pending/` for the worker to pick up.
