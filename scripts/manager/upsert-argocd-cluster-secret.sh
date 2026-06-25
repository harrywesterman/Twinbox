#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --public-zone-name NAME [--secret-name NAME] [--pod-cidr CIDR] [--resource-profile small|standard|large]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PUBLIC_ZONE_NAME=""
POD_CIDR=""
SECRET_NAME="in-cluster-local"
SERVER_URL="https://kubernetes.default.svc"
RESOURCE_PROFILE=""
# Argo CD needs a long-lived token here; the default 24h token would expire
# and leave every application in ComparisonError until the secret is refreshed.
TOKEN_DURATION="${ARGOCD_MANAGER_TOKEN_DURATION:-8760h}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-zone-name)
      PUBLIC_ZONE_NAME="$2"
      shift 2
      ;;
    --pod-cidr)
      POD_CIDR="$2"
      shift 2
      ;;
    --resource-profile)
      RESOURCE_PROFILE="$2"
      shift 2
      ;;
    --secret-name)
      SECRET_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
[[ -n "$PUBLIC_ZONE_NAME" ]] || fail "--public-zone-name is required"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

export KUBECONFIG="$KUBECONFIG_FILE"

log "Ensuring Argo CD manager credentials exist"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: argocd
EOF

ca_data="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
[[ -n "$ca_data" ]] || fail "Could not read cluster CA data from kubeconfig"

bearer_token="$(kubectl -n argocd create token argocd-manager --duration="$TOKEN_DURATION")"
[[ -n "$bearer_token" ]] || fail "Could not create token for argocd-manager"

if [[ -z "$POD_CIDR" ]]; then
  POD_CIDR="$(kubectl get nodes -o jsonpath='{.items[*].spec.podCIDRs[0]}' 2>/dev/null || true)"
  if [[ -n "$POD_CIDR" ]]; then
    POD_CIDR="$(tr ' ' ',' <<<"$POD_CIDR")"
  else
    fail "Could not determine pod CIDR from cluster nodes; pass --pod-cidr explicitly"
  fi
fi

existing_secret_json="$(kubectl -n argocd get secret "$SECRET_NAME" -o json 2>/dev/null || true)"
existing_labels="{}"
existing_annotations="{}"
if [[ -n "$existing_secret_json" ]]; then
  existing_labels="$(jq -c '.metadata.labels // {}' <<<"$existing_secret_json")"
  existing_annotations="$(jq -c '.metadata.annotations // {}' <<<"$existing_secret_json")"
fi

if [[ -z "$RESOURCE_PROFILE" && -n "${STEP_CONTEXT_JSON:-}" ]]; then
  RESOURCE_PROFILE="$(jq -r '.cluster.resource_profile // empty' <<<"$STEP_CONTEXT_JSON")"
fi
if [[ -z "$RESOURCE_PROFILE" ]]; then
  RESOURCE_PROFILE="$(
    jq -r '
      .["twinbox.io/resource-profile"]
      // empty
    ' <<<"$existing_labels"
  )"
fi
if [[ -z "$RESOURCE_PROFILE" ]]; then
  RESOURCE_PROFILE="$(
    jq -r '
      .["twinbox.io/resource-profile"]
      // empty
    ' <<<"$existing_annotations"
  )"
fi
case "$RESOURCE_PROFILE" in
  small|standard|large)
    ;;
  "")
    RESOURCE_PROFILE="standard"
    ;;
  *)
    fail "--resource-profile must be small, standard, or large"
    ;;
esac

merged_labels="$(
  jq -cn \
    --argjson existing "$existing_labels" \
    --arg resource_profile "$RESOURCE_PROFILE" \
    '($existing + {
      "argocd.argoproj.io/secret-type": "cluster",
      "twinbox.io/domain-ready": "true",
      "twinbox.io/resource-profile": $resource_profile
    })'
)"
merged_annotations="$(
  jq -cn \
    --argjson existing "$existing_annotations" \
    --arg public_zone_name "$PUBLIC_ZONE_NAME" \
    --arg pod_cidr "$POD_CIDR" \
    --arg resource_profile "$RESOURCE_PROFILE" \
    '($existing + {
      "twinbox.io/public-zone-name": $public_zone_name,
      "twinbox.io/pod-cidr": $pod_cidr,
      "twinbox.io/resource-profile": $resource_profile
    })'
)"

cluster_config="$(jq -nc \
  --arg bearerToken "$bearer_token" \
  --arg caData "$ca_data" \
  '{
    bearerToken: $bearerToken,
    tlsClientConfig: {
      insecure: false,
      caData: $caData
    }
  }')"

log "Upserting Argo CD cluster secret ${SECRET_NAME}"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: argocd
  labels: ${merged_labels}
  annotations: ${merged_annotations}
type: Opaque
stringData:
  name: ${SECRET_NAME}
  server: ${SERVER_URL}
  config: '${cluster_config}'
EOF

log "Argo CD cluster secret ${SECRET_NAME} updated for ${PUBLIC_ZONE_NAME}"
