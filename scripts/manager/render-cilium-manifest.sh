#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [--output PATH]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_FILE="$2"
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

command -v helm >/dev/null 2>&1 || fail "helm not found"

values_file="$WORKSPACE_ROOT/config/cilium-values.yaml"
[[ -f "$values_file" ]] || fail "Cilium values file not found: ${values_file}"

ensure_cilium_repo() {
  if ! helm repo list 2>/dev/null | awk '$1 == "cilium" { found = 1 } END { exit found ? 0 : 1 }'; then
    helm repo add cilium https://helm.cilium.io >/dev/null
  fi

  helm repo update >/dev/null
}

render_manifest() {
  ensure_cilium_repo

  local helm_args=()
  if [[ -n "${CILIUM_K8S_SERVICE_HOST:-}" ]]; then
    helm_args+=(--set-string "k8sServiceHost=${CILIUM_K8S_SERVICE_HOST}")
  fi
  if [[ -n "${CILIUM_K8S_SERVICE_PORT:-}" ]]; then
    helm_args+=(--set-string "k8sServicePort=${CILIUM_K8S_SERVICE_PORT}")
  fi

  if ((${#helm_args[@]})); then
    helm template cilium cilium/cilium \
      --version "$PINNED_CILIUM_CHART_VERSION" \
      --namespace kube-system \
      --include-crds \
      --values "$values_file" \
      "${helm_args[@]}"
  else
    helm template cilium cilium/cilium \
      --version "$PINNED_CILIUM_CHART_VERSION" \
      --namespace kube-system \
      --include-crds \
      --values "$values_file"
  fi
}

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  log "Rendering Cilium bootstrap manifest to ${OUTPUT_FILE}"
  render_manifest > "$OUTPUT_FILE"
else
  log "Rendering Cilium bootstrap manifest"
  render_manifest
fi
