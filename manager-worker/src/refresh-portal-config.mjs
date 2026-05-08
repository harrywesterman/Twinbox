import fs from "fs";
import os from "os";
import path from "path";
import { spawnSync } from "child_process";
import YAML from "yaml";

import { loadCatalogDefinitions } from "../../lib/catalog-definitions.mjs";
import { isClusterScopedStep } from "../../lib/step-scope.mjs";
import { buildPortalConfig } from "../../lib/portal-config.mjs";

function parseArgs(argv) {
  const options = {
    workspaceRoot: process.env.WORKSPACE_ROOT || "/opt/twinbox",
    managerDataDir: process.env.MANAGER_DATA_DIR || "/data",
    namespace: "twinbox-portal",
    secretName: "portal-config",
    triggerStepId: "",
    clusterId: "",
    clusterInstanceId: "",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const nextValue = argv[index + 1];

    switch (arg) {
      case "--workspace-root":
        options.workspaceRoot = nextValue;
        index += 1;
        break;
      case "--manager-data-dir":
        options.managerDataDir = nextValue;
        index += 1;
        break;
      case "--namespace":
        options.namespace = nextValue;
        index += 1;
        break;
      case "--configmap-name":
        options.secretName = nextValue;
        index += 1;
        break;
      case "--trigger-step-id":
        options.triggerStepId = nextValue;
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

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function loadYaml(file) {
  return YAML.parse(fs.readFileSync(file, "utf8"));
}

function findCurrentCluster(dataRoot, clusterId) {
  const clustersRoot = path.join(dataRoot, "clusters");
  if (!fs.existsSync(clustersRoot)) {
    return null;
  }

  if (clusterId) {
    return readJsonIfExists(path.join(clustersRoot, `${clusterId}.json`));
  }

  return fs.readdirSync(clustersRoot)
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => readJsonIfExists(path.join(clustersRoot, entry)))
    .filter((cluster) => cluster?.id)
    .sort((left, right) => String(right?.updated_at || right?.created_at || "").localeCompare(String(left?.updated_at || left?.created_at || "")))[0] || null;
}

function readStepStates(dataRoot, steps, clusterScopeId) {
  const stepStateById = new Map();

  for (const step of steps) {
    const scope = isClusterScopedStep(step) ? path.join("clusters", clusterScopeId || "") : "global";
    const file = path.join(dataRoot, "step-state", scope, `${step.id}.json`);
    stepStateById.set(step.id, readJsonIfExists(file));
  }

  return stepStateById;
}

function buildKubectlEnv() {
  const env = { ...process.env };
  const kubeconfig = env.KUBECONFIG_FILE || env.TWINBOX_KUBECONFIG_FILE || env.KUBECONFIG;
  if (!env.KUBECONFIG && kubeconfig) {
    env.KUBECONFIG = kubeconfig;
  }
  return env;
}

function runKubectl(args, { input = undefined, allowFailure = false } = {}) {
  const result = spawnSync("kubectl", args, {
    encoding: "utf8",
    env: buildKubectlEnv(),
    input,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0 && !allowFailure) {
    const stderr = (result.stderr || "").trim();
    throw new Error(`kubectl ${args.join(" ")} failed${stderr ? `: ${stderr}` : ""}`);
  }

  return result;
}

function readInstalledAppIds() {
  let parsed = null;
  try {
    const result = runKubectl(["-n", "argocd", "get", "application", "-o", "json"], { allowFailure: true });
    if (result.status !== 0) {
      return null;
    }
    parsed = JSON.parse(result.stdout || "{}");
  } catch {
    return null;
  }

  const items = Array.isArray(parsed?.items) ? parsed.items : [];
  const installedAppIds = items
    .map((item) => String(item?.metadata?.name || "").trim())
    .filter(Boolean)
    .map((appName) => `install-${appName}`);

  return installedAppIds;
}

function applySecret(namespace, secretName, renderedConfig) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "portal-config-"));
  const configFile = path.join(tempDir, "portal-config.json");
  const secretManifestFile = path.join(tempDir, "portal-config-secret.yaml");
  fs.writeFileSync(configFile, renderedConfig, "utf8");

  try {
    const createResult = runKubectl([
      "-n",
      namespace,
      "create",
      "secret",
      "generic",
      secretName,
      `--from-file=portal-config.json=${configFile}`,
      "--dry-run=client",
      "-o",
      "yaml",
    ]);

    fs.writeFileSync(secretManifestFile, createResult.stdout || "", "utf8");
    runKubectl(["apply", "--validate=false", "-f", secretManifestFile]);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const { steps } = loadCatalogDefinitions({
    workspaceRoot: options.workspaceRoot,
    includeApps: true,
    loadYamlFn: loadYaml,
  });
  const appStepIds = new Set(
    steps
      .filter((step) => step?.category_id === "apps")
      .map((step) => step.id),
  );
  const currentCluster = findCurrentCluster(options.managerDataDir, options.clusterId);
  if (!currentCluster?.id) {
    throw new Error("could not determine current cluster for portal config generation");
  }

  const clusterScopeId = options.clusterInstanceId || currentCluster.cluster_instance_id || currentCluster.instance_id || currentCluster.id;
  const stepStateById = readStepStates(options.managerDataDir, steps, clusterScopeId);
  const portalStepState = stepStateById.get("install-twinbox-portal");
  if (
    portalStepState &&
    !["succeeded", "configured"].includes(String(portalStepState.status || "")) &&
    options.triggerStepId !== "install-twinbox-portal"
  ) {
    console.log("Portal refresh skipped: install-twinbox-portal is not complete yet");
    return;
  }
  if (!portalStepState && options.triggerStepId !== "install-twinbox-portal") {
    console.log("Portal refresh skipped: install-twinbox-portal is not installed yet");
    return;
  }

  const contentPath = path.join(options.workspaceRoot, "config", "portal", "content.json");
  const content = readJson(contentPath);
  const installedAppIds = readInstalledAppIds();
  const renderedConfig = JSON.stringify(buildPortalConfig({
    steps,
    stepStateById,
    cluster: currentCluster,
    content,
    installedAppIds: installedAppIds === null
      ? Array.from(appStepIds)
      : installedAppIds.filter((stepId) => appStepIds.has(stepId)),
  }), null, 2);

  applySecret(options.namespace, options.secretName, renderedConfig);
  console.log(`Portal config refreshed for ${currentCluster.id}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
