import fs from "fs";
import path from "path";

import YAML from "yaml";
import { normalizeSecretBundle } from "../../../lib/secrets/schema.mjs";
import { resolveStepPresentation } from "../../../lib/step-presentation.mjs";

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

function normalizeInputDefinition(input, file) {
  if (!input || typeof input !== "object") {
    throw new Error(`invalid input definition in ${file}`);
  }

  const requiredFields = ["id", "label", "type"];
  for (const field of requiredFields) {
    if (!input[field]) {
      throw new Error(`missing ${field} in ${file}`);
    }
  }

  const normalized = {
    id: String(input.id),
    label: String(input.label),
    type: String(input.type),
    help: typeof input.help === "string" ? input.help : "",
    required: input.required !== false,
    min: Number.isFinite(Number(input.min)) ? Number(input.min) : undefined,
    max: Number.isFinite(Number(input.max)) ? Number(input.max) : undefined,
    default: input.default,
    options: Array.isArray(input.options)
      ? input.options.map((option, index) => normalizeInputOption(option, file, input.id, index))
      : undefined,
  };

  if (Array.isArray(normalized.options) && normalized.options.length > 0 && normalized.default !== undefined) {
    const allowedValues = new Set(normalized.options.map((option) => String(option.value)));
    if (!allowedValues.has(String(normalized.default))) {
      throw new Error(`default for ${input.id} must match one of its options in ${file}`);
    }
  }

  return normalized;
}

function normalizeInputOption(option, file, inputId, index) {
  if (typeof option === "string" || typeof option === "number" || typeof option === "boolean") {
    const value = String(option);
    return {
      label: value,
      value,
    };
  }

  if (!option || typeof option !== "object") {
    throw new Error(`invalid option ${index + 1} for ${inputId} in ${file}`);
  }

  const value = option.value !== undefined && option.value !== null && option.value !== ""
    ? String(option.value)
    : (option.label !== undefined && option.label !== null && option.label !== ""
      ? String(option.label)
      : "");
  const label = option.label !== undefined && option.label !== null && option.label !== ""
    ? String(option.label)
    : value;

  if (!value) {
    throw new Error(`missing option value ${index + 1} for ${inputId} in ${file}`);
  }

  return {
    label: label || value,
    value,
  };
}

function normalizeJourneyStage(value, file) {
  if (value === undefined || value === null || value === "") {
    return "setup";
  }

  const normalized = String(value);
  if (normalized === "setup" || normalized === "manage") {
    return normalized;
  }

  throw new Error(`journey_stage must be setup or manage in ${file}`);
}

function normalizeStepSecrets(secrets, file) {
  if (secrets === undefined || secrets === null) {
    return { env: {}, files: {} };
  }

  if (typeof secrets !== "object" || Array.isArray(secrets)) {
    throw new Error(`secrets must be an object in ${file}`);
  }

  return normalizeSecretBundle(secrets);
}

function normalizeCategoryManifest(manifest, file) {
  const requiredFields = ["id", "title", "summary", "order"];
  for (const field of requiredFields) {
    if (manifest?.[field] === undefined || manifest?.[field] === null || manifest?.[field] === "") {
      throw new Error(`missing ${field} in ${file}`);
    }
  }

  return {
    id: String(manifest.id),
    title: String(manifest.title),
    summary: String(manifest.summary),
    order: Number(manifest.order),
  };
}

function normalizeStepManifest(manifest, file, categoryId) {
  const requiredFields = [
    "id",
    "title",
    "type",
    "order",
    "summary",
    "explanation",
    "side_help",
    "inputs",
    "depends_on",
    "runner",
  ];
  for (const field of requiredFields) {
    if (manifest?.[field] === undefined || manifest?.[field] === null) {
      throw new Error(`missing ${field} in ${file}`);
    }
  }

  if (!Array.isArray(manifest.inputs)) {
    throw new Error(`inputs must be an array in ${file}`);
  }

  if (!Array.isArray(manifest.depends_on)) {
    throw new Error(`depends_on must be an array in ${file}`);
  }

  if (!manifest.runner?.kind || !manifest.runner?.script) {
    throw new Error(`runner.kind and runner.script are required in ${file}`);
  }

  const journeyStage = normalizeJourneyStage(manifest.journey_stage, file);
  const presentation = resolveStepPresentation({
    id: String(manifest.id),
    title: String(manifest.title),
    summary: String(manifest.summary),
    journey_stage: journeyStage,
    type: String(manifest.type),
    icon: manifest.icon,
    project_url: manifest.project_url,
    github_url: manifest.github_url,
    positive_summary: manifest.positive_summary,
  });

  return {
    id: String(manifest.id),
    category_id: categoryId,
    title: String(manifest.title),
    type: String(manifest.type),
    journey_stage: journeyStage,
    order: Number(manifest.order),
    ingress_route: typeof manifest.ingress_route === "string" ? manifest.ingress_route : "",
    summary: String(manifest.summary),
    explanation: String(manifest.explanation),
    side_help: String(manifest.side_help),
    ...presentation,
    inputs: manifest.inputs.map((input) => normalizeInputDefinition(input, file)),
    secrets: normalizeStepSecrets(manifest.secrets, file),
    depends_on: manifest.depends_on.map((dependency) => String(dependency)),
    runner: {
      kind: String(manifest.runner.kind),
      script: String(manifest.runner.script),
    },
  };
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

function isPrdCluster(cluster) {
  return clusterSlug(cluster) === "prd";
}

function isAllowedIngressRoute(route, currentCluster) {
  const normalizedRoute = normalizeChoiceValue(route);
  if (!normalizedRoute) {
    return false;
  }

  if (!currentCluster) {
    return true;
  }

  if (normalizedRoute === "cloudflare-tunnel") {
    return isPrdCluster(currentCluster);
  }

  return normalizedRoute === "wiredoor"
    || normalizedRoute === "metallb"
    || normalizedRoute === "tailscale";
}

function renderStepForCluster(step, currentCluster) {
  if (step.id !== "choose-ingress-route" || !currentCluster || isPrdCluster(currentCluster)) {
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

function determineIngressRoute({ currentCluster, stepStateById, definitions }) {
  const clusterCandidates = [
    currentCluster?.selected_ingress_route,
    currentCluster?.ingress_route,
    currentCluster?.ingress_strategy,
  ];

  for (const candidate of clusterCandidates) {
    const normalized = normalizeChoiceValue(candidate);
    if (normalized && isAllowedIngressRoute(normalized, currentCluster)) {
      return normalized;
    }
  }

  const preferredStep = definitions.stepsById.get("choose-ingress-route");
  if (preferredStep) {
    const entry = stepStateById.get("choose-ingress-route");
    const selectedFromChoice = extractIngressRouteFromState(entry?.state);
    if (selectedFromChoice && isAllowedIngressRoute(selectedFromChoice, currentCluster)) {
      return selectedFromChoice;
    }
  }

  for (const category of definitions.categories) {
    for (const step of category.steps) {
      const selectedFromStep = extractIngressRouteFromState(stepStateById.get(step.id)?.state);
      if (selectedFromStep && isAllowedIngressRoute(selectedFromStep, currentCluster)) {
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
      renderedStepsById.set(step.id, renderStepForCluster(step, currentCluster));
    }
  }

  const activeIngressRoute = determineIngressRoute({
    currentCluster,
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
