#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

optional_app_names=(
  audiobookshelf
  freshrss
  hedgedoc
  immich
  jitsi
  n8n
  nextcloud
  opencloud
  openwebui
  outline
  paperless
  karakeep
  pixelfed
  searxng
  stirling-pdf
  vaultwarden
  zulip
)

is_optional_app() {
  local application_name="$1"
  local candidate

  for candidate in "${optional_app_names[@]}"; do
    if [[ "$candidate" == "$application_name" ]]; then
      return 0
    fi
  done

  return 1
}

usage() {
  cat <<USAGE
Usage: $0 --manifest PATH --application NAME [--destination-namespace NAMESPACE] [--skip-namespace-baseline] [--no-wait]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

cluster_resource_profile() {
  local cluster_json="${STEP_CONTEXT_JSON:-}"
  local resource_profile worker_count per_worker_cpu per_worker_memory total_cpu total_memory

  if [[ -z "$cluster_json" ]]; then
    printf 'standard\n'
    return 0
  fi

  cluster_json="$(jq -c '.cluster // empty' <<<"$cluster_json")"
  if [[ -z "$cluster_json" || "$cluster_json" == "null" ]]; then
    printf 'standard\n'
    return 0
  fi

  resource_profile="$(jq -r '.resource_profile // empty' <<<"$cluster_json")"
  case "$resource_profile" in
    small|standard|large)
      printf '%s\n' "$resource_profile"
      return 0
      ;;
  esac

  worker_count="$(jq -r '(.worker_count // 0)' <<<"$cluster_json")"
  per_worker_cpu="$(jq -r '(.cpu_cores // 0)' <<<"$cluster_json")"
  per_worker_memory="$(jq -r '(.memory_mb // 0)' <<<"$cluster_json")"
  total_cpu="$(( per_worker_cpu * worker_count ))"
  total_memory="$(( per_worker_memory * worker_count ))"

  if [[ "$total_cpu" -ge 32 && "$total_memory" -ge 98304 ]]; then
    printf 'large\n'
  elif [[ "$total_cpu" -ge 16 && "$total_memory" -ge 49152 ]]; then
    printf 'standard\n'
  else
    printf 'small\n'
  fi
}

namespace_resource_tier() {
  local namespace="$1"

  case "$namespace" in
    argocd|authentik|databases|external-secrets|longhorn-system|openbao|traefik)
      printf 'infrastructure\n'
      ;;
    *)
      printf 'application\n'
      ;;
  esac
}

namespace_resource_baseline() {
  local namespace="$1"
  local profile="$2"
  local tier request_cpu request_memory limit_cpu

  tier="$(namespace_resource_tier "$namespace")"

  if [[ "$tier" == "infrastructure" ]]; then
    case "$profile" in
      small)
        request_cpu="100m"
        request_memory="192Mi"
        limit_cpu="500m"
        ;;
      large)
        request_cpu="250m"
        request_memory="512Mi"
        limit_cpu="2000m"
        ;;
      *)
        request_cpu="150m"
        request_memory="256Mi"
        limit_cpu="1000m"
        ;;
    esac
  else
    case "$profile" in
      small)
        request_cpu="25m"
        request_memory="64Mi"
        limit_cpu="250m"
        ;;
      large)
        request_cpu="100m"
        request_memory="256Mi"
        limit_cpu="1000m"
        ;;
      *)
        request_cpu="50m"
        request_memory="128Mi"
        limit_cpu="500m"
        ;;
    esac
  fi

  log "Applying namespace resource baseline to ${namespace} (${profile}/${tier})"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: twinbox-default-resources
  namespace: ${namespace}
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: ${request_cpu}
        memory: ${request_memory}
      default:
        cpu: ${limit_cpu}
EOF
}

extract_destination_namespace() {
  awk '
    $1 == "destination:" { in_destination = 1; next }
    in_destination && $1 == "namespace:" { print $2; exit }
    in_destination && $1 ~ /^[^[:space:]]/ { in_destination = 0 }
  ' "$MANIFEST_PATH"
}

wait_for_application_ready() {
  local application="$1"
  local status_json=""
  local sync_status=""
  local health_status=""
  local operation_phase=""
  local comparison_error=""
  local attempt=1
  local attempts=180

  has_unhealthy_resources() {
    jq -e '
      any(
        .status.resources[]?;
        (.health.status // "") == "Degraded"
        or (.health.status // "") == "Missing"
        or (.health.status // "") == "Progressing"
      )
    ' >/dev/null 2>&1
  }

  while true; do
    if status_json="$(kubectl -n argocd get application "$application" -o json 2>/dev/null)"; then
      sync_status="$(jq -r '.status.sync.status // "Unknown"' <<<"$status_json")"
      health_status="$(jq -r '.status.health.status // "Unknown"' <<<"$status_json")"
      operation_phase="$(jq -r '.status.operationState.phase // "Unknown"' <<<"$status_json")"
      comparison_error="$(
        jq -r '
          [
            .status.conditions[]?
            | select((.type // "") == "ComparisonError" or (.type // "" | test("Error$")))
            | .message // empty
          ] | join("; ")
        ' <<<"$status_json"
      )"
      log "Waiting for application/${application}: sync=${sync_status}, health=${health_status}, phase=${operation_phase}"

      if [[ -n "$comparison_error" ]]; then
        log "Application/${application} compare/spec error: ${comparison_error}"
      fi

      if [[ "$operation_phase" == "Failed" || "$operation_phase" == "Error" ]]; then
        log "Application/${application} failed: $(jq -r '.status.operationState.message // "no failure message"' <<<"$status_json")"
        return 1
      fi

      if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" && "$operation_phase" != "Running" && "$operation_phase" != "Terminating" ]]; then
        log "Application/${application} is Synced and Healthy"
        return 0
      fi

      if [[ "$sync_status" == "Synced" && "$operation_phase" != "Running" && "$operation_phase" != "Terminating" && "$health_status" == "Degraded" ]]; then
        if ! has_unhealthy_resources <<<"$status_json"; then
          log "Application/${application} is Synced and has no unhealthy resources; accepting aggregate health=${health_status}"
          return 0
        fi
      fi
    else
      log "Waiting for application/${application} to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      return 1
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

MANIFEST_PATH=""
APPLICATION_NAME=""
DESTINATION_NAMESPACE=""
WAIT_FOR_READY=true
SKIP_NAMESPACE_BASELINE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      MANIFEST_PATH="$2"
      shift 2
      ;;
    --application)
      APPLICATION_NAME="$2"
      shift 2
      ;;
    --destination-namespace)
      DESTINATION_NAMESPACE="$2"
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_READY=false
      shift
      ;;
    --skip-namespace-baseline)
      SKIP_NAMESPACE_BASELINE=true
      shift
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
[[ -n "$MANIFEST_PATH" ]] || { usage; fail "manifest required"; }
[[ -n "$APPLICATION_NAME" ]] || { usage; fail "application required"; }
[[ -f "$MANIFEST_PATH" ]] || fail "manifest not found at ${MANIFEST_PATH}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

export KUBECONFIG="$KUBECONFIG_FILE"

if is_optional_app "$APPLICATION_NAME"; then
  optional_manifest="$WORKSPACE_ROOT/gitops/optional-apps/${APPLICATION_NAME}.yaml"
  [[ -f "$optional_manifest" ]] || fail "optional app manifest not found at ${optional_manifest}"
  MANIFEST_PATH="$optional_manifest"
fi

if [[ -z "$DESTINATION_NAMESPACE" ]]; then
  destination_namespace="$(extract_destination_namespace)"
else
  destination_namespace="$DESTINATION_NAMESPACE"
fi
resource_profile="$(cluster_resource_profile)"
if [[ -n "$destination_namespace" && "$SKIP_NAMESPACE_BASELINE" != true ]]; then
  namespace_resource_baseline "$destination_namespace" "$resource_profile"
elif [[ -n "$destination_namespace" ]]; then
  log "Skipping namespace resource baseline for ${destination_namespace}"
fi

repo_url="${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
target_rev="${TWINBOX_GIT_TARGET_REVISION:-main}"

netbird_version="${PINNED_NETBIRD_VERSION:-latest}"
rendered_manifest="$(sed "s|__REPO_URL__|${repo_url}|g; s|__TARGET_REVISION__|${target_rev}|g; s|__NETBIRD_VERSION__|${netbird_version}|g; s|__CODER_CHART_VERSION__|${PINNED_CODER_CHART_VERSION:-latest}|g" "$MANIFEST_PATH")"

log "Applying Argo CD application manifest ${MANIFEST_PATH}"
printf '%s\n' "$rendered_manifest" | kubectl apply --validate=false -f -

if is_optional_app "$APPLICATION_NAME"; then
  bash "$WORKSPACE_ROOT/scripts/manager/set-optional-app-state.sh" \
    --app "$APPLICATION_NAME" \
    --state enabled
fi

kubectl annotate application "$APPLICATION_NAME" -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
if [[ "$WAIT_FOR_READY" == true ]]; then
  wait_for_application_ready "$APPLICATION_NAME"
else
  log "Skipping wait for application/${APPLICATION_NAME} readiness"
fi
