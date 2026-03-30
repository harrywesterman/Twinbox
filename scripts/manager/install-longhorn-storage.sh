#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_storage_class() {
  local storage_class="${LONGHORN_STORAGE_CLASS:-longhorn}"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl get storageclass "$storage_class" >/dev/null 2>&1; then
      log "StorageClass/${storage_class} is available"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "StorageClass/${storage_class} did not become available after ${attempts} attempts"
    fi

    log "Waiting for StorageClass/${storage_class} to appear"
    sleep 5
    attempt=$((attempt + 1))
  done
}

make_storage_class_default() {
  local storage_class="${LONGHORN_STORAGE_CLASS:-longhorn}"
  local default_annotation="storageclass.kubernetes.io/is-default-class"
  local beta_default_annotation="storageclass.beta.kubernetes.io/is-default-class"
  local default_storage_classes
  local default_storage_class
  local storage_class_json

  default_storage_classes="$(
    kubectl get storageclass -o json | jq -r --arg storage_class "$storage_class" '
      .items[]
      | select(.metadata.name != $storage_class)
      | select(
          (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
          or (.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")
        )
      | .metadata.name
    '
  )"

  for default_storage_class in $default_storage_classes; do
    log "Removing default annotation from StorageClass/${default_storage_class}"
    kubectl annotate storageclass "$default_storage_class" \
      "$default_annotation=false" \
      "$beta_default_annotation=false" \
      --overwrite
  done

  log "Marking StorageClass/${storage_class} as the default storage class"
  kubectl annotate storageclass "$storage_class" \
    "$default_annotation=true" \
    "$beta_default_annotation=true" \
    --overwrite

  storage_class_json="$(kubectl get storageclass "$storage_class" -o json)"
  if ! jq -e --arg default_annotation "$default_annotation" --arg beta_default_annotation "$beta_default_annotation" '
    (.metadata.annotations[$default_annotation] == "true")
    or (.metadata.annotations[$beta_default_annotation] == "true")
  ' <<<"$storage_class_json" >/dev/null; then
    fail "StorageClass/${storage_class} was not marked as the default storage class"
  fi

  default_storage_classes="$(
    kubectl get storageclass -o json | jq -r '
      .items[]
      | select(
          (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
          or (.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")
        )
      | .metadata.name
    '
  )"

  if [[ "$default_storage_classes" != "$storage_class" ]]; then
    fail "StorageClass/${storage_class} is not the only default storage class; found: ${default_storage_classes//$'\n'/, }"
  fi
}

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
manifest_path="$WORKSPACE_ROOT/gitops/apps/longhorn.yaml"
cluster_id="${TWINBOX_CLUSTER_ID:-}"
cluster_instance_id="${TWINBOX_CLUSTER_INSTANCE_ID:-}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

export KUBECONFIG="$KUBECONFIG_FILE"

log "Installing Longhorn through Argo CD"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "longhorn"
wait_for_storage_class
make_storage_class_default

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$cluster_instance_id" \
    --arg application "longhorn" \
    --arg manifest_path "$manifest_path" \
    --arg storage_class "$(printf '%s' "${LONGHORN_STORAGE_CLASS:-longhorn}")" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      manifest_path: $manifest_path,
      storage_class: $storage_class,
      install_mode: "argocd"
    }' >"$STEP_RESULT_FILE"
fi
