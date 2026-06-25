#!/bin/bash
set -euo pipefail

MANAGER_DATA_DIR="${MANAGER_DATA_DIR:-/data}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/opt/twinbox}"
TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-${WORKSPACE_ROOT}/bootstrap}"
NAMESPACE="twinbox-agents"

PROVIDER_FILE="${MANAGER_DATA_DIR}/agents/provider.json"
SECRETS_FILE="${TWINBOX_BOOTSTRAP_DIR}/secrets/global/twinbox-agents.json"

echo "sync-twinbox-agents-config: reading provider config from ${PROVIDER_FILE}"

if [ ! -f "${PROVIDER_FILE}" ]; then
  echo "sync-twinbox-agents-config: provider config not found; runtime secret will still be synced"
fi

CLUSTERS_DIR="${MANAGER_DATA_DIR}/clusters"
KUBECONFIG=""
CLUSTER_ID="${TWINBOX_CLUSTER_ID:-}"

if [ -n "${CLUSTER_ID}" ]; then
  KUBECONFIG_PATH="${TWINBOX_BOOTSTRAP_DIR}/secrets/cluster/${CLUSTER_ID}/kubeconfig/kubeconfig"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    KUBECONFIG="${KUBECONFIG_PATH}"
    echo "sync-twinbox-agents-config: using kubeconfig for requested cluster ${CLUSTER_ID}"
  else
    echo "sync-twinbox-agents-config: requested cluster kubeconfig not found for ${CLUSTER_ID}" >&2
    exit 1
  fi
fi

# Compatibility fallback for manually queued legacy jobs.
if [ -z "${KUBECONFIG}" ] && [ -d "${CLUSTERS_DIR}" ]; then
  for cluster_file in "${CLUSTERS_DIR}"/*.json; do
    if [ -f "${cluster_file}" ]; then
      CLUSTER_ID=$(python3 -c "import json; print(json.load(open('${cluster_file}'))['id'])" 2>/dev/null || true)
      if [ -n "${CLUSTER_ID}" ]; then
        KUBECONFIG_PATH="${TWINBOX_BOOTSTRAP_DIR}/secrets/cluster/${CLUSTER_ID}/kubeconfig/kubeconfig"
        if [ -f "${KUBECONFIG_PATH}" ]; then
          KUBECONFIG="${KUBECONFIG_PATH}"
          echo "sync-twinbox-agents-config: using fallback kubeconfig for cluster ${CLUSTER_ID}"
          break
        fi
      fi
    fi
  done
fi

if [ -z "${KUBECONFIG}" ]; then
  echo "sync-twinbox-agents-config: no cluster kubeconfig found, skipping"
  exit 0
fi

export KUBECONFIG
export KUBECONFIG_FILE="${KUBECONFIG}"

# Create namespace if not exists
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [ ! -f "${SECRETS_FILE}" ]; then
  echo "sync-twinbox-agents-config: required secrets file not found at ${SECRETS_FILE}" >&2
  exit 1
fi

echo "sync-twinbox-agents-config: syncing runtime secret to OpenBao"
TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR}" \
WORKSPACE_ROOT="${WORKSPACE_ROOT}" \
KUBECONFIG_FILE="${KUBECONFIG_FILE}" \
bash "${WORKSPACE_ROOT}/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name twinbox-agents \
  --json-file "${SECRETS_FILE}" \
  --required-keys TWINBOX_AGENT_INTERNAL_TOKEN

if [ -f "${PROVIDER_FILE}" ]; then
  echo "sync-twinbox-agents-config: applying provider configmap"
  kubectl -n "${NAMESPACE}" create configmap twinbox-agents-provider \
    --from-file=provider.json="${PROVIDER_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
else
  echo "sync-twinbox-agents-config: provider config not found, skipping provider configmap"
fi

echo "sync-twinbox-agents-config: requesting ExternalSecret refresh"
refresh_stamp="$(date +%s)"
kubectl -n "${NAMESPACE}" annotate externalsecret/twinbox-agents-runtime \
  twinbox.io/force-sync="${refresh_stamp}" --overwrite >/dev/null 2>&1 || true
kubectl -n twinbox-portal annotate externalsecret/twinbox-agents-portal-runtime \
  twinbox.io/force-sync="${refresh_stamp}" --overwrite >/dev/null 2>&1 || true

if kubectl -n "${NAMESPACE}" get externalsecret/twinbox-agents-runtime >/dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" wait \
    --for=condition=Ready externalsecret/twinbox-agents-runtime \
    --timeout=10m
fi

if kubectl -n twinbox-portal get externalsecret/twinbox-agents-portal-runtime >/dev/null 2>&1; then
  kubectl -n twinbox-portal wait \
    --for=condition=Ready externalsecret/twinbox-agents-portal-runtime \
    --timeout=10m
fi

echo "sync-twinbox-agents-config: restarting deployment"
if kubectl -n "${NAMESPACE}" rollout restart deployment/twinbox-agents 2>/dev/null; then
  kubectl -n "${NAMESPACE}" rollout status deployment/twinbox-agents --timeout=10m
else
  echo "sync-twinbox-agents-config: deployment not yet created, skipping restart"
fi

echo "sync-twinbox-agents-config: done"
