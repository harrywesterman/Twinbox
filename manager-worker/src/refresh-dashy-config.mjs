import fs from "fs";
import os from "os";
import path from "path";
import { spawnSync } from "child_process";
import YAML from "yaml";

import { loadCatalogDefinitions } from "../../lib/catalog-definitions.mjs";
import { isClusterScopedStep } from "../../lib/step-scope.mjs";
import { buildDashyConfig, stepHasDashyItems } from "../../lib/dashy-config.mjs";

function parseArgs(argv) {
  const options = {
    workspaceRoot: process.env.WORKSPACE_ROOT || "/opt/twinbox",
    managerDataDir: process.env.MANAGER_DATA_DIR || "/data",
    namespace: "dashy",
    configMapName: "dashy-config",
    deploymentName: "dashy",
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
        options.configMapName = nextValue;
        index += 1;
        break;
      case "--deployment-name":
        options.deploymentName = nextValue;
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

  return (
    fs
      .readdirSync(clustersRoot)
      .filter((entry) => entry.endsWith(".json"))
      .map((entry) => readJsonIfExists(path.join(clustersRoot, entry)))
      .filter((cluster) => cluster?.id)
      .sort((left, right) =>
        String(right?.updated_at || right?.created_at || "").localeCompare(
          String(left?.updated_at || left?.created_at || "")
        )
      )[0] || null
  );
}

function readStepStates(dataRoot, steps, clusterScopeId) {
  const stepStateById = new Map();

  for (const step of steps) {
    const scope = isClusterScopedStep(step)
      ? path.join("clusters", clusterScopeId || "")
      : "global";
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

function ensureNamespace(namespace) {
  const namespaceManifest = `apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
`;

  runKubectl(["apply", "-f", "-"], { input: namespaceManifest });
}

function deploymentExists(namespace, deploymentName) {
  const result = runKubectl(["-n", namespace, "get", "deployment", deploymentName], {
    allowFailure: true,
  });
  return result.status === 0;
}

function readCurrentConfigMap(namespace, configMapName) {
  const result = runKubectl(["-n", namespace, "get", "configmap", configMapName, "-o", "json"], {
    allowFailure: true,
  });
  if (result.status !== 0) {
    return "";
  }

  const parsed = JSON.parse(result.stdout || "{}");
  return parsed?.data?.["conf.yml.tpl"] || "";
}

function applyConfigMap(namespace, configMapName, renderedConfig) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "dashy-config-"));
  const configFile = path.join(tempDir, "conf.yml.tpl");
  fs.writeFileSync(configFile, renderedConfig, "utf8");

  try {
    const createResult = runKubectl([
      "-n",
      namespace,
      "create",
      "configmap",
      configMapName,
      `--from-file=conf.yml.tpl=${configFile}`,
      "--dry-run=client",
      "-o",
      "yaml",
    ]);

    runKubectl(["apply", "-f", "-"], { input: createResult.stdout });
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function restartDeployment(namespace, deploymentName) {
  runKubectl(["-n", namespace, "rollout", "restart", `deployment/${deploymentName}`]);
  runKubectl([
    "-n",
    namespace,
    "rollout",
    "status",
    `deployment/${deploymentName}`,
    "--timeout=10m",
  ]);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const { steps } = loadCatalogDefinitions({
    workspaceRoot: options.workspaceRoot,
    includeApps: true,
    loadYamlFn: loadYaml,
  });
  const appStepIds = new Set(
    steps.filter((step) => step?.category_id === "apps").map((step) => step.id)
  );

  const currentCluster = findCurrentCluster(options.managerDataDir, options.clusterId);
  if (!currentCluster?.id) {
    throw new Error("could not determine current cluster for Dashy config generation");
  }

  const clusterScopeId =
    options.clusterInstanceId ||
    currentCluster.cluster_instance_id ||
    currentCluster.instance_id ||
    currentCluster.id;
  const stepStateById = readStepStates(options.managerDataDir, steps, clusterScopeId);

  if (options.triggerStepId) {
    const triggerStep = steps.find((step) => step.id === options.triggerStepId);
    if (!triggerStep) {
      throw new Error(`unknown step: ${options.triggerStepId}`);
    }

    if (appStepIds.has(options.triggerStepId)) {
      console.log(`Dashy refresh skipped: ${options.triggerStepId} is a user app install`);
      return;
    }

    const isDashyBootstrapStep = triggerStep.id === "install-dashy-dashboard";
    const dashyBootstrapState = stepStateById.get("install-dashy-dashboard") || null;
    const dashyBootstrapReady =
      dashyBootstrapState?.status === "succeeded" || dashyBootstrapState?.status === "configured";

    if (!isDashyBootstrapStep && !dashyBootstrapReady) {
      console.log(`Dashy refresh skipped: ${options.triggerStepId} ran before Dashy was installed`);
      return;
    }

    if (!isDashyBootstrapStep && !stepHasDashyItems(triggerStep)) {
      console.log(`Dashy refresh skipped: ${options.triggerStepId} does not declare Dashy items`);
      return;
    }
  }

  const dashyConfig = buildDashyConfig({
    steps,
    stepStateById,
    cluster: currentCluster,
    excludeStepIds: appStepIds,
    workspaceRoot: options.workspaceRoot,
  });
  const renderedConfig = YAML.stringify(dashyConfig);

  ensureNamespace(options.namespace);

  const currentRenderedConfig = readCurrentConfigMap(options.namespace, options.configMapName);
  if (currentRenderedConfig === renderedConfig) {
    console.log("Dashy config unchanged");
    return;
  }

  applyConfigMap(options.namespace, options.configMapName, renderedConfig);
  console.log(`Applied ${options.configMapName} in namespace ${options.namespace}`);

  if (!deploymentExists(options.namespace, options.deploymentName)) {
    console.log(
      `Dashy deployment ${options.deploymentName} not present yet; config applied without rollout`
    );
    return;
  }

  restartDeployment(options.namespace, options.deploymentName);
  console.log(`Dashy deployment ${options.deploymentName} restarted`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
