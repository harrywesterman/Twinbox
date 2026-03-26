#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${KUBECONFIG_FILE:-}" && -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG="$KUBECONFIG_FILE"
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl not found" >&2
  exit 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

control_plane_tolerations='[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]'

patch_argocd_workload_tolerations() {
  local resource
  local patch

  patch=$(cat <<EOF
{"spec":{"template":{"spec":{"tolerations":${control_plane_tolerations}}}}}
EOF
  )

  for resource in $(kubectl -n argocd get deployment -o name 2>/dev/null | sort); do
    log "Patching ${resource} for control-plane tolerations"
    kubectl -n argocd patch "$resource" --type merge -p "$patch"
  done

  if kubectl -n argocd get statefulset/argocd-application-controller >/dev/null 2>&1; then
    log "Patching statefulset/argocd-application-controller for control-plane tolerations"
    kubectl -n argocd patch statefulset/argocd-application-controller --type merge -p "$patch"
  fi
}

wait_for_pod_selector() {
  local selector="$1"
  local attempt=0
  local pod_names
  local pods

  while true; do
    pod_names="$(kubectl -n argocd get pod -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

    if [[ -n "${pod_names//[$'\n\r\t ']/}" ]]; then
      mapfile -t pods <<<"$pod_names"
      log "Waiting for pods with selector ${selector} to become ready: ${pods[*]}"
      kubectl -n argocd wait --for=condition=Ready pod "${pods[@]}" --timeout=600s
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 120 ]]; then
      fail "Timed out waiting for pods with selector ${selector} to be created"
    fi

    log "Waiting for pods with selector ${selector} to be created"
    sleep 5
  done
}

wait_for_argocd_workloads() {
  local selector
  local selectors=(
    "app.kubernetes.io/name=argocd-applicationset-controller"
    "app.kubernetes.io/name=argocd-dex-server"
    "app.kubernetes.io/name=argocd-redis"
    "app.kubernetes.io/name=argocd-repo-server"
    "app.kubernetes.io/name=argocd-server"
    "app.kubernetes.io/name=argocd-application-controller"
  )

  for selector in "${selectors[@]}"; do
    wait_for_pod_selector "$selector"
  done
}

log "Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply --validate=false -f -

log "Installing Argo CD"
kubectl apply --server-side --validate=false -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml

patch_argocd_workload_tolerations

wait_for_argocd_workloads

log "Applying bootstrap root application"
kubectl apply --validate=false -f "$WORKSPACE_ROOT/gitops/argocd/bootstrap/root.yaml"
