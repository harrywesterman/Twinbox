#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/backup-storage-profile.sh"

cluster_id="${TWINBOX_CLUSTER_ID:-}"
[[ -n "$cluster_id" ]] || fail "TWINBOX_CLUSTER_ID is required"
load_backup_storage_profile databases

kubectl apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backup-storage-credentials
  namespace: databases
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: backup-storage-credentials
    creationPolicy: Owner
    deletionPolicy: Delete
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: twinbox/cluster/${cluster_id}/backup-storage
        property: access_key_id
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: twinbox/cluster/${cluster_id}/backup-storage
        property: secret_access_key
EOF

if [[ -n "$BACKUP_S3_CA_FILE" && -f "$BACKUP_S3_CA_FILE" ]]; then
  kubectl -n databases create secret generic backup-storage-ca \
    --from-file="ca.crt=${BACKUP_S3_CA_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

rendered_dir="$(mktemp -d "${TMPDIR:-/tmp}/twinbox-database-objectstores-XXXXXX")"
trap 'rm -rf "$rendered_dir"' EXIT

for source_file in "$WORKSPACE_ROOT"/gitops/databases/*/objectstore.yaml; do
  database_name="$(basename "$(dirname "$source_file")")"
  [[ "$database_name" != "_template" ]] || continue
  output_file="$rendered_dir/${database_name}.yaml"
  node - "$source_file" "$output_file" "$BACKUP_S3_BUCKET" "$BACKUP_S3_ENDPOINT" "$BACKUP_S3_CA_FILE" <<'NODE'
const fs = require('fs');
const [source, output, bucket, endpoint, caFile] = process.argv.slice(2);
let text = fs.readFileSync(source, 'utf8');
text = text.replace(/destinationPath:\s*\S+/, `destinationPath: s3://${bucket}/${source.split('/').at(-2)}-db/`);
text = text.replace(/endpointURL:\s*\S+/, `endpointURL: ${endpoint}`);
text = text.replaceAll('seaweedfs-backup-credentials', 'backup-storage-credentials');
if (caFile) {
  text = text.replace(
    /(\s+endpointURL:\s*[^\n]+\n)/,
    '$1    endpointCA:\n      name: backup-storage-ca\n      key: ca.crt\n'
  );
}
fs.writeFileSync(output, text);
NODE
  kubectl apply -f "$output_file" >/dev/null
done

log "Applied CloudNativePG ObjectStores using the ${BACKUP_S3_BUCKET} bucket"
