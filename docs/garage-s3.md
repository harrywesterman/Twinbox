# Garage S3 Storage

Twinbox deploys an embedded [Garage](https://garagehq.deuxfleurs.fr/) instance as an S3-compatible object store for Velero backups.

## Architecture

Garage runs as a single-node deployment in the `velero` namespace on the Talos cluster. It uses Longhorn for persistent storage and exposes an S3 API internally.

### Components

| Resource | File | Purpose |
|----------|------|---------|
| Deployment | `gitops/platform/garage/garage-deployment.yaml` | Single-replica Garage server |
| PVC | `gitops/platform/garage/garage-pvc.yaml` | 20Gi Longhorn volume for data |
| Service | `gitops/platform/garage/garage-service.yaml` | Exposes S3 (3900), RPC (3901), admin (3903) |
| Argo CD App | `gitops/apps/garage.yaml` | GitOps management of the deployment |

### Credentials

Garage credentials are stored in a `garage-bootstrap` Secret in the `velero` namespace:

- `GARAGE_RPC_SECRET` — inter-node RPC secret
- `GARAGE_ADMIN_TOKEN` — admin API token
- `GARAGE_METRICS_TOKEN` — metrics endpoint token
- `garage.toml` — full Garage configuration

### S3 Endpoint

From within the cluster:

```
http://garage.velero.svc.cluster.local:3900
```

This is the endpoint configured in `velero.json` as the backup storage location.

## Integration with Velero

`install-velero-backup` deploys Velero and either:

1. **Embedded Garage** (default) — creates a bucket in the local Garage instance
2. **External S3** — connects to an external S3-compatible endpoint

The `velero.json` bootstrap secret tracks the mode:

```json
{
  "mode": "embedded-garage",
  "endpoint": "http://garage.velero.svc.cluster.local:3900",
  "bucket": "twinbox-velero",
  "region": "garage",
  "username": "velero",
  "password": "generated-password"
}
```

## Health

The Garage admin API exposes a health endpoint at `/health` on port 3903, used by readiness and liveness probes.

## Limitations

- Single-node only (no replication)
- Data is stored on a single Longhorn volume
- Suitable for single-cluster deployments; multi-cluster setups should consider external S3
