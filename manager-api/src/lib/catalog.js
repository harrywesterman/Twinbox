import fs from "fs";
import path from "path";

import YAML from "yaml";
import {
  normalizeCategoryManifest,
  normalizeStepManifest,
} from "../../../lib/step-manifest.mjs";

import {
  parseIPv4,
  parseIntInRange,
  parseRequiredString,
  readJsonIfExists,
  summarizeJob,
} from "./common.js";

function loadYaml(file) {
  return YAML.parse(fs.readFileSync(file, "utf8"));
}

export function loadCatalogDefinitions({ workspaceRoot }) {
  const categoriesRoot = process.env.TWINBOX_CATEGORIES_DIR || path.join(workspaceRoot, "categories");
  const response = {
    categoriesRoot,
    categories: [],
    stepsById: new Map(),
    errors: [],
  };

  if (!fs.existsSync(categoriesRoot)) {
    response.errors.push(`categories directory not found: ${categoriesRoot}`);
    return response;
  }

  const categoryDirs = fs.readdirSync(categoriesRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);

  for (const categoryDir of categoryDirs) {
    const categoryFile = path.join(categoriesRoot, categoryDir, "category.yaml");
    try {
      const category = normalizeCategoryManifest(loadYaml(categoryFile), categoryFile);
      const stepsRoot = path.join(categoriesRoot, categoryDir, "steps");
      const steps = [];

      if (fs.existsSync(stepsRoot)) {
        const stepDirs = fs.readdirSync(stepsRoot, { withFileTypes: true })
          .filter((entry) => entry.isDirectory())
          .map((entry) => entry.name);

        for (const stepDir of stepDirs) {
          const stepFile = path.join(stepsRoot, stepDir, "step.yaml");
          if (!fs.existsSync(stepFile)) {
            continue;
          }
          const step = normalizeStepManifest(loadYaml(stepFile), stepFile, category.id);
          steps.push(step);
          response.stepsById.set(step.id, step);
        }
      }

      steps.sort((left, right) => left.order - right.order);
      response.categories.push({
        ...category,
        steps,
      });
    } catch (error) {
      response.errors.push(error instanceof Error ? error.message : `failed to load ${categoryFile}`);
    }
  }

  response.categories.sort((left, right) => left.order - right.order);
  return response;
}

function isDone(step, state) {
  if (state?.status === "skipped") return true;
  return step.type === "config"
    ? state?.status === "configured" || state?.status === "succeeded"
    : state?.status === "succeeded";
}

function summarizeStepState(state) {
  if (!state) {
    return {
      status: "not_started",
      inputs: {},
      outputs: null,
      cluster_id: null,
      cluster_instance_id: null,
      error: null,
      updated_at: null,
      last_job_id: null,
    };
  }

  return {
    status: state.status || "not_started",
    inputs: state.inputs || {},
    outputs: state.outputs || null,
    cluster_id: state.cluster_id || null,
    cluster_instance_id: state.cluster_instance_id || null,
    error: state.error || null,
    updated_at: state.updated_at || null,
    last_job_id: state.last_job_id || null,
  };
}

function clusterScopeId(cluster) {
  return cluster?.cluster_instance_id || cluster?.instance_id || cluster?.id || null;
}

function clusterSlug(cluster) {
  return normalizeChoiceValue(cluster?.slug || cluster?.id).toLowerCase();
}

function isPrdCluster(clusterOrSlug) {
  if (typeof clusterOrSlug === "string") {
    return normalizeChoiceValue(clusterOrSlug).toLowerCase() === "prd";
  }

  return clusterSlug(clusterOrSlug) === "prd";
}

function inferClusterSlug(currentCluster, stepStateById, dirs) {
  const directSlug = clusterSlug(currentCluster);
  if (directSlug) {
    return directSlug;
  }

  const candidateStates = [
    stepStateById.get("choose-ingress-route")?.state,
    stepStateById.get("provision-nodes")?.state,
  ];

  for (const state of candidateStates) {
    const candidates = [
      state?.outputs?.cluster_id,
      state?.cluster_id,
      state?.outputs?.cluster_slug,
      state?.cluster_slug,
    ];

    for (const candidate of candidates) {
      const normalized = normalizeChoiceValue(candidate).toLowerCase();
      if (normalized) {
        return normalized;
      }
    }
  }

  const clusterStatesRoot = path.join(dirs.stepState, "clusters");
  if (fs.existsSync(clusterStatesRoot)) {
    const clusterStateDirs = fs.readdirSync(clusterStatesRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(clusterStatesRoot, entry.name))
      .sort((left, right) => {
        const leftStat = fs.statSync(left);
        const rightStat = fs.statSync(right);
        return rightStat.mtimeMs - leftStat.mtimeMs;
      });

    for (const clusterStateDir of clusterStateDirs) {
      const routeState = readJsonIfExists(path.join(clusterStateDir, "choose-ingress-route.json"));
      const candidates = [
        routeState?.outputs?.cluster_id,
        routeState?.cluster_id,
        routeState?.outputs?.cluster_slug,
        routeState?.cluster_slug,
      ];

      for (const candidate of candidates) {
        const normalized = normalizeChoiceValue(candidate).toLowerCase();
        if (normalized) {
          return normalized;
        }
      }

      const provisionState = readJsonIfExists(path.join(clusterStateDir, "provision-nodes.json"));
      const provisionCandidates = [
        provisionState?.outputs?.cluster_id,
        provisionState?.cluster_id,
        provisionState?.outputs?.cluster_slug,
        provisionState?.cluster_slug,
      ];

      for (const candidate of provisionCandidates) {
        const normalized = normalizeChoiceValue(candidate).toLowerCase();
        if (normalized) {
          return normalized;
        }
      }
    }
  }

  return "";
}

function isAllowedIngressRoute(route, currentClusterOrSlug) {
  const normalizedRoute = normalizeChoiceValue(route);
  if (!normalizedRoute) {
    return false;
  }

  if (!currentClusterOrSlug) {
    return true;
  }

  if (normalizedRoute === "cloudflare-tunnel") {
    return isPrdCluster(currentClusterOrSlug);
  }

  return normalizedRoute === "wiredoor"
    || normalizedRoute === "metallb"
    || normalizedRoute === "tailscale";
}

function renderStepForCluster(step, clusterSlugHint) {
  if (step.id !== "choose-ingress-route" || !clusterSlugHint || isPrdCluster(clusterSlugHint)) {
    return step;
  }

  return {
    ...step,
    inputs: step.inputs.map((input) => {
      if (input.id !== "ingress_route" || !Array.isArray(input.options)) {
        return input;
      }

      return {
        ...input,
        options: input.options.filter((option) => option.value !== "cloudflare-tunnel"),
      };
    }),
  };
}

function stepStatePath(dirs, stepId, clusterScope = null) {
  const scope = clusterScope ? path.join("clusters", clusterScope) : "global";
  return path.join(dirs.stepState, scope, `${stepId}.json`);
}

function readStepState(dirs, stepId, clusterScope = null) {
  return readJsonIfExists(stepStatePath(dirs, stepId, clusterScope));
}

function synthesizeProvisionStateFromCluster(step, cluster, state) {
  if (step.id !== "provision-nodes" || state || !cluster?.id) {
    return state;
  }

  const clusterInstanceId = clusterScopeId(cluster);

  if (cluster.status === "bootstrapped" || cluster.status === "provisioned") {
    return {
      status: "succeeded",
      inputs: {},
      outputs: {
        cluster_id: cluster.id,
        cluster_instance_id: clusterInstanceId,
        cluster_status: cluster.status,
      },
      cluster_id: cluster.id,
      cluster_instance_id: clusterInstanceId,
      error: null,
      updated_at: cluster.updated_at || cluster.created_at || null,
      last_job_id: null,
    };
  }

  if (cluster.status === "failed") {
    return {
      status: "failed",
      inputs: {},
      outputs: {
        cluster_id: cluster.id,
        cluster_instance_id: clusterInstanceId,
        cluster_status: cluster.status,
      },
      cluster_id: cluster.id,
      cluster_instance_id: clusterInstanceId,
      error: cluster.last_error || "cluster provisioning failed",
      updated_at: cluster.updated_at || cluster.created_at || null,
      last_job_id: null,
    };
  }

  return state;
}

function deriveStepStatus(step, state, latestJob, completedDependencies) {
  const dependenciesMet = step.depends_on.every((dependency) => completedDependencies.has(dependency));
  if (!dependenciesMet) {
    return "locked";
  }

  if (state?.status === "skipped") {
    return "skipped";
  }

  if (state?.status === "canceled") {
    return "canceled";
  }

  if (latestJob && latestJob.status === "cancel_requested") {
    return "running";
  }

  if (latestJob && latestJob.status === "canceled") {
    return "canceled";
  }

  if (latestJob && (latestJob.status === "pending" || latestJob.status === "running")) {
    return "running";
  }

  if (state?.status === "failed") {
    return "failed";
  }

  if (isDone(step, state)) {
    return "done";
  }

  return "ready";
}

function deriveCategoryStatus(steps) {
  if (steps.some((step) => step.status === "running")) return "running";
  if (steps.some((step) => step.status === "failed")) return "failed";
  if (steps.length > 0 && steps.every((step) => step.status === "done" || step.status === "skipped")) return "done";
  if (steps.every((step) => step.status === "locked")) return "locked";
  return "ready";
}

function normalizeChoiceValue(value) {
  if (value === undefined || value === null) {
    return "";
  }
  return String(value).trim();
}

function extractIngressRouteFromState(state) {
  if (!state) {
    return "";
  }

  const candidates = [
    state?.outputs?.selected_ingress_route,
    state?.outputs?.ingress_route,
    state?.outputs?.ingress_strategy,
    state?.inputs?.ingress_route,
    state?.inputs?.selected_ingress_route,
  ];

  for (const candidate of candidates) {
    const normalized = normalizeChoiceValue(candidate);
    if (normalized) {
      return normalized;
    }
  }

  return "";
}

function determineIngressRoute({ currentCluster, clusterSlugHint, stepStateById, definitions }) {
  const allowedCluster = clusterSlugHint || currentCluster;
  const clusterCandidates = [
    currentCluster?.selected_ingress_route,
    currentCluster?.ingress_route,
    currentCluster?.ingress_strategy,
  ];

  for (const candidate of clusterCandidates) {
    const normalized = normalizeChoiceValue(candidate);
    if (normalized && isAllowedIngressRoute(normalized, allowedCluster)) {
      return normalized;
    }
  }

  const preferredStep = definitions.stepsById.get("choose-ingress-route");
  if (preferredStep) {
    const entry = stepStateById.get("choose-ingress-route");
    const selectedFromChoice = extractIngressRouteFromState(entry?.state);
    if (selectedFromChoice && isAllowedIngressRoute(selectedFromChoice, allowedCluster)) {
      return selectedFromChoice;
    }
  }

  for (const category of definitions.categories) {
    for (const step of category.steps) {
      const selectedFromStep = extractIngressRouteFromState(stepStateById.get(step.id)?.state);
      if (selectedFromStep && isAllowedIngressRoute(selectedFromStep, allowedCluster)) {
        return selectedFromStep;
      }
    }
  }

  return "";
}

function shouldExposeStep(step, activeIngressRoute) {
  if (!step.ingress_route) {
    return true;
  }

  if (!activeIngressRoute) {
    return false;
  }

  return step.ingress_route === activeIngressRoute;
}

export function findCurrentCluster(dirs) {
  if (!fs.existsSync(dirs.clusters)) {
    return null;
  }

  const clusterFiles = fs.readdirSync(dirs.clusters)
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => readJsonIfExists(path.join(dirs.clusters, entry)))
    .filter((cluster) => cluster?.id)
    .sort((left, right) => String(right?.updated_at || right?.created_at || "").localeCompare(String(left?.updated_at || left?.created_at || "")));

  return clusterFiles[0] || null;
}

function findClusterById(dirs, clusterId) {
  if (!clusterId || !fs.existsSync(dirs.clusters)) {
    return null;
  }

  return readJsonIfExists(path.join(dirs.clusters, `${clusterId}.json`));
}

export function buildCatalogResponse({ workspaceRoot, dirs, clusterId = null }) {
  const definitions = loadCatalogDefinitions({ workspaceRoot });
  const currentCluster = clusterId ? findClusterById(dirs, clusterId) : findCurrentCluster(dirs);
  const activeClusterId = currentCluster?.id || null;
  const activeClusterScopeId = clusterScopeId(currentCluster);
  const stepStateById = new Map();
  const renderedStepsById = new Map();

  for (const category of definitions.categories) {
    for (const step of category.steps) {
      const isClusterScopedStep = step.category_id === "talos-cluster";
      const scopedClusterId = isClusterScopedStep ? activeClusterScopeId : null;
      const rawState = readStepState(dirs, step.id, scopedClusterId);
      const state = isClusterScopedStep ? synthesizeProvisionStateFromCluster(step, currentCluster, rawState) : rawState;
      const latestJob = state?.last_job_id
        ? readJsonIfExists(path.join(dirs.jobs, `${state.last_job_id}.json`))
        : null;
      stepStateById.set(step.id, { state, latestJob });
      renderedStepsById.set(step.id, renderStepForCluster(step, ""));
    }
  }

  const clusterSlugHint = inferClusterSlug(currentCluster, stepStateById, dirs);
  for (const [stepId, step] of definitions.stepsById.entries()) {
    if (stepId === "choose-ingress-route") {
      renderedStepsById.set(stepId, renderStepForCluster(step, clusterSlugHint));
    }
  }

  const activeIngressRoute = determineIngressRoute({
    currentCluster,
    clusterSlugHint,
    stepStateById,
    definitions,
  });

  const completedDependencies = new Set(
    Array.from(stepStateById.entries())
      .filter(([stepId, { state }]) => {
        const step = definitions.stepsById.get(stepId);
        return step && isDone(step, state);
      })
      .map(([stepId]) => stepId),
  );

  const categories = definitions.categories.map((category) => {
    const steps = category.steps
      .filter((step) => shouldExposeStep(step, activeIngressRoute))
      .map((step) => {
      const renderedStep = renderedStepsById.get(step.id) || step;
      const { state, latestJob } = stepStateById.get(step.id) || { state: null, latestJob: null };
      const status = deriveStepStatus(renderedStep, state, latestJob, completedDependencies);

      return {
        id: renderedStep.id,
        category_id: renderedStep.category_id,
        title: renderedStep.title,
        type: renderedStep.type,
        journey_stage: renderedStep.journey_stage,
        order: renderedStep.order,
        ingress_route: renderedStep.ingress_route,
        summary: renderedStep.summary,
        explanation: renderedStep.explanation,
        side_help: renderedStep.side_help,
        dashy: renderedStep.dashy,
        inputs: renderedStep.inputs,
        secrets: renderedStep.secrets,
        depends_on: renderedStep.depends_on,
        icon: renderedStep.icon,
        icon_artwork_url: renderedStep.icon_artwork_url,
        project_url: renderedStep.project_url,
        github_url: renderedStep.github_url,
        positive_summary: renderedStep.positive_summary,
        status,
        state: summarizeStepState(state),
        latest_job: summarizeJob(latestJob),
      };
    });

    return {
      id: category.id,
      title: category.title,
      summary: category.summary,
      order: category.order,
      status: deriveCategoryStatus(steps),
      steps,
    };
  });

  return {
    categories,
    errors: definitions.errors,
    stepsById: renderedStepsById,
  };
}

function parseBoolean(value, field) {
  if (typeof value === "boolean") {
    return { ok: true, value };
  }
  if (typeof value === "string" && (value === "true" || value === "false")) {
    return { ok: true, value: value === "true" };
  }
  return { ok: false, error: `${field} must be a boolean` };
}

export function validateStepInputs(step, bodyInputs) {
  const inputs = (bodyInputs && typeof bodyInputs === "object") ? bodyInputs : {};
  const normalized = {};

  for (const input of step.inputs) {
    let value = inputs[input.id];
    const hasValue = value !== undefined && value !== null && value !== "";

    if (!hasValue && input.default !== undefined) {
      value = input.default;
    }

    if ((value === undefined || value === null || value === "") && input.required) {
      return { ok: false, error: `${input.id} is required` };
    }

    if (value === undefined || value === null || value === "") {
      continue;
    }

    if (input.type === "string") {
      const parsed = input.required
        ? parseRequiredString(value, input.id)
        : { ok: true, value: String(value).trim() };
      if (!parsed.ok) return parsed;
      if (Array.isArray(input.options) && input.options.length > 0) {
        const allowedValues = new Set(input.options.map((option) => String(option.value)));
        if (!allowedValues.has(parsed.value)) {
          return { ok: false, error: `${input.id} must be one of: ${Array.from(allowedValues).join(", ")}` };
        }
      }
      normalized[input.id] = parsed.value;
      continue;
    }

    if (input.type === "integer") {
      const parsed = parseIntInRange(value, input.id, input.min ?? Number.MIN_SAFE_INTEGER, input.max ?? Number.MAX_SAFE_INTEGER);
      if (!parsed.ok) return parsed;
      normalized[input.id] = parsed.value;
      continue;
    }

    if (input.type === "ipv4") {
      const parsed = parseIPv4(value, input.id);
      if (!parsed.ok) return parsed;
      normalized[input.id] = parsed.value;
      continue;
    }

    if (input.type === "boolean") {
      const parsed = parseBoolean(value, input.id);
      if (!parsed.ok) return parsed;
      normalized[input.id] = parsed.value;
      continue;
    }

    return { ok: false, error: `unsupported input type for ${input.id}: ${input.type}` };
  }

  return { ok: true, value: normalized };
}
