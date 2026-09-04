#!/usr/bin/env bash

twinbox_backup_bucket_name() {
  local cluster_slug="$1" purpose="$2"
  python3 - "$cluster_slug" "$purpose" <<'PY'
import hashlib, re, sys
value = re.sub(r"[^a-z0-9-]+", "-", f"{sys.argv[1].lower()}-{sys.argv[2].lower()}")
value = re.sub(r"-+", "-", value).strip("-")
if len(value) > 63:
    digest = hashlib.sha256(value.encode()).hexdigest()[:8]
    value = f"{value[:54].rstrip('-')}-{digest}"
if len(value) < 3 or not re.fullmatch(r"[a-z0-9][a-z0-9.-]*[a-z0-9]", value):
    raise SystemExit("invalid derived S3 bucket name")
print(value)
PY
}
