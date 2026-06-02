# API Reference

The `manager-api` service runs an Express server on port 8080. All endpoints return JSON.

## Health

### `GET /api/health`

Returns `{ ok: true, time: "..." }`.

## Catalog

### `GET /api/catalog`

Returns the full wizard catalog: categories, steps, inputs, and current state.

Query parameters:

| Param | Type | Description |
|-------|------|-------------|
| `cluster_id` | string | Optional. Scope catalog to an existing cluster. |

Response: `{ categories: [...], errors: [...] }`

Each step includes: `id`, `title`, `type`, `status`, `inputs`, `secrets`, `runner`, presentation metadata.

## Clusters

### `POST /api/clusters`

Creates a new cluster and queues provisioning. Validates VMID and IP allocation before persisting.

Request body: `{ name, vip_ip, start_ip, controlplane_count, worker_count, start_vmid, vm_node_map, ... }`

Response (202): `{ cluster_id, cluster_instance_id, job_id }`

### `GET /api/clusters/:clusterId`

Returns the cluster state JSON.

### `POST /api/clusters/:clusterId/bootstrap`

Re-bootstraps an existing cluster (re-applies Talos configs).

Request body: `{ cluster_instance_id }`

Response (202): `{ cluster_id, cluster_instance_id, job_id }`

## Cluster Updates

Cluster updates are stored under `manager-data/upgrade-state/<cluster-id>.json`. While a Talos or
Kubernetes phase is pending or running, other mutating cluster operations return HTTP `409`.

### `GET /api/clusters/:clusterId/upgrades`

Returns the live inventory, upstream stable versions, calculated paths, checkpoints and maintenance
status.

### `POST /api/clusters/:clusterId/upgrades/refresh`

Queues a fresh inspection of Talos, Kubernetes and Longhorn health and upstream stable releases.

### `POST /api/clusters/:clusterId/upgrades/talos`

Queues the Talos phase after inspection. The worker snapshots etcd and upgrades one node at a time
while preserving the Twinbox Image Factory extensions.

### `POST /api/clusters/:clusterId/upgrades/kubernetes`

Queues the Kubernetes phase after Talos completed successfully.

### `POST /api/clusters/:clusterId/upgrades/pause`

Requests a pause after the active safe checkpoint.

### `POST /api/clusters/:clusterId/upgrades/resume`

Resumes a paused or failed Talos or Kubernetes phase.

## Steps

### `POST /api/steps/:stepId/execute`

Executes a wizard step. Validates inputs against the step manifest, resolves secrets, and queues a job.

Request body: `{ cluster_id, cluster_instance_id, inputs: {...} }`

Response (202): `{ step_id, cluster_id, cluster_instance_id, job_id, job_type }`

Accepts execution for any step at any time, provided inputs are valid.

### `POST /api/steps/:stepId/skip`

Marks a step as skipped. Only allowed for steps in `ready` or `failed` status.

Request body: `{ cluster_id }`

Response: `{ step_id, status: "skipped" }`

### `POST /api/steps/:stepId/unskip`

Reverts a skipped step back to its natural state.

Request body: `{ cluster_id }`

Response: `{ step_id, status: "ready" }`

## Jobs

### `GET /api/jobs/:jobId`

Returns the job state JSON.

### `GET /api/jobs/:jobId/logs`

Returns the job log lines.

Response: `{ lines: [{ line: "..." }, ...] }`

## Secrets

### `GET /api/secrets/*`

Reads a secret item by path. The path encodes scope and item name.

Example: `/api/secrets/global/proxmox` returns the Proxmox secret item.

Response: `{ data: { id, name, type, login, fields, attachments } }`

## IP Suggestions

### `GET /api/ip-suggestions`

Returns IP and VMID allocation suggestions for cluster provisioning.

Query parameters:

| Param | Type | Description |
|-------|------|-------------|
| `management_ip` | string | Management VM IP (fallback: request hostname) |
| `node_count` | number | Number of nodes (default: 3, max: 215) |

Response: `{ start_vmid, vmid_block, start_ip, vip_ip, suggested_ips, gateway_ip, dns_servers, ... }`

## Proxmox Resources

### `GET /api/proxmox/cluster-resources`

Returns a summary of Proxmox node and VM resources: CPU, memory, disk totals, and per-node active VM counts.

## Internal

All data is stored as JSON files under `manager-data/`:

- `clusters/<id>.json`
- `jobs/<id>.json`
- `logs/<id>.log`
- `queue/pending/<id>.json`, `queue/running/<id>.json`, `queue/completed/<id>.json`
- `step-state/global/<stepId>.json`
- `step-state/clusters/<scope>/<stepId>.json`
- `upgrade-state/<cluster-id>.json`
