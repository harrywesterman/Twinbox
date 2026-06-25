#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
AGENTS_NAMESPACE="${AGENTS_NAMESPACE:-twinbox-agents}"
PORTAL_NAMESPACE="${PORTAL_NAMESPACE:-twinbox-portal}"
AGENTS_SECRET_FILE="${TWINBOX_BOOTSTRAP_DIR}/secrets/global/twinbox-agents.json"
AGENTS_APP_MANIFEST="${WORKSPACE_ROOT}/gitops/apps/twinbox-agents.yaml"
PORTAL_AGENTS_EXTERNALSECRET="${WORKSPACE_ROOT}/gitops/platform-apps/twinbox-portal/agents-externalsecret.yaml"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id // empty')"
cluster_instance_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

mkdir -p "$(dirname "$AGENTS_SECRET_FILE")"

current_secret_json="$(mktemp "${TMPDIR:-/tmp}/twinbox-agents-current-XXXXXX")"
next_secret_json="$(mktemp "${TMPDIR:-/tmp}/twinbox-agents-next-XXXXXX")"
trap 'rm -f "$current_secret_json" "$next_secret_json"' EXIT

if [[ -s "$AGENTS_SECRET_FILE" ]]; then
  cp "$AGENTS_SECRET_FILE" "$current_secret_json"
else
  printf '{}\n' >"$current_secret_json"
fi

jq -e 'type == "object"' "$current_secret_json" >/dev/null \
  || fail "Existing ${AGENTS_SECRET_FILE} is not a JSON object"

agent_internal_token="$(jq -r '.TWINBOX_AGENT_INTERNAL_TOKEN // empty' "$current_secret_json")"
if [[ -z "$agent_internal_token" ]]; then
  agent_internal_token="$(openssl rand -hex 32)"
  log "Generated Twinbox agents internal token"
else
  log "Reusing existing Twinbox agents internal token"
fi

jq \
  --arg token "$agent_internal_token" \
  '. + {TWINBOX_AGENT_INTERNAL_TOKEN: $token}' \
  "$current_secret_json" >"$next_secret_json"
mv "$next_secret_json" "$AGENTS_SECRET_FILE"
chmod 600 "$AGENTS_SECRET_FILE"

log "Syncing Twinbox agents runtime secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "twinbox-agents" \
  --json-file "$AGENTS_SECRET_FILE" \
  --required-keys "TWINBOX_AGENT_INTERNAL_TOKEN"

log "Applying Twinbox agents Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$AGENTS_APP_MANIFEST" \
  --application "twinbox-agents" \
  --destination-namespace "$AGENTS_NAMESPACE"

log "Ensuring Portal can read the Twinbox agents internal token"
kubectl create namespace "$PORTAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$PORTAL_AGENTS_EXTERNALSECRET" >/dev/null

refresh_stamp="$(date +%s)"
kubectl -n "$AGENTS_NAMESPACE" annotate externalsecret/twinbox-agents-runtime \
  twinbox.io/force-sync="$refresh_stamp" --overwrite >/dev/null 2>&1 || true
kubectl -n "$PORTAL_NAMESPACE" annotate externalsecret/twinbox-agents-portal-runtime \
  twinbox.io/force-sync="$refresh_stamp" --overwrite >/dev/null 2>&1 || true

kubectl -n "$AGENTS_NAMESPACE" wait \
  --for=condition=Ready externalsecret/twinbox-agents-runtime \
  --timeout=10m
kubectl -n "$PORTAL_NAMESPACE" wait \
  --for=condition=Ready externalsecret/twinbox-agents-portal-runtime \
  --timeout=10m

log "Restarting Twinbox agents to pick up the runtime secret"
kubectl -n "$AGENTS_NAMESPACE" rollout restart deployment/twinbox-agents
kubectl -n "$AGENTS_NAMESPACE" rollout status deployment/twinbox-agents --timeout=10m

if kubectl -n "$PORTAL_NAMESPACE" get deployment/twinbox-portal >/dev/null 2>&1; then
  log "Restarting Portal to pick up the Twinbox agents internal token"
  kubectl -n "$PORTAL_NAMESPACE" rollout restart deployment/twinbox-portal
  kubectl -n "$PORTAL_NAMESPACE" rollout status deployment/twinbox-portal --timeout=10m
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "twinbox-agents" \
    --arg namespace "$AGENTS_NAMESPACE" \
    --arg manifest_path "$AGENTS_APP_MANIFEST" \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$cluster_instance_id" \
    '{
      application: $application,
      namespace: $namespace,
      manifest_path: $manifest_path,
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      portal_path: "/admin/agents"
    }' >"$STEP_RESULT_FILE"
fi

log "Twinbox AI beheerteam installation complete. Configure the LLM endpoint in the Portal at /admin/agents."
