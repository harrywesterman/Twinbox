# SeaweedFS S3 Storage

Twinbox uses SeaweedFS only in two explicitly separated roles:

- The Kubernetes SeaweedFS installation is the application-media store. It exposes `s3.<ZONE_NAME>` for media and `s3-admin.<ZONE_NAME>` for administration.
- When an operator has no external S3 service, the backup-storage wizard can provision a dedicated SeaweedFS VM. That VM is outside the Management VM and provides the same cluster backup-S3 contract as an external provider.

The Management VM Docker Compose stack does not run SeaweedFS.

## Backup S3

`configure-backup-storage` requires either an external HTTPS S3 endpoint or a dedicated local SeaweedFS VM. The cluster-scoped profile assigns separate buckets to databases, Longhorn, Velero, Management VM backups, and PBS. Credentials, VM SSH keys, and private CA material remain under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/` and in OpenBao; wizard state contains only metadata and secret references.

The dedicated VM uses a persistent data disk, a runtime-validated LAN address, TLS from a Twinbox private CA, and a restricted S3 identity. It is registered as a NetBird management peer later in the existing NetBird phase. This mode is a local backup and does not protect against loss of the complete Proxmox environment.

## Application media

The cluster-native installation remains GitOps-managed by `gitops/apps/seaweedfs-object-store.yaml` and `gitops/values/seaweedfs-object-store.yaml`. Application credentials are separate from backup credentials. Mastodon, for example, uses its own bucket and OpenBao secret through the in-cluster endpoint `http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333`.

Do not point backup consumers at the application-media installation, and do not point applications at the backup profile.
