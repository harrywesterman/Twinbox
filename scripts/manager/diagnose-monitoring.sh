#!/usr/bin/env bash
set -euo pipefail

# Monitoring Stack Diagnostic Tool
# Troubleshoots missing data in Grafana dashboards by checking:
# 1. Data source connectivity (Prometheus + Loki + Tempo)
# 2. Prometheus scraping targets
# 3. Alloy collection pipeline
# 4. Loki log ingestion
# 5. Grafana dashboard configuration
# 6. Infrastructure health (storage, resources, network)

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh" 2>/dev/null || true

KUBECONFIG="${TWINBOX_KUBECONFIG:-}"
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'
BOLD='\033[1m'

pass() { echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET} $*"; }
fail() { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
section() { echo -e "\n${BOLD}${COLOR_BLUE}=== $1 ===${COLOR_RESET}"; }

check_kubeconfig() {
  if [[ -z "$KUBECONFIG" ]]; then
    # Try to find kubeconfig from common locations
    for candidate in \
      "$WORKSPACE_ROOT/bootstrap/kubeconfig" \
      "$WORKSPACE_ROOT/kubeconfig" \
      "$HOME/.kube/config" \
      "/opt/twinbox/bootstrap/kubeconfig"; do
      if [[ -f "$candidate" ]]; then
        KUBECONFIG="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$KUBECONFIG" ]]; then
    fail "KUBECONFIG not set and not found in common locations"
    info "Set TWINBOX_KUBECONFIG=<path> or place kubeconfig at bootstrap/kubeconfig"
    return 1
  fi

  if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info &>/dev/null; then
    fail "Cannot connect to cluster with KUBECONFIG=$KUBECONFIG"
    return 1
  fi
  pass "Cluster connection verified (KUBECONFIG=$KUBECONFIG)"
  export KUBECONFIG
}

get_pod() {
  local selector="$1"
  local namespace="${2:-monitoring}"
  kubectl --kubeconfig="$KUBECONFIG" get pod -n "$namespace" -l "$selector" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

get_pod_namespace() {
  local label_selector="$1"
  kubectl --kubeconfig="$KUBECONFIG" get pod -n monitoring -l "$label_selector" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# ============================================================================
# LAYER 1: Data Source Connectivity
# ============================================================================
check_data_sources() {
  section "Layer 1: Data Source Connectivity"

  local grafana_pod
  grafana_pod=$(get_pod_namespace "app.kubernetes.io/name=grafana")

  if [[ -z "$grafana_pod" ]]; then
    fail "Grafana pod not found in monitoring namespace"
    info "Check: kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana"
    return 1
  fi

  pass "Grafana pod found: $grafana_pod"

  # Test Prometheus datasource
  info "Testing Prometheus datasource connection from Grafana..."
  local prom_health
  prom_health=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$grafana_pod" \
    -- curl -sS --max-time 5 http://prometheus-operated.monitoring.svc.cluster.local:9090/-/healthy 2>/dev/null || echo "UNREACHABLE")

  if [[ "$prom_health" == *"healthy"* || "$prom_health" == *"Healthy"* ]]; then
    pass "Prometheus datasource is reachable and healthy"
  elif [[ "$prom_health" == "UNREACHABLE" ]]; then
    fail "Cannot reach Prometheus at http://prometheus-operated.monitoring.svc.cluster.local:9090"
    info "Check: kubectl -n monitoring get svc prometheus-operated"
    info "Check: kubectl exec -it <prometheus-pod> -- curl -sS http://localhost:9090/-/healthy"
  else
    warn "Prometheus health check returned unexpected response: $prom_health"
  fi

  # Test Loki datasource
  info "Testing Loki datasource connection from Grafana..."
  local loki_ready
  loki_ready=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$grafana_pod" \
    -- curl -sS --max-time 5 http://loki.monitoring.svc.cluster.local:3100/ready 2>/dev/null || echo "UNREACHABLE")

  if [[ "$loki_ready" == *"ready"* || "$loki_ready" == *"Ready"* || "$loki_ready" == *"no state"* ]]; then
    pass "Loki datasource is reachable and ready"
  elif [[ "$loki_ready" == "UNREACHABLE" ]]; then
    fail "Cannot reach Loki at http://loki.monitoring.svc.cluster.local:3100"
    info "Check: kubectl -n monitoring get svc loki"
    info "Check: kubectl exec -it <loki-pod> -- curl -sS http://localhost:3100/ready"
  else
    warn "Loki ready check returned unexpected response: $loki_ready"
  fi

  # Test Tempo datasource
  info "Testing Tempo datasource connection from Grafana..."
  local tempo_ready
  tempo_ready=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$grafana_pod" \
    -- curl -sS --max-time 5 http://tempo.monitoring.svc.cluster.local:3200/ready 2>/dev/null || echo "UNREACHABLE")

  if [[ "$tempo_ready" == *"ready"* || "$tempo_ready" == *"Ready"* ]]; then
    pass "Tempo datasource is reachable and ready"
  elif [[ "$tempo_ready" == "UNREACHABLE" ]]; then
    fail "Cannot reach Tempo at http://tempo.monitoring.svc.cluster.local:3200"
    info "Check: kubectl -n monitoring get svc -l app.kubernetes.io/name=tempo"
    info "Check: kubectl -n monitoring get pods -l app.kubernetes.io/name=tempo"
  else
    warn "Tempo ready check returned unexpected response: $tempo_ready"
  fi

  # Verify datasource configuration in Grafana
  info "Checking Grafana datasource configuration..."
  local ds_config
  ds_config=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$grafana_pod" \
    -- cat /etc/grafana/provisioning/datasources/datasources.yaml 2>/dev/null || echo "NOT_FOUND")

  if [[ "$ds_config" != "NOT_FOUND" ]]; then
    info "Grafana datasource config:"
    echo "$ds_config" | head -30
  else
    warn "No provisioned datasource file found at /etc/grafana/provisioning/datasources/datasources.yaml"
    info "Check: kubectl exec -it $grafana_pod -- ls -la /etc/grafana/provisioning/datasources/"
  fi

  info ""
  info "To test data sources from the Grafana UI:"
  info "  1. Port-forward: kubectl -n monitoring port-forward svc/grafana 3000:80"
  info "  2. Visit http://localhost:3000/monitoring/datasources"
  info "  3. Click 'View' for each datasource, then 'Test'"
  info ""
  info "Expected datasource URLs (from gitops/values/grafana.yaml):"
  info "  Prometheus: http://prometheus-operated.monitoring.svc.cluster.local:9090"
  info "  Loki:       http://loki.monitoring.svc.cluster.local:3100"
  info "  Tempo:      http://tempo.monitoring.svc.cluster.local:3200"

  return 0
}

# ============================================================================
# LAYER 2: Prometheus (Metrics) Layer
# ============================================================================
check_prometheus_targets() {
  section "Layer 2: Prometheus Targets"

  local prom_pod
  prom_pod=$(kubectl --kubeconfig="$KUBECONFIG" get pod -n monitoring \
    -l 'app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$prom_pod" ]]; then
    # Fallback: try other label patterns
    prom_pod=$(kubectl --kubeconfig="$KUBECONFIG" get pod -n monitoring \
      --no-headers 2>/dev/null | grep 'prometheus.*prometheus' | awk '{print $1}' | head -1 || true)
  fi

  if [[ -z "$prom_pod" ]]; then
    fail "Prometheus pod not found in monitoring namespace"
    info "Check: kubectl -n monitoring get pods | grep prometheus"
    return 1
  fi

  if [[ -z "$prom_pod" ]]; then
    fail "Prometheus pod not found in monitoring namespace"
    info "Check: kubectl -n monitoring get pods | grep prometheus"
    return 1
  fi

  pass "Prometheus pod found: $prom_pod"

  # Check /targets endpoint
  info "Checking Prometheus targets..."
  local targets_json
  targets_json=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$prom_pod" \
    -- curl -sS --max-time 5 http://localhost:9090/api/v1/targets 2>/dev/null || echo "{}")

  local active_count
  active_count=$(echo "$targets_json" | jq '.data.activeTargets | length' 2>/dev/null || echo "0")

  if [[ "$active_count" -eq 0 ]]; then
    fail "No active scrape targets found"
    info "Prometheus is not scraping any targets."
    info "Check: kubectl -n monitoring get servicemonitors,podmonitors --all-namespaces"
    info "Check: kubectl -n monitoring get endpoints prometheus-operated"
    return 1
  fi

  pass "Found $active_count active scrape targets"

  # Show target states
  local down_targets
  down_targets=$(echo "$targets_json" | jq -r '[.data.activeTargets[] | select(.health != "up")] | length' 2>/dev/null || echo "0")

  if [[ "$down_targets" -gt 0 ]]; then
    warn "$down_targets target(s) are DOWN"
    echo "$targets_json" | jq -r '.data.activeTargets[] | select(.health != "up") | "  - \(.labels.job): \(.health) (\(.labels.instance // "N/A"))"'
  else
    pass "All $active_count targets are UP"
  fi

  # Show target summary by job
  info "Target summary by job:"
  echo "$targets_json" | jq -r '.data.activeTargets[].labels.job' 2>/dev/null | sort | uniq -c | sort -rn | while read -r count job; do
    info "  $job: $count target(s)"
  done

  # Test querying metrics directly
  info "Testing direct metric queries in Prometheus..."

  # Check 'up' metric
  local up_result
  up_result=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$prom_pod" \
    -- curl -sS --max-time 5 'http://localhost:9090/api/v1/query?query=up' 2>/dev/null || echo "{}")

  local up_series
  up_series=$(echo "$up_result" | jq '.data.result | length' 2>/dev/null || echo "0")

  if [[ "$up_series" -gt 0 ]]; then
    pass "Metric 'up' returns $up_series series"
  else
    fail "Metric 'up' returns 0 series - Prometheus may not be scraping"
  fi

  # Check node_exporter metrics
  local node_metric
  node_metric=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$prom_pod" \
    -- curl -sS --max-time 5 'http://localhost:9090/api/v1/query?query=node_cpu_seconds_total' 2>/dev/null || echo "{}")

  local node_series
  node_series=$(echo "$node_metric" | jq '.data.result | length' 2>/dev/null || echo "0")

  if [[ "$node_series" -gt 0 ]]; then
    pass "node_cpu_seconds_total returns $node_series series"
  else
    warn "node_cpu_seconds_total returns 0 series - Node Exporter may not be scraping"
    info "Check: kubectl -n monitoring get daemonset -l app.kubernetes.io/name=node-exporter"
  fi

  # Check kube_state_metrics
  local ksm_metric
  ksm_metric=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$prom_pod" \
    -- curl -sS --max-time 5 'http://localhost:9090/api/v1/query?query=kube_pod_info' 2>/dev/null || echo "{}")

  local ksm_series
  ksm_series=$(echo "$ksm_metric" | jq '.data.result | length' 2>/dev/null || echo "0")

  if [[ "$ksm_series" -gt 0 ]]; then
    pass "kube_pod_info returns $ksm_series series"
  else
    warn "kube_pod_info returns 0 series - Kube State Metrics may not be scraping"
  fi

  return 0
}

# ============================================================================
# LAYER 3: Alloy (Logs, Events, and Traces) Layer
# ============================================================================
check_alloy_pipeline() {
  section "Layer 3: Alloy (Logs, Events, and Traces) Layer"

  local alloy_pod
  alloy_pod=$(get_pod_namespace "app.kubernetes.io/name=alloy")

  if [[ -z "$alloy_pod" ]]; then
    fail "Alloy pod not found in monitoring namespace"
    info "Check: kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy"
    return 1
  fi

  pass "Alloy pod found: $alloy_pod"

  local alloy_phase
  alloy_phase=$(kubectl --kubeconfig="$KUBECONFIG" get pod -n monitoring "$alloy_pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  local alloy_ready
  alloy_ready=$(kubectl --kubeconfig="$KUBECONFIG" get pod -n monitoring "$alloy_pod" -o jsonpath='{.status.containerStatuses[?(@.ready==true)].name}' 2>/dev/null || true)

  if [[ "$alloy_phase" == "Running" && -n "$alloy_ready" ]]; then
    pass "Alloy is running and has a ready container"
  else
    warn "Alloy pod is not fully ready yet: phase=$alloy_phase"
  fi

  info "Checking Alloy logs for errors..."
  local alloy_logs
  alloy_logs=$(kubectl --kubeconfig="$KUBECONFIG" logs -n monitoring "$alloy_pod" --tail=50 2>/dev/null || echo "")

  if echo "$alloy_logs" | grep -qi 'error\|panic\|fatal'; then
    warn "Alloy logs contain errors:"
    echo "$alloy_logs" | grep -i 'error\|panic\|fatal' | head -10
  else
    pass "No errors found in Alloy logs"
  fi

  return 0
}

# ============================================================================
# LAYER 4: Loki (Logs) Layer
# ============================================================================
check_loki_logs() {
  section "Layer 4: Loki (Logs) Layer"

  local loki_pod
  loki_pod=$(get_pod_namespace "app=loki")

  if [[ -z "$loki_pod" ]]; then
    fail "Loki pod not found in monitoring namespace"
    info "Check: kubectl -n monitoring get pods -l app=loki"
    return 1
  fi

  pass "Loki pod found: $loki_pod"

  # Check Loki readiness
  info "Checking Loki readiness..."
  local loki_status
  loki_status=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$loki_pod" \
    -- curl -sS --max-time 5 http://localhost:3100/ready 2>/dev/null || echo "UNREACHABLE")

  if [[ "$loki_status" == *"ready"* || "$loki_status" == *"no state"* ]]; then
    pass "Loki is ready"
  else
    fail "Loki is not ready: $loki_status"
  fi

  # Check if any log streams exist
  info "Checking for log streams in Loki..."
  local stream_result
  stream_result=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$loki_pod" \
    -- curl -sS --max-time 5 'http://localhost:3100/loki/api/v1/label/__name__/values' 2>/dev/null || echo "[]")

  local stream_count
  stream_count=$(echo "$stream_result" | jq 'length' 2>/dev/null || echo "0")

  if [[ "$stream_count" -eq 0 ]]; then
    warn "No log streams found in Loki"
    info "This is expected if no workloads or events have been shipped yet, but Alloy should still be present."
    info "Checking for the Alloy collector..."

    local log_collector
    log_collector=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n monitoring \
      -l 'app.kubernetes.io/name=alloy' \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -z "$log_collector" ]]; then
      fail "No Alloy collector found in the monitoring namespace"
      info "Loki requires Grafana Alloy to ship logs, events, and traces in this greenfield stack."
      info "Check: kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy"
    else
      pass "Log collector found: $log_collector"
    fi
  else
    pass "Found $stream_count log stream(s) in Loki"
  fi

  # Check Loki logs for errors
  info "Checking Loki container logs for errors..."
  local loki_logs
  loki_logs=$(kubectl --kubeconfig="$KUBECONFIG" logs -n monitoring "$loki_pod" --tail=50 2>/dev/null || echo "")

  if echo "$loki_logs" | grep -qi 'error\|panic\|fatal'; then
    fail "Loki logs contain errors:"
    echo "$loki_logs" | grep -i 'error\|panic\|fatal' | head -10
  else
    pass "No errors found in Loki logs"
  fi

  return 0
}

# ============================================================================
# LAYER 5: Grafana Dashboard Configuration
# ============================================================================
check_grafana_dashboards() {
  section "Layer 5: Grafana Dashboard Configuration"

  local grafana_pod
  grafana_pod=$(get_pod_namespace "app.kubernetes.io/name=grafana")

  if [[ -z "$grafana_pod" ]]; then
    fail "Grafana pod not found"
    return 1
  fi

  # Check seeded dashboards (ConfigMaps)
  info "Checking seeded dashboard ConfigMaps..."
  local dashboards
  dashboards=$(kubectl --kubeconfig="$KUBECONFIG" get configmaps -n monitoring \
    -l grafana_dashboard=1 \
    --no-headers 2>/dev/null | awk '{print $1}' || true)

  if [[ -z "$dashboards" ]]; then
    fail "No dashboard ConfigMaps found with label grafana_dashboard=1"
    info "Check: kubectl -n monitoring get configmaps -l grafana_dashboard=1"
  else
    pass "Found $(echo "$dashboards" | wc -l) dashboard ConfigMap(s):"
    echo "$dashboards" | while read -r cm; do
      info "  - $cm"
    done
  fi

  # Check Grafana server logs for errors
  info "Checking Grafana logs for datasource/query errors..."
  local grafana_logs
  grafana_logs=$(kubectl --kubeconfig="$KUBECONFIG" logs -n monitoring "$grafana_pod" --tail=100 2>/dev/null || echo "")

  local error_lines
  error_lines=$(echo "$grafana_logs" | grep -ci 'error\|failed\|unauthorized\|forbidden' 2>/dev/null || echo "0")

  if [[ "$error_lines" -gt 0 ]]; then
    warn "Found $error_lines error/warning line(s) in Grafana logs:"
    echo "$grafana_logs" | grep -i 'error\|failed\|unauthorized\|forbidden' | head -15
  else
    pass "No datasource/query errors found in Grafana logs"
  fi

  # Check dashboard sidecar status
  info "Checking Grafana sidecar configuration..."
  local ds_cm_count
  ds_cm_count=$(kubectl --kubeconfig="$KUBECONFIG" get configmaps -n monitoring \
    -l grafana_datasource=1 \
    --no-headers 2>/dev/null | wc -l || echo "0")

  if [[ "$ds_cm_count" -gt 0 ]]; then
    pass "Grafana sidecar found $ds_cm_count datasource ConfigMap(s)"
  else
    warn "No datasource sidecar ConfigMaps found (datasources are provisioned via Helm values)"
  fi

  # Check if Grafana can list datasources via API
  info "Checking Grafana datasources via API..."
  local grafana_svc
  grafana_svc=$(kubectl --kubeconfig="$KUBECONFIG" get svc -n monitoring grafana \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

  if [[ -n "$grafana_svc" ]]; then
    info "Grafana service ClusterIP: $grafana_svc"
    info "Port-forward to inspect datasources: kubectl -n monitoring port-forward svc/grafana 3000:80"
    info "Then visit http://localhost:3000/monitoring/datasources"
  else
    warn "Grafana ClusterIP not found (may be using different service type)"
  fi

  # Check for common dashboard placeholder issues
  info "Checking dashboard JSON for placeholder replacement issues..."
  echo "$dashboards" | while read -r cm; do
    local cm_data
    cm_data=$(kubectl --kubeconfig="$KUBECONFIG" get configmap "$cm" -n monitoring \
      -o jsonpath='{.data}' 2>/dev/null || echo "{}")

    # Check for unreplaced ${DATASOURCE} placeholders
    local unreplaced
    unreplaced=$(echo "$cm_data" | grep -c '\${DATASOURCE}\|\${DS_PROMETHEUS}\|\${DS_LOCALHOST}\|\${P4169E866C3094E38}' 2>/dev/null || echo "0")

    if [[ "$unreplaced" -gt 0 ]]; then
      warn "ConfigMap '$cm' may contain unreplaced datasource placeholders"
      info "  This dashboard may show 'No data' because placeholders weren't replaced."
      info "  The install-grafana seeding script replaces: \${DATASOURCE}, \${DS_MK8S}, \${DS_LOCALHOST}, \${DS_PROMETHEUS}, \${DS_SERVICEMONITOR}, \${DS_LOKI}, \${VAR_JOB}, \${P4169E866C3094E38}"
      info "  But queries using \$$cm (by uid) are NOT replaced."
    fi
  done

  return 0
}

# ============================================================================
# LAYER 6: Infrastructure & Network
# ============================================================================
check_infrastructure() {
  section "Layer 6: Infrastructure & Network"

  # Check PVC usage
  info "Checking PersistentVolumeClaim usage..."
  local pvcs
  pvcs=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n monitoring \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.storage}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")

  if [[ -n "$pvcs" ]]; then
    info "Monitoring PVCs:"
    while IFS=$'\t' read -r name capacity phase; do
      if [[ "$name" == *"prometheus"* || "$name" == *"loki"* || "$name" == *"alertmanager"* ]]; then
        if [[ "$phase" == "Bound" ]]; then
          pass "$name: $capacity (Bound)"
        else
          fail "$name: $capacity ($phase)"
        fi
      fi
    done <<< "$pvcs"
  else
    warn "No PVCs found in monitoring namespace"
  fi

  # Check PVC fill percentage
  info "Checking PVC fill percentage..."
  local prom_pvc
  prom_pvc=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n monitoring \
    -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$prom_pvc" ]]; then
    local prom_usage
    prom_usage=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring \
      "$(kubectl --kubeconfig="$KUBECONFIG" get pod -n monitoring -l app=prometheus \
        -o jsonpath='{.items[0].metadata.name}')" \
      -- df -h /prometheus 2>/dev/null | tail -1 || echo "")

    if [[ -n "$prom_usage" ]]; then
      local used_pct
      used_pct=$(echo "$prom_usage" | awk '{print $5}' | tr -d '%' || echo "0")
      if [[ "$used_pct" -gt 90 ]]; then
        fail "Prometheus PVC is ${used_pct}% full - data may be evicted or writes failing"
      elif [[ "$used_pct" -gt 70 ]]; then
        warn "Prometheus PVC is ${used_pct}% full - consider increasing storage"
      else
        pass "Prometheus PVC is ${used_pct}% full"
      fi
    fi
  fi

  local loki_pvc
  loki_pvc=$(kubectl --kubeconfig="$KUBECONFIG" get pvc -n monitoring \
    -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$loki_pvc" ]]; then
    local loki_usage
    loki_usage=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring \
      "$(kubectl --kubeconfig="$KUBECONFIG" get pod -n monitoring -l app=loki \
        -o jsonpath='{.items[0].metadata.name}')" \
      -- df -h /loki 2>/dev/null | tail -1 || echo "")

    if [[ -n "$loki_usage" ]]; then
      local loki_pct
      loki_pct=$(echo "$loki_usage" | awk '{print $5}' | tr -d '%' || echo "0")
      if [[ "$loki_pct" -gt 90 ]]; then
        fail "Loki PVC is ${loki_pct}% full - data may be evicted or writes failing"
      elif [[ "$loki_pct" -gt 70 ]]; then
        warn "Loki PVC is ${loki_pct}% full - consider increasing storage"
      else
        pass "Loki PVC is ${loki_pct}% full"
      fi
    fi
  fi

  # Check for OOMKilled pods
  info "Checking for OOMKilled or CrashLoopBackOff pods..."
  local problem_pods
  problem_pods=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n monitoring \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.lastState.reason}{"\t"}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null | grep -i 'OOMKilled\|CrashLoopBackOff' || true)

  if [[ -n "$problem_pods" ]]; then
    fail "Problem pods found:"
    echo "$problem_pods"
  else
    pass "No OOMKilled or CrashLoopBackOff pods in monitoring namespace"
  fi

  # Check resource usage
  info "Checking monitoring pod resource usage..."
  local resource_output
  resource_output=$(kubectl --kubeconfig="$KUBECONFIG" top pods -n monitoring 2>/dev/null || echo "")

  if [[ -n "$resource_output" ]]; then
    info "Pod resource usage:"
    echo "$resource_output"
  else
    warn "kubectl top not available (metrics-server may not be deployed)"
  fi

  # Check for network policies that might block traffic
  info "Checking for NetworkPolicies in monitoring namespace..."
  local netpol_count
  netpol_count=$(kubectl --kubeconfig="$KUBECONFIG" get networkpolicies -n monitoring \
    --no-headers 2>/dev/null | wc -l || echo "0")

  if [[ "$netpol_count" -gt 0 ]]; then
    warn "Found $netpol_count NetworkPolicy(s) in monitoring namespace"
    kubectl --kubeconfig="$KUBECONFIG" get networkpolicies -n monitoring -o wide 2>/dev/null
  else
    pass "No NetworkPolicies blocking monitoring traffic"
  fi

  # Check service DNS resolution from Grafana pod
  info "Checking service DNS resolution from Grafana pod..."
  local infra_grafana_pod
  infra_grafana_pod=$(get_pod_namespace "app.kubernetes.io/name=grafana")
  local dns_test
  dns_test=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$infra_grafana_pod" \
    -- nslookup prometheus-operated.monitoring.svc.cluster.local 2>/dev/null || echo "DNS_FAILED")

  if echo "$dns_test" | grep -qi 'name\|server'; then
    pass "DNS resolution for prometheus-operated works"
  else
    fail "DNS resolution for prometheus-operated.monitoring.svc.cluster.local failed"
    info "Check CoreDNS: kubectl -n kube-system get pods -l k8s-app=kube-dns"
  fi

  local loki_dns
  loki_dns=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$infra_grafana_pod" \
    -- nslookup loki.monitoring.svc.cluster.local 2>/dev/null || echo "DNS_FAILED")

  if echo "$loki_dns" | grep -qi 'name\|server'; then
    pass "DNS resolution for loki.monitoring.svc.cluster.local works"
  else
    fail "DNS resolution for loki.monitoring.svc.cluster.local failed"
  fi

  local tempo_dns
  tempo_dns=$(kubectl --kubeconfig="$KUBECONFIG" exec -n monitoring "$infra_grafana_pod" \
    -- nslookup tempo.monitoring.svc.cluster.local 2>/dev/null || echo "DNS_FAILED")

  if echo "$tempo_dns" | grep -qi 'name\|server'; then
    pass "DNS resolution for tempo.monitoring.svc.cluster.local works"
  else
    fail "DNS resolution for tempo.monitoring.svc.cluster.local failed"
  fi

  return 0
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  echo "=========================================="
  echo "  Twinbox Monitoring Stack Diagnostic Tool"
  echo "=========================================="

  check_kubeconfig || exit 1

  local overall_pass=0
  local overall_fail=0
  local overall_warn=0

  # Layer 1: Data Source Connectivity
  if check_data_sources; then
    ((overall_pass++))
  else
    ((overall_fail++))
  fi

  # Layer 2: Prometheus Targets
  if check_prometheus_targets; then
    ((overall_pass++))
  else
    ((overall_fail++))
  fi

  # Layer 3: Alloy Pipeline
  if check_alloy_pipeline; then
    ((overall_pass++))
  else
    ((overall_fail++))
  fi

  # Layer 4: Loki Logs
  if check_loki_logs; then
    ((overall_pass++))
  else
    ((overall_fail++))
  fi

  # Layer 5: Grafana Dashboards
  if check_grafana_dashboards; then
    ((overall_pass++))
  else
    ((overall_fail++))
  fi

  # Layer 6: Infrastructure
  if check_infrastructure; then
    ((overall_pass++))
  else
    ((overall_fail++))
  fi

  section "Summary"
  echo -e "  ${COLOR_GREEN}Layers passed:${COLOR_RESET} $overall_pass"
  echo -e "  ${COLOR_RED}Layers failed:${COLOR_RESET} $overall_fail"
  echo -e "  ${COLOR_YELLOW}Warnings:${COLOR_RESET} Check [WARN] entries above"

  echo ""
  echo "Troubleshooting Quick Reference:"
  echo "  Port-forward Grafana: kubectl -n monitoring port-forward svc/grafana 3000:80"
  echo "  Port-forward Prometheus: kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-stack-prometheus 9090:9090"
  echo "  Port-forward Loki: kubectl -n monitoring port-forward svc/loki 3100:3100"
  echo "  Port-forward Tempo: kubectl -n monitoring port-forward svc/tempo 3200:3200"
  echo ""
  echo "  View Prometheus targets: http://localhost:9090/targets"
  echo "  Query Prometheus: http://localhost:9090/graph"
  echo "  View Grafana datasources: http://localhost:3000/monitoring/datasources"
  echo ""

  if [[ "$overall_fail" -gt 0 ]]; then
    echo -e "${COLOR_RED}Some layers failed. Review [FAIL] and [WARN] entries above.${COLOR_RESET}"
    return 1
  else
    echo -e "${COLOR_GREEN}All layers passed.${COLOR_RESET}"
    return 0
  fi
}

main "$@"
