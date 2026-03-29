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
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-external-secrets}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-twinbox-system}"
CLUSTER_SECRET_STORE_NAME="${CLUSTER_SECRET_STORE_NAME:-openbao}"
EXTERNAL_SECRET_NAME="${EXTERNAL_SECRET_NAME:-proxmox-bootstrap}"
TARGET_SECRET_NAME="${TARGET_SECRET_NAME:-proxmox-bootstrap}"

detect_openbao_replicas() {
  local control_plane_count
  control_plane_count="$(
    kubectl get nodes -o json | jq -r '
      [.items[]
        | select(
            .metadata.labels["node-role.kubernetes.io/control-plane"] != null
            or .metadata.labels["node-role.kubernetes.io/master"] != null
          )
      ] | length
    '
  )"

  if [[ "$control_plane_count" =~ ^[0-9]+$ ]] && [[ "$control_plane_count" -ge 3 ]]; then
    printf '3\n'
  else
    printf '1\n'
  fi
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

require_cmd kubectl
require_cmd helm
require_cmd jq
require_cmd openssl

export KUBECONFIG="$KUBECONFIG_FILE"
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

openbao_log "Installing External Secrets Operator ${PINNED_EXTERNAL_SECRETS_CHART_VERSION}"
openbao_install_external_secrets

openbao_log "Seeding OpenBao static seal secret"
openbao_seed_release_secret

openbao_log "Installing OpenBao ${PINNED_OPENBAO_CHART_VERSION} on Longhorn"
openbao_install_release

openbao_pod="$(openbao_wait_for_server_pod)"
openbao_initialize_if_needed "$openbao_pod"
openbao_configure_auth_and_policy "$openbao_pod"
openbao_seed_secret_paths "$openbao_pod"
openbao_apply_cluster_secret_store
openbao_apply_bootstrap_external_secret
openbao_wait_for_secret "$TARGET_SECRET_NAME" "$TARGET_NAMESPACE"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$CLUSTER_ID" \
    --arg operator_namespace "$OPERATOR_NAMESPACE" \
    --arg openbao_namespace "$OPENBAO_NAMESPACE" \
    --arg target_namespace "$TARGET_NAMESPACE" \
    --arg cluster_secret_store_name "$CLUSTER_SECRET_STORE_NAME" \
    --arg external_secret_name "$EXTERNAL_SECRET_NAME" \
    --arg target_secret_name "$TARGET_SECRET_NAME" \
    --arg replicas "$OPENBAO_REPLICAS" \
    '{
      cluster_id: $cluster_id,
      operator_namespace: $operator_namespace,
      openbao_namespace: $openbao_namespace,
      target_namespace: $target_namespace,
      cluster_secret_store_name: $cluster_secret_store_name,
      external_secret_name: $external_secret_name,
      target_secret_name: $target_secret_name,
      openbao_replicas: ($replicas | tonumber)
    }' >"$STEP_RESULT_FILE"
fi

log "OpenBao and External Secrets are configured; Secret/${TARGET_SECRET_NAME} exists in ${TARGET_NAMESPACE}"
