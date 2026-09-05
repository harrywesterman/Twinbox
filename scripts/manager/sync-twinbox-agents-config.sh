#!/bin/bash
set -euo pipefail

MANAGER_DATA_DIR="${MANAGER_DATA_DIR:-/data}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/opt/twinbox}"
TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-${WORKSPACE_ROOT}/bootstrap}"
NAMESPACE="twinbox-agents"

# shellcheck disable=SC1091
source "${WORKSPACE_ROOT}/scripts/manager/kubernetes-ai-refresh.sh"

PROVIDER_FILE="${MANAGER_DATA_DIR}/agents/provider.json"
SECRETS_FILE="${TWINBOX_BOOTSTRAP_DIR}/secrets/global/twinbox-agents.json"
AI_PROVIDER_FILE="$(mktemp "${TMPDIR:-/tmp}/twinbox-ai-provider-XXXXXX")"
trap 'rm -f "${AI_PROVIDER_FILE}"' EXIT

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

project_shared_ai_endpoint() {
  if [ ! -f "${PROVIDER_FILE}" ]; then
    echo "sync-twinbox-ai-config: provider config not found, skipping shared AI endpoint projection"
    return 0
  fi

  echo "sync-twinbox-ai-config: projecting shared AI endpoint"
  python3 - "${PROVIDER_FILE}" "${SECRETS_FILE}" >"${AI_PROVIDER_FILE}" <<'PY'
import json
import sys

provider_path, secrets_path = sys.argv[1], sys.argv[2]
with open(provider_path, encoding="utf-8") as handle:
    provider = json.load(handle)
with open(secrets_path, encoding="utf-8") as handle:
    secrets = json.load(handle)

base_url = str(provider.get("baseUrl") or "").rstrip("/")
model = str(provider.get("model") or "").strip()
api_key = str(secrets.get("OPENAI_API_KEY") or "").strip()

opencode_config = {
    "$schema": "https://opencode.ai/config.json",
    "model": f"twinbox/{model}",
    "providers": {
        "twinbox": {
            "package": "@opencode-ai/ai/providers/openai-compatible",
            "settings": {
                "baseURL": base_url,
                "apiKey": "{env:OPENAI_API_KEY}",
            },
            "models": {
                model: {
                    "name": model,
                    "modelID": model,
                }
            },
        }
    },
}
json.dump(
    {
        "OPENAI_API_BASE_URL": base_url,
        "OPENAI_BASE_URL": base_url,
        "OPENAI_API_KEY": api_key,
        "DEFAULT_MODELS": model,
        "INFERENCE_TEXT_MODEL": model,
        "INFERENCE_IMAGE_MODEL": model,
        "PAPERLESS_AI_ENABLED": "true",
        "PAPERLESS_AI_LLM_BACKEND": "openai-like",
        "PAPERLESS_AI_LLM_MODEL": model,
        "PAPERLESS_AI_LLM_API_KEY": api_key,
        "PAPERLESS_AI_LLM_ENDPOINT": base_url,
        "PAPERLESS_AI_LLM_ALLOW_INTERNAL_ENDPOINTS": "true",
        "OPENCODE_CONFIG_JSON": json.dumps(opencode_config, separators=(",", ":")),
    },
    sys.stdout,
)
PY

  TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR}" \
  WORKSPACE_ROOT="${WORKSPACE_ROOT}" \
  KUBECONFIG_FILE="${KUBECONFIG_FILE}" \
  bash "${WORKSPACE_ROOT}/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name twinbox-ai \
    --json-file "${AI_PROVIDER_FILE}" \
    --required-keys "OPENAI_API_BASE_URL,OPENAI_BASE_URL,DEFAULT_MODELS,INFERENCE_TEXT_MODEL,INFERENCE_IMAGE_MODEL,PAPERLESS_AI_ENABLED,PAPERLESS_AI_LLM_BACKEND,PAPERLESS_AI_LLM_MODEL,PAPERLESS_AI_LLM_ENDPOINT,OPENCODE_CONFIG_JSON"
}

restart_deployment_if_exists() {
  local namespace="$1"
  local deployment="$2"

  if kubectl -n "${namespace}" get "deployment/${deployment}" >/dev/null 2>&1; then
    kubectl -n "${namespace}" rollout restart deployment/"${deployment}"
    kubectl -n "${namespace}" rollout status deployment/"${deployment}" --timeout=10m
  else
    echo "sync-twinbox-ai-config: deployment not found in ${namespace}: ${deployment}, skipping restart"
  fi
}

restart_deployments_by_selector_if_exists() {
  local namespace="$1"
  local selector="$2"
  local deployments

  deployments="$(kubectl -n "$namespace" get deployment -l "$selector" -o name 2>/dev/null || true)"
  if [[ -z "$deployments" ]]; then
    echo "sync-twinbox-ai-config: no deployments found in ${namespace} for selector ${selector}, skipping restart"
    return 0
  fi

  kubectl -n "$namespace" rollout restart deployment -l "$selector"
  kubectl -n "$namespace" rollout status deployment -l "$selector" --timeout=10m
}

project_shared_ai_endpoint

echo "sync-twinbox-agents-config: requesting ExternalSecret refresh"
refresh_stamp="$(date +%s)"
refresh_externalsecret_if_exists "${NAMESPACE}" "externalsecret/twinbox-agents-runtime" "${refresh_stamp}"
refresh_externalsecret_if_exists "twinbox-portal" "externalsecret/twinbox-agents-portal-runtime" "${refresh_stamp}"
refresh_externalsecret_if_exists "openwebui" "externalsecret/openwebui-ai-provider" "${refresh_stamp}"
refresh_externalsecret_if_exists "karakeep" "externalsecret/karakeep-ai-provider" "${refresh_stamp}"
refresh_externalsecret_if_exists "paperless" "externalsecret/paperless-ai-provider" "${refresh_stamp}"
refresh_externalsecret_if_exists "coder-workspaces" "externalsecret/coder-workspace-ai-provider" "${refresh_stamp}"

echo "sync-twinbox-agents-config: restarting deployment"
restart_deployment_if_exists "twinbox-agents" "twinbox-agents"
restart_deployment_if_exists "openwebui" "openwebui"
restart_deployment_if_exists "karakeep" "karakeep"
restart_deployment_if_exists "paperless" "paperless"
# Do not roll Coder workspaces here. A workspace may be starting while the
# ExternalSecret refreshes; restarting it can briefly create a second pod and
# exceed the namespace quota before the old pod has terminated. New workspaces
# consume the refreshed Secret automatically, and existing ones can be
# restarted explicitly from Coder when needed.

echo "sync-twinbox-agents-config: done"
