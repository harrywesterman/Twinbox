#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

phase=""
cluster_id="${TWINBOX_CLUSTER_ID:-}"
data_dir="${MANAGER_DATA_DIR:-/data}"
talosconfig="${TWINBOX_TALOSCONFIG_FILE:-}"
kubeconfig="${TWINBOX_KUBECONFIG_FILE:-${KUBECONFIG_FILE:-}}"
state_file="${TWINBOX_UPGRADE_STATE_FILE:-}"
talos_backup_root="${TWINBOX_TALOS_BACKUP_ROOT:-/opt/twinbox/bootstrap/backups/talos-etcd}"
cluster_file=""

usage() {
  echo "Usage: $0 --phase inspect|talos|kubernetes --cluster-id ID [--data-dir DIR]"
}

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) phase="$2"; shift 2 ;;
    --cluster-id) cluster_id="$2"; shift 2 ;;
    --data-dir) data_dir="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

[[ "$phase" =~ ^(inspect|talos|kubernetes)$ ]] || { usage; exit 1; }
[[ -n "$cluster_id" ]] || fail "cluster ID is required"
cluster_file="$data_dir/clusters/${cluster_id}.json"
state_file="${state_file:-$data_dir/upgrade-state/${cluster_id}.json}"
[[ -f "$cluster_file" ]] || fail "cluster not found: ${cluster_id}"
[[ -f "$talosconfig" ]] || fail "talosconfig not found"
[[ -f "$kubeconfig" ]] || fail "kubeconfig not found"
mkdir -p "$(dirname "$state_file")"
export KUBECONFIG="$kubeconfig"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

for command in curl jq kubectl sha256sum talosctl; do
  require_cmd "$command"
done

now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

ensure_state() {
  if [[ -f "$state_file" ]]; then
    return
  fi
  jq -n --arg cluster_id "$cluster_id" --arg updated_at "$(now)" '{
    cluster_id: $cluster_id,
    phase: "idle",
    status: "idle",
    active_job_id: null,
    last_job_id: null,
    pause_requested: false,
    resumable: false,
    error: null,
    inspected_at: null,
    inventory: null,
    upstream: null,
    paths: {talos: [], kubernetes: []},
    checkpoints: {talos: [], kubernetes: []},
    longhorn_maintenance: {active: false, original_policy: null},
    updated_at: $updated_at
  }' >"$state_file"
}

patch_state() {
  local filter="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg updated_at "$(now)" "($filter) | .updated_at = \$updated_at" "$state_file" >"$tmp"
  mv "$tmp" "$state_file"
}

ensure_state

controlplanes_json="$(jq -c '.controlplane_ips // .discovered_controlplane_ips // []' "$cluster_file")"
workers_json="$(jq -c '.worker_ips // .discovered_worker_ips // []' "$cluster_file")"
all_nodes_json="$(jq -cn --argjson cps "$controlplanes_json" --argjson workers "$workers_json" '$cps + $workers')"
endpoint="$(jq -r '.[0] // empty' <<<"$controlplanes_json")"
[[ -n "$endpoint" ]] || fail "no control-plane endpoint found"
nodes_csv="$(jq -r 'join(",")' <<<"$all_nodes_json")"
controlplanes_csv="$(jq -r 'join(",")' <<<"$controlplanes_json")"
workers_csv="$(jq -r 'join(",")' <<<"$workers_json")"

talos() {
  local binary="${TALOSCTL_BIN:-talosctl}"
  "$binary" "$@" --talosconfig "$talosconfig"
}

semver() {
  grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//'
}

node_talos_version() {
  local node="$1" output version
  output="$(talos version --nodes "$node" --endpoints "$endpoint" 2>&1)"
  version="$(awk '/^Server:/{server=1; next} server && /^[[:space:]]*Tag:/{print $2; exit}' <<<"$output" | sed 's/^v//' || true)"
  [[ -n "$version" ]] || fail "could not read Talos server version for ${node}"
  printf '%s\n' "$version"
}

node_extensions() {
  local node="$1" output
  output="$(talos get extensions --nodes "$node" --endpoints "$endpoint" -o json 2>/dev/null || true)"
  jq -sc '
    [
      .[]
      | .spec.metadata.name // empty
      | select(. != "schematic")
      | if startswith("siderolabs/") then . else "siderolabs/" + . end
    ]
    | unique
  ' <<<"$output"
}

kubernetes_version() {
  kubectl version -o json | jq -r '.serverVersion.gitVersion' | sed 's/^v//'
}

latest_talos_releases() {
  curl -fsSL "https://api.github.com/repos/siderolabs/talos/releases?per_page=100" |
    jq -c '[.[] | select(.draft == false and .prerelease == false) | .tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))]'
}

version_path() {
  local current="$1"
  local latest="$2"
  local releases_json="$3"
  jq -cn --arg current "$current" --arg latest "$latest" --argjson releases "$releases_json" '
    def parts: ltrimstr("v") | split(".") | map(tonumber);
    ($current | parts) as $from
    | ($latest | parts) as $to
    | if ($from[0] != $to[0]) or ($from[1] > $to[1]) then []
      else [
        range($from[1] + 1; $to[1] + 1) as $minor
        | $releases
        | map(select((parts[0] == $to[0]) and (parts[1] == $minor)))
        | sort_by(parts)
        | last
      ] | map(select(. != null))
      | if ($from[1] == $to[1]) and (($current | parts) < ($latest | parts)) then [$latest]
        elif ($from[1] < $to[1]) and ((last // "") != $latest) then . + [$latest]
        else .
        end
      end
  '
}

kubernetes_releases() {
  local current="$1"
  local latest="$2"
  local current_minor latest_minor minor version versions=()
  current_minor="$(cut -d. -f2 <<<"$current")"
  latest_minor="$(cut -d. -f2 <<<"$latest")"
  for ((minor = current_minor + 1; minor <= latest_minor; minor++)); do
    version="$(curl -fsSL "https://dl.k8s.io/release/stable-1.${minor}.txt")"
    versions+=("$version")
  done
  if [[ "$current_minor" -eq "$latest_minor" && "v${current}" != "$latest" ]]; then
    versions+=("$latest")
  fi
  jq -cn '$ARGS.positional' --args "${versions[@]}"
}

check_pause() {
  if [[ "$(jq -r '.pause_requested // false' "$state_file")" == "true" ]]; then
    patch_state '.status = "paused" | .resumable = true'
    log "Pause requested; stopping at a safe checkpoint"
    exit 0
  fi
}

health_check() {
  log "Checking Talos, Kubernetes and Longhorn health"
  talos health --nodes "$endpoint" --control-plane-nodes "$controlplanes_csv" --worker-nodes "$workers_csv" --endpoints "$endpoint"
  kubectl wait --for=condition=Ready nodes --all --timeout=10m
  if kubectl get namespace longhorn-system >/dev/null 2>&1; then
    wait_for_longhorn_health
  fi
}

wait_for_longhorn_health() {
  local degraded deadline
  deadline=$((SECONDS + ${TWINBOX_LONGHORN_HEALTH_TIMEOUT_SECONDS:-900}))
  while true; do
    degraded="$(kubectl -n longhorn-system get volumes.longhorn.io -o json |
      jq '[.items[] | select((.status.robustness // "") != "healthy")] | length')"
    if [[ "$degraded" == "0" ]]; then
      log "Longhorn volumes are healthy"
      return
    fi
    ((SECONDS < deadline)) || fail "Longhorn has ${degraded} non-healthy volume(s) after waiting"
    log "Waiting for Longhorn volumes to become healthy: ${degraded} non-healthy volume(s)"
    sleep "${TWINBOX_LONGHORN_HEALTH_POLL_SECONDS:-10}"
  done
}

inspect() {
  local talos_releases latest_talos latest_kubernetes current_kubernetes inventory talos_path kube_path
  log "Inspecting cluster versions and upstream stable releases"
  inventory="$(
    jq -cn --argjson cps "$controlplanes_json" --argjson workers "$workers_json" '$cps + $workers | .[]' |
      while read -r node; do
        node="${node//\"/}"
        jq -cn --arg node "$node" --arg version "$(node_talos_version "$node")" \
          --argjson extensions "$(node_extensions "$node")" \
          --arg role "$(jq -r --arg node "$node" 'if index($node) then "controlplane" else "worker" end' <<<"$controlplanes_json")" \
          '{node: $node, role: $role, version: ("v" + $version), extensions: $extensions}'
      done | jq -sc '.'
  )"
  current_kubernetes="$(kubernetes_version)"
  talos_releases="$(latest_talos_releases)"
  latest_talos="$(jq -r 'sort_by(ltrimstr("v") | split(".") | map(tonumber)) | last' <<<"$talos_releases")"
  latest_kubernetes="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  talos_path="$(version_path "$(jq -r '.[0].version' <<<"$inventory")" "$latest_talos" "$talos_releases")"
  kube_path="$(kubernetes_releases "$current_kubernetes" "$latest_kubernetes")"
  health_check
  patch_state \
    ".phase = \"idle\"
    | .status = \"ready\"
    | .active_job_id = null
    | .pause_requested = false
    | .resumable = false
    | .error = null
    | .inspected_at = \"$(now)\"
    | .inventory = {nodes: $inventory, kubernetes_version: \"v${current_kubernetes}\"}
    | .upstream = {talos: \"$latest_talos\", kubernetes: \"$latest_kubernetes\", fetched_at: \"$(now)\"}
    | .paths = {talos: $talos_path, kubernetes: $kube_path}"
  log "Inspection completed"
}

expected_extensions="$("$WORKSPACE_ROOT/scripts/get-talos-image-factory.sh" --preset qemu-guest-agent --output extensions)"

verify_extensions() {
  local node="$1" active
  active="$(node_extensions "$node")"
  [[ "$(jq -c 'sort' <<<"$active")" == "$(jq -c 'sort' <<<"$expected_extensions")" ]] ||
    fail "Talos extensions on ${node} do not match the Twinbox Image Factory preset"
}

longhorn_policy() {
  kubectl -n longhorn-system get settings.longhorn.io node-drain-policy -o json |
    jq -r '.value'
}

set_longhorn_policy() {
  local policy="$1"
  kubectl -n longhorn-system patch settings.longhorn.io node-drain-policy \
    --type=merge \
    -p "{\"value\":\"${policy}\"}" >/dev/null
}

enable_longhorn_worker_maintenance() {
  local active current original
  if ! kubectl get namespace longhorn-system >/dev/null 2>&1; then
    return
  fi
  active="$(jq -r '.longhorn_maintenance.active // false' "$state_file")"
  current="$(longhorn_policy)"
  original="$(jq -r '.longhorn_maintenance.original_policy // empty' "$state_file")"
  if [[ "$active" != "true" ]]; then
    original="$current"
  fi
  [[ -n "$original" ]] || fail "could not preserve the Longhorn node drain policy"
  if [[ "$current" != "always-allow" ]]; then
    log "Enabling temporary Longhorn worker maintenance policy: ${current} -> always-allow"
    set_longhorn_policy "always-allow"
  else
    log "Temporary Longhorn worker maintenance policy is already active: always-allow"
  fi
  patch_state ".longhorn_maintenance = {active: true, original_policy: \"$original\"}"
}

restore_longhorn_worker_maintenance() {
  local active original current
  active="$(jq -r '.longhorn_maintenance.active // false' "$state_file")"
  if [[ "$active" != "true" ]]; then
    return
  fi
  original="$(jq -r '.longhorn_maintenance.original_policy // empty' "$state_file")"
  [[ -n "$original" ]] || {
    log "ERROR: cannot restore Longhorn worker maintenance policy: original policy is missing" >&2
    return 1
  }
  current="$(longhorn_policy)"
  if [[ "$current" != "$original" ]]; then
    log "Restoring Longhorn worker maintenance policy: ${current} -> ${original}"
    set_longhorn_policy "$original"
  else
    log "Longhorn worker maintenance policy is already restored: ${original}"
  fi
  patch_state '.longhorn_maintenance = {active: false, original_policy: null}'
}

uncordon_ready_workers() {
  local node kubernetes_node ready unschedulable
  for node in $(jq -r '.[]' <<<"$workers_json"); do
    kubernetes_node="$(kubectl get nodes -o json |
      jq -r --arg node "$node" '
        .items[]
        | select(any(.status.addresses[]?; .type == "InternalIP" and .address == $node))
        | .metadata.name
      ' | head -n1)"
    [[ -n "$kubernetes_node" ]] || fail "could not resolve Kubernetes node name for worker ${node}"
    ready="$(kubectl get node "$kubernetes_node" -o json |
      jq -r '[.status.conditions[]? | select(.type == "Ready") | .status] | first // "False"')"
    unschedulable="$(kubectl get node "$kubernetes_node" -o json | jq -r '.spec.unschedulable // false')"
    if [[ "$ready" == "True" && "$unschedulable" == "true" ]]; then
      log "Uncordoning ready worker left behind by an interrupted drain: ${kubernetes_node} (${node})"
      kubectl uncordon "$kubernetes_node" >/dev/null
    fi
  done
}

cleanup_talos_upgrade() {
  local exit_code=$?
  trap - EXIT
  restore_longhorn_worker_maintenance || true
  uncordon_ready_workers || true
  exit "$exit_code"
}

download_talosctl() {
  local version="$1" target_dir binary checksums expected actual
  target_dir="$(mktemp -d)"
  binary="$target_dir/talosctl"
  curl -fsSL "https://github.com/siderolabs/talos/releases/download/${version}/talosctl-linux-amd64" -o "$binary"
  checksums="$(curl -fsSL "https://github.com/siderolabs/talos/releases/download/${version}/sha256sum.txt")"
  expected="$(grep ' talosctl-linux-amd64$' <<<"$checksums" | awk '{print $1}')"
  [[ -n "$expected" ]] || fail "could not find talosctl checksum for ${version}"
  actual="$(sha256sum "$binary" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "talosctl checksum mismatch for ${version}"
  chmod 0755 "$binary"
  printf '%s\n' "$binary"
}

talos_upgrade() {
  local target node installer helper binary checkpoint snapshot_dir snapshot
  trap cleanup_talos_upgrade EXIT
  uncordon_ready_workers
  health_check
  snapshot_dir="${talos_backup_root}/${cluster_id}"
  mkdir -p "$snapshot_dir"
  snapshot="${snapshot_dir}/etcd-$(date -u '+%Y%m%dT%H%M%SZ').snapshot"
  log "Creating required etcd snapshot at ${snapshot}"
  talos etcd snapshot "$snapshot" --nodes "$endpoint" --endpoints "$endpoint"
  for node in $(jq -r '.[]' <<<"$all_nodes_json"); do verify_extensions "$node"; done

  for target in $(jq -r '.paths.talos[]' "$state_file"); do
    helper="$("$WORKSPACE_ROOT/scripts/get-talos-image-factory.sh" --preset qemu-guest-agent --version "$target" --installer-only --output shell)"
    installer="$(awk -F= '/^TALOS_IMAGE_INSTALLER=/{print $2}' <<<"$helper")"
    [[ -n "$installer" ]] || fail "failed to resolve installer for ${target}"
    binary="$(download_talosctl "$target")"
    for node in $(jq -r '.[]' <<<"$controlplanes_json"); do
      checkpoint="${target}:${node}"
      if jq -e --arg checkpoint "$checkpoint" '.checkpoints.talos | index($checkpoint)' "$state_file" >/dev/null; then
        log "Skipping completed Talos checkpoint ${checkpoint}"
        continue
      fi
      log "Upgrading Talos node ${node} to ${target}"
      TALOSCTL_BIN="$binary" talos upgrade --nodes "$node" --endpoints "$endpoint" --image "$installer" --wait
      health_check
      patch_state ".checkpoints.talos += [\"$checkpoint\"]"
      check_pause
    done
    for node in $(jq -r '.[]' <<<"$workers_json"); do
      checkpoint="${target}:${node}"
      if jq -e --arg checkpoint "$checkpoint" '.checkpoints.talos | index($checkpoint)' "$state_file" >/dev/null; then
        log "Skipping completed Talos checkpoint ${checkpoint}"
        continue
      fi
      enable_longhorn_worker_maintenance
      log "Upgrading Talos worker ${node} to ${target} without draining workloads"
      TALOSCTL_BIN="$binary" talos upgrade --nodes "$node" --endpoints "$endpoint" --image "$installer" --drain=false --wait
      health_check
      patch_state ".checkpoints.talos += [\"$checkpoint\"]"
      check_pause
    done
    restore_longhorn_worker_maintenance
    rm -rf "$(dirname "$binary")"
  done
  patch_state '.phase = "talos" | .status = "talos_completed" | .active_job_id = null | .resumable = false | .pause_requested = false'
  log "Talos upgrade phase completed"
}

kubernetes_upgrade() {
  local target normalized
  health_check
  for target in $(jq -r '.paths.kubernetes[]' "$state_file"); do
    normalized="${target#v}"
    if jq -e --arg target "$target" '.checkpoints.kubernetes | index($target)' "$state_file" >/dev/null; then
      log "Skipping completed Kubernetes checkpoint ${target}"
      continue
    fi
    log "Previewing Kubernetes upgrade to ${target}"
    talos upgrade-k8s --to "$normalized" --dry-run --nodes "$endpoint" --endpoints "$endpoint"
    log "Upgrading Kubernetes to ${target}"
    talos upgrade-k8s --to "$normalized" --nodes "$endpoint" --endpoints "$endpoint"
    health_check
    patch_state ".checkpoints.kubernetes += [\"$target\"]"
    check_pause
  done
  patch_state '.phase = "kubernetes" | .status = "kubernetes_completed" | .active_job_id = null | .resumable = false | .pause_requested = false'
  log "Kubernetes upgrade phase completed"
}

case "$phase" in
  inspect) inspect ;;
  talos) talos_upgrade ;;
  kubernetes) kubernetes_upgrade ;;
esac
