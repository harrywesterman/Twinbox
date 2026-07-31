#!/usr/bin/env bash
set -euo pipefail

# Request an in-cluster reconciliation after an optional Twinbox application
# changes. The CronJob performs the API calls with the Headwind administrator
# secret, so that secret never leaves the cluster or job logs.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl is unavailable; skipping Headwind mobile catalog reconciliation"
  exit 0
fi

if ! kubectl -n headwind-mdm get cronjob/headwind-mdm-catalog-sync >/dev/null 2>&1; then
  log "Headwind MDM catalog reconciler is not installed; skipping mobile catalog reconciliation"
  exit 0
fi

job_name="headwind-mdm-catalog-sync-$(date +%s)"
if kubectl -n headwind-mdm create job "$job_name" --from=cronjob/headwind-mdm-catalog-sync >/dev/null 2>&1; then
  log "Requested Headwind MDM mobile catalog reconciliation (${job_name})"
else
  log "Headwind MDM mobile catalog reconciliation could not be requested; the scheduled reconciliation will retry"
fi
