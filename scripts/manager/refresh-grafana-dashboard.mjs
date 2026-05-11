#!/usr/bin/env node
import fs from "fs";
import os from "os";
import path from "path";
import { spawnSync } from "child_process";

const DASHBOARD_URL = "https://grafana.com/api/dashboards/24155/revisions/1/download";
const DASHBOARD_CONFIGMAP_NAME = "managed-kubernetes-overview-dashboard";
const DASHBOARD_FILE_KEY = "managed-kubernetes-overview.json";
const DASHBOARD_NAMESPACE = "monitoring";
const OBSOLETE_DASHBOARD_CONFIGMAPS = [
  "kubernetes-overview-dashboard",
  "kubernetes-dashboard",
  "node-exporter-full-dashboard",
  "longhorn-dashboard",
  "cilium-metrics-dashboard",
  "hubble-metrics-dashboard",
  "loki-dashboard",
  "cilium-network-monitoring-dashboard",
];

function now() {
  return new Date().toISOString();
}

function log(message) {
  console.log(`[${now()}] ${message}`);
}

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const options = {
    managerDataDir: process.env.MANAGER_DATA_DIR || "/data",
    clusterId: process.env.TWINBOX_CLUSTER_ID || process.env.CLUSTER_ID || "",
    clusterInstanceId:
      process.env.TWINBOX_CLUSTER_INSTANCE_ID || process.env.CLUSTER_INSTANCE_ID || "",
    triggerStepId: process.env.STEP_ID || process.env.TRIGGER_STEP_ID || "",
    namespace: DASHBOARD_NAMESPACE,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = argv[index + 1];

    switch (arg) {
      case "--manager-data-dir":
        options.managerDataDir = nextValue;
        index += 1;
        break;
      case "--cluster-id":
        options.clusterId = nextValue;
        index += 1;
        break;
      case "--cluster-instance-id":
        options.clusterInstanceId = nextValue;
        index += 1;
        break;
      case "--trigger-step-id":
        options.triggerStepId = nextValue;
        index += 1;
        break;
      case "--namespace":
        options.namespace = nextValue;
        index += 1;
        break;
      default:
        throw new Error(`unsupported argument: ${arg}`);
    }
  }

  return options;
}

function readJsonIfExists(file) {
  if (!fs.existsSync(file)) {
    return null;
  }

  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function findClusterById(dataRoot, clusterId) {
  if (!clusterId) {
    return null;
  }

  return readJsonIfExists(path.join(dataRoot, "clusters", `${clusterId}.json`));
}

function findCurrentCluster(dataRoot) {
  const clustersRoot = path.join(dataRoot, "clusters");
  if (!fs.existsSync(clustersRoot)) {
    return null;
  }

  const clusterFiles = fs
    .readdirSync(clustersRoot)
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => readJsonIfExists(path.join(clustersRoot, entry)))
    .filter((cluster) => cluster?.id)
    .sort((left, right) =>
      String(right?.updated_at || right?.created_at || "").localeCompare(
        String(left?.updated_at || left?.created_at || "")
      )
    );

  return clusterFiles[0] || null;
}

function clusterScopeId(cluster = null, fallback = null) {
  return cluster?.cluster_instance_id || cluster?.instance_id || fallback || cluster?.id || null;
}

function stepStatePath(dataRoot, stepId, clusterScope = null) {
  const scope = clusterScope ? path.join("clusters", clusterScope) : "global";
  return path.join(dataRoot, "step-state", scope, `${stepId}.json`);
}

function readStepState(dataRoot, stepId, clusterScope = null) {
  return readJsonIfExists(stepStatePath(dataRoot, stepId, clusterScope));
}

function buildKubectlEnv() {
  const env = { ...process.env };
  const kubeconfig = env.KUBECONFIG_FILE || env.TWINBOX_KUBECONFIG_FILE || env.KUBECONFIG;

  if (!kubeconfig) {
    throw new Error("kubeconfig file is required");
  }

  if (!fs.existsSync(kubeconfig)) {
    throw new Error(`kubeconfig not found at ${kubeconfig}`);
  }

  env.KUBECONFIG = kubeconfig;
  return env;
}

function runKubectl(args, { input = undefined } = {}) {
  const result = spawnSync("kubectl", args, {
    encoding: "utf8",
    env: buildKubectlEnv(),
    input,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const stderr = (result.stderr || "").trim();
    const stdout = (result.stdout || "").trim();
    throw new Error(
      `kubectl ${args.join(" ")} failed${stderr ? `: ${stderr}` : stdout ? `: ${stdout}` : ""}`
    );
  }

  return result.stdout || "";
}

function fetchDashboardJson(url) {
  const result = spawnSync("curl", ["-fsSL", url], {
    encoding: "utf8",
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const stderr = (result.stderr || "").trim();
    const stdout = (result.stdout || "").trim();
    throw new Error(`curl ${url} failed${stderr ? `: ${stderr}` : stdout ? `: ${stdout}` : ""}`);
  }

  return JSON.parse(result.stdout || "{}");
}

function rewriteDashboardStrings(value) {
  const replacements = new Map([
    ["${DS_MK8S}", "Prometheus"],
    ["${datasource}", "Prometheus"],
    ["${VAR_JOB}", "node-exporter"],
  ]);
  const substitutions = [['cluster_name="$cluster"', 'cluster_name=~".*"']];

  if (Array.isArray(value)) {
    return value.map((entry) => rewriteDashboardStrings(entry));
  }

  if (value && typeof value === "object") {
    const next = {};
    for (const [key, entry] of Object.entries(value)) {
      next[key] = rewriteDashboardStrings(entry);
    }

    if (next.name === "datasource") {
      next.regex = ".*";
      next.current = {
        selected: true,
        text: "Prometheus",
        value: "Prometheus",
      };
    }

    if (next.name === "job") {
      next.current = {
        selected: false,
        text: "node-exporter",
        value: "node-exporter",
      };
      next.options = [
        {
          selected: false,
          text: "node-exporter",
          value: "node-exporter",
        },
      ];
      next.query = "node-exporter";
    }

    return next;
  }

  if (typeof value === "string") {
    let next = value;
    for (const [from, to] of substitutions) {
      next = next.split(from).join(to);
    }

    return replacements.get(next) || next;
  }

  return value;
}

function ensureNamespace(namespace) {
  const manifest = `apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
`;

  runKubectl(["apply", "-f", "-"], { input: manifest });
}

function deleteObsoleteDashboardConfigMaps(namespace) {
  for (const configmapName of OBSOLETE_DASHBOARD_CONFIGMAPS) {
    runKubectl(["-n", namespace, "delete", "configmap", configmapName, "--ignore-not-found=true"]);
  }
}

function applyManagedOverviewDashboard(namespace, dashboard) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "grafana-dashboard-"));
  const dashboardFile = path.join(tempDir, DASHBOARD_FILE_KEY);
  fs.writeFileSync(dashboardFile, `${JSON.stringify(dashboard, null, 2)}\n`, "utf8");

  try {
    const createResult = spawnSync(
      "kubectl",
      [
        "-n",
        namespace,
        "create",
        "configmap",
        DASHBOARD_CONFIGMAP_NAME,
        `--from-file=${DASHBOARD_FILE_KEY}=${dashboardFile}`,
        "--dry-run=client",
        "-o",
        "yaml",
      ],
      {
        encoding: "utf8",
        env: buildKubectlEnv(),
      }
    );

    if (createResult.error) {
      throw createResult.error;
    }

    if (createResult.status !== 0) {
      const stderr = (createResult.stderr || "").trim();
      const stdout = (createResult.stdout || "").trim();
      throw new Error(
        `kubectl create configmap ${DASHBOARD_CONFIGMAP_NAME} failed${stderr ? `: ${stderr}` : stdout ? `: ${stdout}` : ""}`
      );
    }

    runKubectl(["apply", "--server-side", "--field-manager=grafana-dashboard", "-f", "-"], {
      input: createResult.stdout,
    });

    runKubectl([
      "-n",
      namespace,
      "label",
      "configmap",
      DASHBOARD_CONFIGMAP_NAME,
      "grafana_dashboard=1",
      "app.kubernetes.io/name=grafana",
      "--overwrite",
    ]);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function shouldRefreshDashboard(triggerStepId, stepState) {
  if (triggerStepId === "install-grafana") {
    return true;
  }

  return ["succeeded", "configured"].includes(String(stepState?.status || ""));
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const currentCluster =
    findClusterById(options.managerDataDir, options.clusterId) ||
    findCurrentCluster(options.managerDataDir);

  if (!currentCluster?.id && !options.clusterId) {
    fail("could not determine current cluster for Grafana dashboard refresh");
  }

  const cluster = currentCluster || {
    id: options.clusterId,
    cluster_instance_id: options.clusterInstanceId || options.clusterId,
  };
  const clusterInstanceId = options.clusterInstanceId || clusterScopeId(cluster, options.clusterId);
  const installGrafanaState = readStepState(
    options.managerDataDir,
    "install-grafana",
    clusterInstanceId || null
  );

  if (!shouldRefreshDashboard(options.triggerStepId, installGrafanaState)) {
    log("Grafana dashboard refresh skipped: install-grafana is not installed yet");
    return;
  }

  log("Refreshing managed-kubernetes-overview dashboard");
  ensureNamespace(options.namespace);
  deleteObsoleteDashboardConfigMaps(options.namespace);

  const dashboard = fetchDashboardJson(DASHBOARD_URL);
  const rewrittenDashboard = rewriteDashboardStrings(dashboard);
  applyManagedOverviewDashboard(options.namespace, rewrittenDashboard);
  log("Grafana dashboard refresh complete");
}

try {
  main();
} catch (error) {
  console.error(
    `[${now()}] ERROR: ${error instanceof Error ? error.message : String(error || "unknown error")}`
  );
  process.exit(1);
}
