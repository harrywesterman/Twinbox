#!/usr/bin/env node

const PROMETHEUS = "Prometheus";
const LOKI = "Loki";

function panelBase({
  title,
  type,
  datasource,
  x,
  y,
  w,
  h,
  targets,
  fieldConfig,
  options,
  timeFrom,
  timeShift,
  transparent = false,
}) {
  const panel = {
    id: null,
    title,
    type,
    datasource,
    gridPos: { x, y, w, h },
    targets,
    fieldConfig,
    options,
    transparent,
  };

  if (timeFrom != null) {
    panel.timeFrom = timeFrom;
  }

  if (timeShift != null) {
    panel.timeShift = timeShift;
  }

  return panel;
}

function statPanel({
  title,
  expr,
  datasource = PROMETHEUS,
  unit = "none",
  decimals = 0,
  x,
  y,
  w = 6,
  h = 4,
  thresholds = [{ color: "green", value: null }],
  mappings = [],
  links = [],
  textMode = "auto",
  colorMode = "value",
  graphMode = "none",
  justifyMode = "auto",
}) {
  return panelBase({
    title,
    type: "stat",
    datasource,
    x,
    y,
    w,
    h,
    targets: [
      {
        refId: "A",
        expr: `(${expr}) or vector(0)`,
        instant: true,
        range: false,
        queryType: "instant",
        format: "time_series",
      },
    ],
    fieldConfig: {
      defaults: {
        unit,
        decimals,
        color: { mode: "thresholds" },
        mappings,
        links,
        thresholds: {
          mode: "absolute",
          steps: thresholds,
        },
      },
      overrides: [],
    },
    options: {
      reduceOptions: {
        calcs: ["lastNotNull"],
        fields: "",
        values: false,
      },
      orientation: "horizontal",
      textMode,
      colorMode,
      graphMode,
      justifyMode,
    },
  });
}

function buttonPanel({ title, text, url, x, y, w = 4, h = 4 }) {
  return statPanel({
    title,
    expr: "vector(1)",
    unit: "none",
    decimals: 0,
    x,
    y,
    w,
    h,
    thresholds: [{ color: "blue", value: null }],
    mappings: [
      {
        type: "value",
        options: {
          1: {
            text,
            color: "blue",
          },
        },
      },
    ],
    links: [
      {
        title: text,
        url,
        targetBlank: false,
      },
    ],
    textMode: "value",
  });
}

function normalizeTargets(targets) {
  if (targets == null) {
    return [];
  }

  const list = Array.isArray(targets) ? targets : [targets];
  return list.map((target, index) => {
    if (typeof target === "string") {
      return { refId: String.fromCharCode(65 + index), expr: target };
    }

    return {
      refId: target.refId ?? String.fromCharCode(65 + index),
      expr: target.expr,
      legendFormat: target.legendFormat,
      instant: target.instant,
      range: target.range,
      queryType: target.queryType,
      format: target.format,
      maxLines: target.maxLines,
      interval: target.interval,
      step: target.step,
      limit: target.limit,
    };
  });
}

function timeSeriesPanel({
  title,
  expr,
  targets,
  datasource = PROMETHEUS,
  unit = "none",
  decimals = 0,
  x,
  y,
  w = 12,
  h = 8,
}) {
  const normalizedTargets = targets != null ? normalizeTargets(targets) : normalizeTargets(expr);
  const resolvedTargets = normalizedTargets.map((target) => ({
    ...target,
    instant: false,
    range: true,
    queryType: target.queryType ?? "range",
    format: target.format ?? "time_series",
  }));

  return panelBase({
    title,
    type: "timeseries",
    datasource,
    x,
    y,
    w,
    h,
    targets: resolvedTargets,
    fieldConfig: {
      defaults: {
        unit,
        decimals,
        color: { mode: "palette-classic" },
      },
      overrides: [],
    },
    options: {
      legend: {
        calcs: ["lastNotNull", "max"],
        displayMode: "list",
        placement: "bottom",
      },
      tooltip: {
        mode: "single",
        sort: "none",
      },
    },
  });
}

function logsPanel({ title, expr, x, y, w = 8, h = 10, maxLines = 250, timeFrom }) {
  return panelBase({
    title,
    type: "logs",
    datasource: LOKI,
    x,
    y,
    w,
    h,
    targets: [
      {
        refId: "A",
        expr,
        queryType: "range",
        range: true,
        instant: false,
        format: "logs",
        maxLines,
      },
    ],
    timeFrom,
    fieldConfig: {
      defaults: {},
      overrides: [],
    },
    options: {
      showTime: true,
      showLabels: true,
      showCommonLabels: false,
      sortOrder: "Descending",
      wrapLogMessage: false,
      prettifyLogMessage: false,
      enableLogDetails: true,
      dedupStrategy: "none",
    },
  });
}

function dashboard({
  uid,
  title,
  description,
  panels,
  links = [],
  timeFrom = "now-6h",
  tags = [],
}) {
  return {
    uid,
    title,
    description,
    tags: ["twinbox", ...tags],
    timezone: "browser",
    schemaVersion: 39,
    version: 1,
    refresh: "30s",
    time: {
      from: timeFrom,
      to: "now",
    },
    timepicker: {
      hidden: false,
    },
    annotations: {
      list: [],
    },
    editable: true,
    graphTooltip: 1,
    links,
    liveNow: false,
    fiscalYearStartMonth: 0,
    style: "dark",
    templating: {
      list: [],
    },
    panels: panels.map((panel, index) => ({ ...panel, id: index + 1 })),
  };
}

const nodeNetworkFilter = '{device!~"lo|veth.*|cni.*|flannel.*|docker.*|dummy.*"}';
const nodeFilesystemFilter = '{fstype!~"tmpfs|overlay|squashfs|nsfs|proc|sysfs|cgroup2"}';
const runningContainerFilter = '{container!="",image!=""}';
const lokiCluster = '{cluster="twinbox"}';
const lokiEvents =
  '{cluster="twinbox", kubernetes_cluster_events="integrations/kubernetes/eventhandler"}';

function buildNodesDashboard() {
  return dashboard({
    uid: "twinbox-nodes",
    title: "Twinbox Nodes",
    description: "Node health, CPU, memory, filesystem, and network usage.",
    tags: ["nodes", "capacity"],
    panels: [
      statPanel({
        title: "Ready nodes",
        expr: 'count(kube_node_status_condition{condition="Ready",status="true"})',
        x: 0,
        y: 0,
      }),
      statPanel({
        title: "Unschedulable nodes",
        expr: "sum(kube_node_spec_unschedulable)",
        x: 6,
        y: 0,
      }),
      statPanel({
        title: "Cluster CPU",
        expr: 'sum(rate(node_cpu_seconds_total{mode!="idle",mode!="iowait"}[5m])) / sum(rate(node_cpu_seconds_total[5m]))',
        unit: "percentunit",
        decimals: 1,
        x: 12,
        y: 0,
      }),
      statPanel({
        title: "Cluster memory",
        expr: "1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)",
        unit: "percentunit",
        decimals: 1,
        x: 18,
        y: 0,
      }),
      timeSeriesPanel({
        title: "CPU by node",
        expr: 'sum by (node) (rate(node_cpu_seconds_total{mode!="idle",mode!="iowait"}[5m])) / sum by (node) (rate(node_cpu_seconds_total[5m]))',
        legendFormat: "{{node}}",
        unit: "percentunit",
        decimals: 1,
        x: 0,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Memory by node",
        expr: "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes",
        legendFormat: "{{node}}",
        unit: "percentunit",
        decimals: 1,
        x: 12,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Network throughput by node",
        targets: [
          {
            expr: `sum by (node) (rate(node_network_receive_bytes_total${nodeNetworkFilter}[5m]))`,
            legendFormat: "RX {{node}}",
          },
          {
            expr: `sum by (node) (rate(node_network_transmit_bytes_total${nodeNetworkFilter}[5m]))`,
            legendFormat: "TX {{node}}",
          },
        ],
        unit: "Bps",
        x: 0,
        y: 12,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Filesystem usage by mountpoint",
        targets: [
          {
            expr: `1 - node_filesystem_avail_bytes${nodeFilesystemFilter} / node_filesystem_size_bytes${nodeFilesystemFilter}`,
            legendFormat: "{{node}} {{mountpoint}}",
          },
        ],
        unit: "percentunit",
        decimals: 1,
        x: 12,
        y: 12,
        w: 12,
        h: 8,
      }),
    ],
  });
}

function buildWorkloadsDashboard() {
  return dashboard({
    uid: "twinbox-workloads",
    title: "Twinbox Workloads",
    description: "Namespace, deployment, pod, and container health.",
    tags: ["workloads", "pods"],
    panels: [
      statPanel({
        title: "Namespaces",
        expr: 'count(kube_namespace_status_phase{phase="Active"})',
        x: 0,
        y: 0,
      }),
      statPanel({
        title: "Deployments available",
        expr: "sum(kube_deployment_status_replicas_available)",
        x: 6,
        y: 0,
      }),
      statPanel({
        title: "Running pods",
        expr: 'count(kube_pod_status_phase{phase="Running"})',
        x: 12,
        y: 0,
      }),
      statPanel({
        title: "Restarts last hour",
        expr: "sum(increase(kube_pod_container_status_restarts_total[1h]))",
        x: 18,
        y: 0,
      }),
      timeSeriesPanel({
        title: "Deployment desired vs available",
        targets: [
          {
            expr: "sum(kube_deployment_spec_replicas)",
            legendFormat: "Desired",
          },
          {
            expr: "sum(kube_deployment_status_replicas_available)",
            legendFormat: "Available",
          },
        ],
        unit: "short",
        x: 0,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Pod phases",
        targets: [
          {
            expr: "sum by (phase) (kube_pod_status_phase)",
            legendFormat: "{{phase}}",
          },
        ],
        unit: "short",
        x: 12,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Top pod CPU",
        targets: [
          {
            expr: `topk(10, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total${runningContainerFilter}[5m])))`,
            legendFormat: "{{namespace}}/{{pod}}",
          },
        ],
        unit: "cores",
        decimals: 3,
        x: 0,
        y: 12,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Top pod memory",
        targets: [
          {
            expr: `topk(10, sum by (namespace, pod) (container_memory_working_set_bytes${runningContainerFilter}))`,
            legendFormat: "{{namespace}}/{{pod}}",
          },
        ],
        unit: "bytes",
        x: 12,
        y: 12,
        w: 12,
        h: 8,
      }),
    ],
  });
}

function buildControlPlaneDashboard() {
  return dashboard({
    uid: "twinbox-control-plane",
    title: "Twinbox Control Plane",
    description: "API server and etcd request rate, latency, and pressure.",
    tags: ["control-plane", "etcd", "apiserver"],
    timeFrom: "now-12h",
    panels: [
      statPanel({
        title: "API requests / s",
        expr: "sum(rate(apiserver_request_total[5m]))",
        unit: "reqps",
        decimals: 2,
        x: 0,
        y: 0,
      }),
      statPanel({
        title: "API p99 latency",
        expr: "1000 * histogram_quantile(0.99, sum by (le) (rate(apiserver_request_duration_seconds_bucket[5m])))",
        unit: "ms",
        decimals: 0,
        x: 6,
        y: 0,
      }),
      statPanel({
        title: "etcd requests / s",
        expr: "sum(rate(etcd_requests_total[5m]))",
        unit: "reqps",
        decimals: 2,
        x: 12,
        y: 0,
      }),
      statPanel({
        title: "etcd p99 latency",
        expr: "1000 * histogram_quantile(0.99, sum by (le) (rate(etcd_request_duration_seconds_bucket[5m])))",
        unit: "ms",
        decimals: 0,
        x: 18,
        y: 0,
      }),
      timeSeriesPanel({
        title: "API requests by verb",
        targets: [
          {
            expr: "sum by (verb) (rate(apiserver_request_total[5m]))",
            legendFormat: "{{verb}}",
          },
        ],
        unit: "reqps",
        decimals: 2,
        x: 0,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "API p95 latency by verb",
        targets: [
          {
            expr: "1000 * histogram_quantile(0.95, sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket[5m])))",
            legendFormat: "{{verb}}",
          },
        ],
        unit: "ms",
        decimals: 0,
        x: 12,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "etcd request latency",
        targets: [
          {
            expr: "1000 * histogram_quantile(0.95, sum by (le) (rate(etcd_request_duration_seconds_bucket[5m])))",
            legendFormat: "p95",
          },
        ],
        unit: "ms",
        decimals: 0,
        x: 0,
        y: 12,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Control plane pressure",
        targets: [
          {
            expr: "sum(apiserver_current_inflight_requests)",
            legendFormat: "Inflight requests",
          },
          {
            expr: "sum(apiserver_current_inqueue_requests)",
            legendFormat: "Queued requests",
          },
          {
            expr: "sum(rate(apiserver_request_aborts_total[5m]))",
            legendFormat: "Aborts / s",
          },
          {
            expr: "sum(rate(etcd_request_errors_total[5m]))",
            legendFormat: "etcd errors / s",
          },
        ],
        unit: "short",
        decimals: 2,
        x: 12,
        y: 12,
        w: 12,
        h: 8,
      }),
    ],
  });
}

function buildStorageDashboard() {
  return dashboard({
    uid: "twinbox-storage",
    title: "Twinbox Storage",
    description: "PVC utilization and Longhorn control-plane readiness.",
    tags: ["storage", "pvc", "longhorn"],
    panels: [
      statPanel({
        title: "Bound PVCs",
        expr: 'count(kube_persistentvolumeclaim_status_phase{phase="Bound"})',
        x: 0,
        y: 0,
      }),
      statPanel({
        title: "PVCs > 70%",
        expr: "count((kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) > 0.70)",
        x: 6,
        y: 0,
      }),
      statPanel({
        title: "PVCs > 85%",
        expr: "count((kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) > 0.85)",
        x: 12,
        y: 0,
      }),
      statPanel({
        title: "Longhorn manager ready",
        expr: 'sum(kube_pod_status_ready{namespace="longhorn-system",condition="true",pod=~"longhorn-manager.*"})',
        x: 18,
        y: 0,
      }),
      statPanel({
        title: "Longhorn CSI ready",
        expr: 'sum(kube_pod_status_ready{namespace="longhorn-system",condition="true",pod=~"longhorn-csi-plugin.*"})',
        x: 0,
        y: 4,
      }),
      timeSeriesPanel({
        title: "PVC usage by namespace",
        targets: [
          {
            expr: "sum by (namespace) (kubelet_volume_stats_used_bytes) / sum by (namespace) (kubelet_volume_stats_capacity_bytes)",
            legendFormat: "{{namespace}}",
          },
        ],
        unit: "percentunit",
        decimals: 1,
        x: 6,
        y: 4,
        w: 18,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Top PVC usage",
        targets: [
          {
            expr: "topk(10, kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes)",
            legendFormat: "{{namespace}}/{{persistentvolumeclaim}}",
          },
        ],
        unit: "percentunit",
        decimals: 1,
        x: 0,
        y: 12,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Requested storage by namespace",
        targets: [
          {
            expr: "sum by (namespace) (kube_persistentvolumeclaim_resource_requests_storage_bytes)",
            legendFormat: "{{namespace}}",
          },
        ],
        unit: "bytes",
        x: 12,
        y: 12,
        w: 12,
        h: 8,
      }),
    ],
  });
}

function buildLogsEventsDashboard() {
  return dashboard({
    uid: "twinbox-logs-events",
    title: "Twinbox Logs & Events",
    description: "Cluster-wide log volume, noisy errors, and Kubernetes event streams.",
    tags: ["logs", "events", "loki"],
    timeFrom: "now-1h",
    links: [
      {
        title: "Zoom logs",
        url: "/d/twinbox-logs-detail/twinbox-logs-detail?orgId=1&from=now-1h&to=now",
        targetBlank: false,
        includeVars: true,
      },
    ],
    panels: [
      statPanel({
        title: "Logs / s",
        expr: `sum(count_over_time(${lokiCluster}[5m])) / 300`,
        datasource: LOKI,
        unit: "ops",
        decimals: 2,
        x: 0,
        y: 0,
        w: 5,
      }),
      statPanel({
        title: "Error logs / s",
        expr: `sum(count_over_time(${lokiCluster} |~ "(?i)error|panic|fail" [5m])) / 300`,
        datasource: LOKI,
        unit: "ops",
        decimals: 2,
        x: 5,
        y: 0,
        w: 5,
      }),
      statPanel({
        title: "Events (5m)",
        expr: `sum(count_over_time(${lokiEvents}[5m]))`,
        datasource: LOKI,
        unit: "short",
        decimals: 0,
        x: 10,
        y: 0,
        w: 5,
      }),
      statPanel({
        title: "Warning events (5m)",
        expr: `sum(count_over_time(${lokiEvents} |~ "(?i)warning|failed|error" [5m]))`,
        datasource: LOKI,
        unit: "short",
        decimals: 0,
        x: 15,
        y: 0,
        w: 5,
      }),
      buttonPanel({
        title: "Zoom logs",
        text: "Open detail",
        url: "/d/twinbox-logs-detail/twinbox-logs-detail?orgId=1",
        x: 20,
        y: 0,
      }),
      timeSeriesPanel({
        title: "Log volume",
        targets: [
          {
            expr: `sum(count_over_time(${lokiCluster}[5m])) / 300`,
            legendFormat: "Logs / s",
          },
        ],
        datasource: LOKI,
        unit: "ops",
        decimals: 2,
        x: 0,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Event volume",
        targets: [
          {
            expr: `sum(count_over_time(${lokiEvents}[5m]))`,
            legendFormat: "Events / 5m",
          },
        ],
        datasource: LOKI,
        unit: "short",
        decimals: 0,
        x: 12,
        y: 4,
        w: 12,
        h: 8,
      }),
      logsPanel({
        title: "Cluster logs",
        expr: lokiCluster,
        x: 0,
        y: 12,
        w: 8,
        h: 12,
        maxLines: 80,
        timeFrom: "1h",
      }),
      logsPanel({
        title: "Errors and warnings",
        expr: `${lokiCluster} |~ "(?i)error|warn|panic|fail"`,
        x: 8,
        y: 12,
        w: 8,
        h: 12,
        maxLines: 50,
        timeFrom: "1h",
      }),
      logsPanel({
        title: "Kubernetes events",
        expr: lokiEvents,
        x: 16,
        y: 12,
        w: 8,
        h: 12,
        maxLines: 50,
        timeFrom: "1h",
      }),
    ],
  });
}

function buildLogsDetailDashboard() {
  return dashboard({
    uid: "twinbox-logs-detail",
    title: "Twinbox Logs Detail",
    description: "A larger, easier-to-read cluster log view with event context.",
    tags: ["logs", "detail", "loki"],
    timeFrom: "now-1h",
    links: [
      {
        title: "Back to overview",
        url: "/d/twinbox-logs-events/twinbox-logs-and-events?orgId=1&from=now-1h&to=now",
        targetBlank: false,
        includeVars: true,
      },
    ],
    panels: [
      statPanel({
        title: "Logs / s",
        expr: `sum(count_over_time(${lokiCluster}[5m])) / 300`,
        datasource: LOKI,
        unit: "ops",
        decimals: 2,
        x: 0,
        y: 0,
      }),
      statPanel({
        title: "Errors / s",
        expr: `sum(count_over_time(${lokiCluster} |~ "(?i)error|panic|fail" [5m])) / 300`,
        datasource: LOKI,
        unit: "ops",
        decimals: 2,
        x: 6,
        y: 0,
      }),
      statPanel({
        title: "Events (5m)",
        expr: `sum(count_over_time(${lokiEvents}[5m]))`,
        datasource: LOKI,
        unit: "short",
        decimals: 0,
        x: 12,
        y: 0,
      }),
      statPanel({
        title: "Warning events (5m)",
        expr: `sum(count_over_time(${lokiEvents} |~ "(?i)warning|failed|error" [5m]))`,
        datasource: LOKI,
        unit: "short",
        decimals: 0,
        x: 18,
        y: 0,
      }),
      logsPanel({
        title: "Cluster logs (zoomed)",
        expr: lokiCluster,
        x: 0,
        y: 4,
        w: 24,
        h: 14,
        maxLines: 100,
        timeFrom: "1h",
      }),
      logsPanel({
        title: "Errors and warnings",
        expr: `${lokiCluster} |~ "(?i)error|warn|panic|fail"`,
        x: 0,
        y: 18,
        w: 12,
        h: 12,
        maxLines: 50,
        timeFrom: "1h",
      }),
      logsPanel({
        title: "Kubernetes events",
        expr: lokiEvents,
        x: 12,
        y: 18,
        w: 12,
        h: 12,
        maxLines: 50,
        timeFrom: "1h",
      }),
    ],
  });
}

function buildNetworkDashboard() {
  return dashboard({
    uid: "twinbox-network",
    title: "Twinbox Network",
    description: "Node network traffic, pod traffic, and network policy coverage.",
    tags: ["network", "traffic"],
    panels: [
      statPanel({
        title: "Total RX",
        expr: `sum(rate(node_network_receive_bytes_total${nodeNetworkFilter}[5m]))`,
        unit: "Bps",
        decimals: 2,
        x: 0,
        y: 0,
      }),
      statPanel({
        title: "Total TX",
        expr: `sum(rate(node_network_transmit_bytes_total${nodeNetworkFilter}[5m]))`,
        unit: "Bps",
        decimals: 2,
        x: 6,
        y: 0,
      }),
      statPanel({
        title: "Packet errors",
        expr: `sum(rate(node_network_receive_errs_total${nodeNetworkFilter}[5m])) + sum(rate(node_network_transmit_errs_total${nodeNetworkFilter}[5m])) + sum(rate(node_network_receive_drop_total${nodeNetworkFilter}[5m])) + sum(rate(node_network_transmit_drop_total${nodeNetworkFilter}[5m]))`,
        unit: "ops",
        decimals: 2,
        x: 12,
        y: 0,
      }),
      statPanel({
        title: "Network policies",
        expr: "count(kube_networkpolicy_created)",
        x: 18,
        y: 0,
      }),
      timeSeriesPanel({
        title: "Node RX/TX",
        targets: [
          {
            expr: `sum by (node) (rate(node_network_receive_bytes_total${nodeNetworkFilter}[5m]))`,
            legendFormat: "RX {{node}}",
          },
          {
            expr: `sum by (node) (rate(node_network_transmit_bytes_total${nodeNetworkFilter}[5m]))`,
            legendFormat: "TX {{node}}",
          },
        ],
        unit: "Bps",
        decimals: 2,
        x: 0,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Top pod RX",
        targets: [
          {
            expr: `topk(10, sum by (namespace, pod) (rate(container_network_receive_bytes_total{interface!="lo"}[5m])))`,
            legendFormat: "{{namespace}}/{{pod}}",
          },
        ],
        unit: "Bps",
        decimals: 2,
        x: 12,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Top pod TX",
        targets: [
          {
            expr: `topk(10, sum by (namespace, pod) (rate(container_network_transmit_bytes_total{interface!="lo"}[5m])))`,
            legendFormat: "{{namespace}}/{{pod}}",
          },
        ],
        unit: "Bps",
        decimals: 2,
        x: 0,
        y: 12,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Network policy coverage by namespace",
        targets: [
          {
            expr: "count by (namespace) (kube_networkpolicy_created)",
            legendFormat: "{{namespace}}",
          },
        ],
        unit: "short",
        decimals: 0,
        x: 12,
        y: 12,
        w: 12,
        h: 8,
      }),
    ],
  });
}

function buildTraefikDashboard() {
  return dashboard({
    uid: "twinbox-traefik",
    title: "Twinbox Traefik",
    description: "Ingress request volume, latency, route traffic, and config reload health.",
    tags: ["traefik", "ingress", "edge"],
    timeFrom: "now-12h",
    panels: [
      statPanel({
        title: "Requests / s",
        expr: "sum(rate(traefik_entrypoint_requests_total[5m]))",
        unit: "reqps",
        decimals: 2,
        x: 0,
        y: 0,
      }),
      statPanel({
        title: "4xx / s",
        expr: 'sum(rate(traefik_entrypoint_requests_total{code=~"4.."}[5m]))',
        unit: "reqps",
        decimals: 2,
        x: 6,
        y: 0,
        thresholds: [
          { color: "green", value: null },
          { color: "orange", value: 1 },
          { color: "red", value: 10 },
        ],
      }),
      statPanel({
        title: "5xx / s",
        expr: 'sum(rate(traefik_entrypoint_requests_total{code=~"5.."}[5m]))',
        unit: "reqps",
        decimals: 2,
        x: 12,
        y: 0,
        thresholds: [
          { color: "green", value: null },
          { color: "orange", value: 0.1 },
          { color: "red", value: 1 },
        ],
      }),
      statPanel({
        title: "Reloads total",
        expr: "max(traefik_config_reloads_total)",
        unit: "none",
        decimals: 0,
        x: 18,
        y: 0,
      }),
      timeSeriesPanel({
        title: "Requests by entrypoint",
        targets: [
          {
            expr: "sum by (entrypoint) (rate(traefik_entrypoint_requests_total[5m]))",
            legendFormat: "{{entrypoint}}",
          },
        ],
        unit: "reqps",
        decimals: 2,
        x: 0,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Requests by code",
        targets: [
          {
            expr: "sum by (code) (rate(traefik_entrypoint_requests_total[5m]))",
            legendFormat: "{{code}}",
          },
        ],
        unit: "reqps",
        decimals: 2,
        x: 12,
        y: 4,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "p95 latency by entrypoint",
        targets: [
          {
            expr: "1000 * histogram_quantile(0.95, sum by (le, entrypoint) (rate(traefik_entrypoint_request_duration_seconds_bucket[5m])))",
            legendFormat: "{{entrypoint}}",
          },
        ],
        unit: "ms",
        decimals: 0,
        x: 0,
        y: 12,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Top services by traffic",
        targets: [
          {
            expr: "topk(10, sum by (service) (rate(traefik_service_requests_total[5m])))",
            legendFormat: "{{service}}",
          },
        ],
        unit: "reqps",
        decimals: 2,
        x: 12,
        y: 12,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Top services by 5xx",
        targets: [
          {
            expr: 'topk(10, sum by (service) (rate(traefik_service_requests_total{code=~"5.."}[5m])))',
            legendFormat: "{{service}}",
          },
        ],
        unit: "reqps",
        decimals: 2,
        x: 0,
        y: 20,
        w: 12,
        h: 8,
      }),
      timeSeriesPanel({
        title: "Config reloads / min",
        targets: [
          {
            expr: "sum by (instance) (rate(traefik_config_reloads_total[5m]) * 60)",
            legendFormat: "{{instance}}",
          },
        ],
        unit: "ops",
        decimals: 2,
        x: 12,
        y: 20,
        w: 12,
        h: 8,
      }),
    ],
  });
}

const dashboards = {
  nodes: buildNodesDashboard(),
  workloads: buildWorkloadsDashboard(),
  controlPlane: buildControlPlaneDashboard(),
  storage: buildStorageDashboard(),
  logsEvents: buildLogsEventsDashboard(),
  logsDetail: buildLogsDetailDashboard(),
  network: buildNetworkDashboard(),
  traefik: buildTraefikDashboard(),
};

const dashboardName = process.argv[2];

if (!dashboardName) {
  console.error(`Usage: ${process.argv[1]} <${Object.keys(dashboards).sort().join("|")}>`);
  process.exit(1);
}

const dashboardJson = dashboards[dashboardName];

if (!dashboardJson) {
  console.error(
    `Unknown dashboard "${dashboardName}". Expected one of: ${Object.keys(dashboards)
      .sort()
      .join(", ")}`
  );
  process.exit(1);
}

process.stdout.write(`${JSON.stringify(dashboardJson, null, 2)}\n`);
