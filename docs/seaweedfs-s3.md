# SeaweedFS S3 Storage

Twinbox deploys [SeaweedFS](https://github.com/seaweedfs/seaweedfs) in a Docker container on the Management VM and uses it as the default S3-compatible object store for Velero backups.

## Architecture

SeaweedFS runs on the Management VM alongside the Twinbox manager stack.

### Components

| Resource | Location | Purpose |
|----------|----------|---------|
| Docker Compose service | `docker-compose.yml` | Runs SeaweedFS as a single management-VM container |
| Bootstrap secret | `/opt/twinbox/bootstrap/secrets/global/velero.json` | Stores the S3 credentials, bucket, region, and endpoint |
| K8s Service | `gitops/platform/management-consoles/seaweedfs-service.yaml` | Exposes SeaweedFS ports inside the cluster |
| K8s Endpoints | `gitops/platform/management-consoles/seaweedfs-endpoints.yaml` | Points the cluster service at the Management VM IP |
| Traefik IngressRoutes | `gitops/platform/management-consoles/seaweedfs-*.yaml` | Publishes the filer and admin UIs through Traefik |

## S3 Endpoint

Velero targets the SeaweedFS S3 endpoint through the cluster service:

```text
http://seaweedfs.longhorn-system.svc.cluster.local:8333
```

The same credentials and bucket name are stored in `velero.json` and mirrored into the management VM `.env` file for the SeaweedFS container.

## Web UIs

SeaweedFS exposes two browser-facing interfaces through Traefik:

- `seaweedfs.__ZONE_NAME__` for the filer/standard web UI
- `seaweedfs-admin.__ZONE_NAME__` for the admin UI

Both routes use the shared Authentik forward-auth middleware.

## Velero Integration

`install-velero-backup` configures Velero to use SeaweedFS by default.

The `velero.json` bootstrap secret now looks like this:

```json
{
  "mode": "seaweedfs",
  "endpoint": "http://192.168.1.50:8333",
  "bucket": "twinbox-velero",
  "region": "seaweedfs",
  "username": "velero",
  "password": "generated-password"
}
```

## Notes

- SeaweedFS is the only built-in S3 target.
- Garage is no longer installed or referenced.
- Velero always points at SeaweedFS unless the operator changes the generated bootstrap secret manually.
