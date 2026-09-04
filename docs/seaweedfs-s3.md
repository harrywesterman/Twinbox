# SeaweedFS S3 Storage

Twinbox uses [SeaweedFS](https://github.com/seaweedfs/seaweedfs) for two separate S3-compatible storage roles:

- A Management VM SeaweedFS container remains the default backup target for Velero, Longhorn, CloudNativePG, Talos etcd snapshots, and Management VM restic backups.
- A Kubernetes SeaweedFS deployment is installed as the default app-media object store for applications such as Mastodon.

## Architecture

SeaweedFS runs on the Management VM alongside the Twinbox manager stack.
`scripts/start-manager.sh` keeps the SeaweedFS bootstrap idempotent by ensuring the Velero bucket and IAM config exist after the container comes up.

### Backup Components

| Resource | Location | Purpose |
|----------|----------|---------|
| Docker Compose service | `docker-compose.yml` | Runs SeaweedFS as a single management-VM container |
| Bootstrap secret | `/opt/twinbox/bootstrap/secrets/global/velero.json` | Stores the S3 credentials, bucket, region, and endpoint |
| K8s Service | `gitops/platform/management-consoles/seaweedfs-service.yaml` | Exposes SeaweedFS ports inside the cluster |
| K8s Endpoints | `gitops/platform/management-consoles/seaweedfs-endpoints.yaml` | Points the cluster service at the Management VM IP |
| Traefik IngressRoutes | `gitops/platform/management-consoles/seaweedfs-*.yaml` | Publishes the legacy backup SeaweedFS web UIs through Traefik |

### App-Media Components

| Resource | Location | Purpose |
|----------|----------|---------|
| Argo CD Application | `gitops/apps/seaweedfs-object-store.yaml` | Installs the upstream SeaweedFS Helm chart into Kubernetes |
| Helm values | `gitops/values/seaweedfs-object-store.yaml` | Enables master, volume, filer, S3, and admin components with Longhorn PVCs |
| Setup step | `categories/talos-cluster/steps/install-seaweedfs-object-store/` | Installs SeaweedFS and provisions app buckets/users |
| Traefik IngressRoutes | `gitops/platform/seaweedfs-object-store/ingressroute.yaml` | Publishes `s3.__ZONE_NAME__` app media and `s3-admin.__ZONE_NAME__` admin UI |
| App secret | `twinbox/apps/mastodon/s3` in OpenBao | Stores Mastodon-specific S3 credentials |

## S3 Endpoint

Velero targets the SeaweedFS S3 endpoint on the Management VM directly:

```text
http://<MANAGEMENT_VM_IP>:8333
```

The same credentials, bucket name, and endpoint are stored in `/opt/twinbox/bootstrap/secrets/global/velero.json` and mirrored into the Management VM runtime when the stack starts.

## Web UIs

SeaweedFS exposes two browser-facing interfaces through Traefik:

- `seaweedfs.__ZONE_NAME__` for the filer/standard web UI
- `seaweedfs-admin.__ZONE_NAME__` for the admin UI

The SeaweedFS filer host serves `/cache` without Authentik for Mastodon media, and Traefik prefixes the request with the `mastodon` bucket before it reaches the S3 endpoint on port `8333`. The admin UI stays behind Authentik.

## Velero Integration

`install-velero-backup` configures Velero to use SeaweedFS by default and renders the Helm values from `velero.json`.

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
- Longhorn, CloudNativePG, Velero, Talos etcd snapshots, and Management VM restic backups all use the same SeaweedFS S3 target by default.
- Mastodon media uses the Kubernetes SeaweedFS endpoint `http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333` and public media host `s3.__ZONE_NAME__`.
- Management VM restic backups exclude `/opt/twinbox/seaweedfs/data` to avoid recursively backing up the backup store.
