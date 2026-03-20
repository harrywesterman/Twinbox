import fs from "fs";
import path from "path";

import YAML from "yaml";

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

  return {
    id: String(input.id),
    label: String(input.label),
    type: String(input.type),
    help: typeof input.help === "string" ? input.help : "",
    required: input.required !== false,
    min: Number.isFinite(Number(input.min)) ? Number(input.min) : undefined,
    max: Number.isFinite(Number(input.max)) ? Number(input.max) : undefined,
    default: input.default,
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

  return {
    id: String(manifest.id),
    category_id: categoryId,
    title: String(manifest.title),
    type: String(manifest.type),
    journey_stage: normalizeJourneyStage(manifest.journey_stage, file),
    order: Number(manifest.order),
    summary: String(manifest.summary),
    explanation: String(manifest.explanation),
    side_help: String(manifest.side_help),
    inputs: manifest.inputs.map((input) => normalizeInputDefinition(input, file)),
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
    error: state.error || null,
    updated_at: state.updated_at || null,
    last_job_id: state.last_job_id || null,
  };
}

function deriveStepStatus(step, state, latestJob, completedDependencies) {
  const dependenciesMet = step.depends_on.every((dependency) => completedDependencies.has(dependency));
  if (!dependenciesMet) {
    return "locked";
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
  if (steps.length > 0 && steps.every((step) => step.status === "done")) return "done";
  if (steps.every((step) => step.status === "locked")) return "locked";
  return "ready";
}

function findActiveClusterId(dirs) {
  if (!fs.existsSync(dirs.clusters)) {
    return null;
  }

  const clusterFiles = fs.readdirSync(dirs.clusters)
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => readJsonIfExists(path.join(dirs.clusters, entry)))
    .filter(Boolean);

  const inProgress = clusterFiles
    .filter((cluster) => cluster?.id && cluster?.status && cluster.status !== "bootstrapped")
    .sort((left, right) => String(right?.updated_at || "").localeCompare(String(left?.updated_at || "")));

  return inProgress[0]?.id || null;
}

export function buildCatalogResponse({ workspaceRoot, dirs }) {
  const definitions = loadCatalogDefinitions({ workspaceRoot });
  const completedDependencies = new Set();
  const activeClusterId = findActiveClusterId(dirs);

  const categories = definitions.categories.map((category) => {
    const steps = category.steps.map((step) => {
      const rawState = readJsonIfExists(path.join(dirs.stepState, `${step.id}.json`));
      const isClusterScopedStep = step.category_id === "talos-cluster";
      const state = isClusterScopedStep && rawState?.cluster_id !== activeClusterId ? null : rawState;
      const latestJob = state?.last_job_id
        ? readJsonIfExists(path.join(dirs.jobs, `${state.last_job_id}.json`))
        : null;
      const status = deriveStepStatus(step, state, latestJob, completedDependencies);

      if (status === "done") {
        completedDependencies.add(step.id);
      }

      return {
        id: step.id,
        category_id: step.category_id,
        title: step.title,
        type: step.type,
        journey_stage: step.journey_stage,
        order: step.order,
        summary: step.summary,
        explanation: step.explanation,
        side_help: step.side_help,
        inputs: step.inputs,
        depends_on: step.depends_on,
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
    stepsById: definitions.stepsById,
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
