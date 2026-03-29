#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

cluster_id="$(printf '%s' "${STEP_CONTEXT_JSON:-{}}" | jq -r '.cluster.id // empty')"
chart_version="${LONGHORN_CHART_VERSION:-1.11.1}"
release_name="${LONGHORN_RELEASE_NAME:-longhorn}"
namespace="${LONGHORN_NAMESPACE:-longhorn-system}"

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found" >&2
  exit 1
}
command -v helm >/dev/null 2>&1 || {
  echo "helm not found" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq not found" >&2
  exit 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

ensure_namespace() {
  log "Ensuring ${namespace} namespace exists with privileged Pod Security labels"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply --validate=false -f - >/dev/null
  kubectl label namespace "$namespace" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/audit-version=latest \
    pod-security.kubernetes.io/warn=privileged \
    pod-security.kubernetes.io/warn-version=latest \
    --overwrite >/dev/null
}

wait_for_rollout() {
  local kind="$1"
  local name="$2"
  log "Waiting for ${kind}/${name} in ${namespace}"
  kubectl rollout status "${kind}/${name}" -n "$namespace" --timeout=600s
}

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

log "Installing Longhorn ${chart_version} directly with Helm"
ensure_namespace
helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null
helm upgrade --install "$release_name" longhorn/longhorn \
  --namespace "$namespace" \
  --create-namespace \
  --version "$chart_version" \
  --wait \
  --timeout 10m \
  --set preUpgradeChecker.jobEnabled=false \
  --set-string defaultSetting.taintToleration='node-role.kubernetes.io/control-plane:NoSchedule;node-role.kubernetes.io/master:NoSchedule'

wait_for_rollout deployment longhorn-driver-deployer
wait_for_rollout daemonset longhorn-manager
wait_for_storage_class

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg release_name "$release_name" \
    --arg namespace "$namespace" \
    --arg chart_version "$chart_version" \
    --arg storage_class "$(printf '%s' "${LONGHORN_STORAGE_CLASS:-longhorn}")" \
    '{
      cluster_id: $cluster_id,
      release_name: $release_name,
      namespace: $namespace,
      chart_version: $chart_version,
      storage_class: $storage_class,
      install_mode: "helm"
    }' >"$STEP_RESULT_FILE"
fi
