#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: $0 --cluster-id ID [--operator-namespace NAME] [--openbao-namespace NAME] [--target-namespace NAME] [--cluster-secret-store-name NAME] [--external-secret-name NAME] [--target-secret-name NAME]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-external-secrets}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-twinbox-system}"
CLUSTER_SECRET_STORE_NAME="${CLUSTER_SECRET_STORE_NAME:-openbao}"
EXTERNAL_SECRET_NAME="${EXTERNAL_SECRET_NAME:-proxmox-bootstrap}"
TARGET_SECRET_NAME="${TARGET_SECRET_NAME:-proxmox-bootstrap}"
VELERO_SECRET_NAME="${VELERO_SECRET_NAME:-velero}"
VELERO_SECRET_FILE="${VELERO_SECRET_FILE:-/opt/twinbox/bootstrap/secrets/global/velero.json}"

detect_openbao_replicas() {
  printf '1\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --operator-namespace) OPERATOR_NAMESPACE="$2"; shift 2 ;;
    --openbao-namespace) OPENBAO_NAMESPACE="$2"; shift 2 ;;
    --target-namespace) TARGET_NAMESPACE="$2"; shift 2 ;;
    --cluster-secret-store-name) CLUSTER_SECRET_STORE_NAME="$2"; shift 2 ;;
    --external-secret-name) EXTERNAL_SECRET_NAME="$2"; shift 2 ;;
    --target-secret-name) TARGET_SECRET_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "${CLUSTER_ID:-}" ]] || { usage; fail "cluster-id required"; }
[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
CLUSTER_INSTANCE_ID="${TWINBOX_CLUSTER_INSTANCE_ID:-}"

require_cmd kubectl
require_cmd jq
require_cmd openssl

export KUBECONFIG="$KUBECONFIG_FILE"

if [[ -n "${KUBE_API_SERVER:-}" ]]; then
  kube_cluster_name="$(kubectl config view --kubeconfig "$KUBECONFIG_FILE" -o jsonpath='{.clusters[0].name}')"
  [[ -n "$kube_cluster_name" ]] || fail "Unable to read cluster name from kubeconfig"
  log "Rewriting kubeconfig cluster ${kube_cluster_name} to ${KUBE_API_SERVER}"
  kubectl config set-cluster "$kube_cluster_name" --kubeconfig "$KUBECONFIG_FILE" --server "$KUBE_API_SERVER" >/dev/null
fi

export OPENBAO_NAMESPACE
export OPERATOR_NAMESPACE
export TARGET_NAMESPACE
export CLUSTER_SECRET_STORE_NAME
export EXTERNAL_SECRET_NAME
export TARGET_SECRET_NAME

if [[ -z "${OPENBAO_REPLICAS:-}" ]]; then
  export OPENBAO_REPLICAS
  OPENBAO_REPLICAS="$(detect_openbao_replicas)"
  export OPENBAO_REPLICAS
fi

openbao_log "Preparing management bootstrap material"
openbao_seed_management_bootstrap_files

openbao_log "Ensuring namespaces exist"
openbao_ensure_namespace "$OPENBAO_NAMESPACE"
kubectl create namespace "$OPERATOR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace "$TARGET_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

openbao_log "Applying External Secrets Operator application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/external-secrets.yaml" \
  --application "external-secrets"

openbao_log "Waiting for External Secrets webhook"
openbao_wait_for_external_secrets_webhook

openbao_log "Rendering ArgoCD values files"
openbao_render_values_file

openbao_log "Seeding OpenBao static seal secret"
openbao_seed_release_secret

openbao_log "Applying OpenBao application"
openbao_application_manifest="$(mktemp "${TMPDIR:-/tmp}/openbao-application-XXXXXX")"
trap 'rm -f "$openbao_application_manifest"' RETURN
{
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openbao
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://openbao.github.io/openbao-helm
      chart: openbao
      targetRevision: "0.27.2"
      helm:
        values: |
EOF
  sed 's/^/          /' "$OPENBAO_VALUES_FILE"
  cat <<EOF
  destination:
    server: https://kubernetes.default.svc
    namespace: openbao
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
} >"$openbao_application_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$openbao_application_manifest" \
  --application "openbao" \
  --no-wait

openbao_pod="$(openbao_wait_for_server_pod)"
openbao_initialize_if_needed "$openbao_pod"
openbao_repair_kubernetes_auth
openbao_pod="$(openbao_wait_for_server_pod)"
openbao_seed_secret_paths "$openbao_pod"
openbao_apply_bootstrap_external_secret
openbao_force_cluster_secret_store_refresh
openbao_wait_for_cluster_secret_store_ready
openbao_wait_for_external_secret_ready "$TARGET_NAMESPACE" "$EXTERNAL_SECRET_NAME"
openbao_wait_for_secret "$TARGET_SECRET_NAME" "$TARGET_NAMESPACE"

if [[ -f "$VELERO_SECRET_FILE" ]]; then
  openbao_log "Syncing SeaweedFS/Velero credentials to OpenBao"
  openbao_sync_global_secret_file "$VELERO_SECRET_NAME" "$VELERO_SECRET_FILE" \
    "mode" "endpoint" "bucket" "region" "username" "password"
else
  openbao_log "SeaweedFS/Velero secret file not found at ${VELERO_SECRET_FILE}; skipping sync"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$CLUSTER_ID" \
    --arg cluster_instance_id "$CLUSTER_INSTANCE_ID" \
    --arg operator_namespace "$OPERATOR_NAMESPACE" \
    --arg openbao_namespace "$OPENBAO_NAMESPACE" \
    --arg target_namespace "$TARGET_NAMESPACE" \
    --arg cluster_secret_store_name "$CLUSTER_SECRET_STORE_NAME" \
    --arg external_secret_name "$EXTERNAL_SECRET_NAME" \
    --arg target_secret_name "$TARGET_SECRET_NAME" \
    --arg replicas "$OPENBAO_REPLICAS" \
    --arg velero_secret_name "$VELERO_SECRET_NAME" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      operator_namespace: $operator_namespace,
      openbao_namespace: $openbao_namespace,
      target_namespace: $target_namespace,
      cluster_secret_store_name: $cluster_secret_store_name,
      external_secret_name: $external_secret_name,
      target_secret_name: $target_secret_name,
      openbao_replicas: ($replicas | tonumber),
      velero_secret_name: $velero_secret_name
    }' >"$STEP_RESULT_FILE"
fi

log "OpenBao and External Secrets are configured; Secret/${TARGET_SECRET_NAME} exists in ${TARGET_NAMESPACE}"
