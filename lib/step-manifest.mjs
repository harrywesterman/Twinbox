import { normalizeSecretBundle } from "./secrets/schema.mjs";
import { resolveStepPresentation } from "./step-presentation.mjs";

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function normalizeInputOption(option, file, inputId, index) {
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

  const value =
    option.value !== undefined && option.value !== null && option.value !== ""
      ? String(option.value)
      : option.label !== undefined && option.label !== null && option.label !== ""
        ? String(option.label)
        : "";
  const label =
    option.label !== undefined && option.label !== null && option.label !== ""
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

export function normalizeInputDefinition(input, file) {
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

  if (
    Array.isArray(normalized.options) &&
    normalized.options.length > 0 &&
    normalized.default !== undefined
  ) {
    const allowedValues = new Set(normalized.options.map((option) => String(option.value)));
    if (!allowedValues.has(String(normalized.default))) {
      throw new Error(`default for ${input.id} must match one of its options in ${file}`);
    }
  }

  return normalized;
}

export function normalizeJourneyStage(value, file) {
  if (value === undefined || value === null || value === "") {
    return "setup";
  }

  const normalized = String(value);
  if (normalized === "setup" || normalized === "manage") {
    return normalized;
  }

  throw new Error(`journey_stage must be setup or manage in ${file}`);
}

export function normalizeStepSecrets(secrets, file) {
  if (secrets === undefined || secrets === null) {
    return { env: {}, files: {} };
  }

  if (typeof secrets !== "object" || Array.isArray(secrets)) {
    throw new Error(`secrets must be an object in ${file}`);
  }

  return normalizeSecretBundle(secrets);
}

function normalizeDashyItem(rawItem, file, stepId, index) {
  if (!rawItem || typeof rawItem !== "object" || Array.isArray(rawItem)) {
    throw new Error(`dashy item ${index + 1} must be an object in ${file}`);
  }

  const requiredFields = ["section", "title", "description", "icon"];
  for (const field of requiredFields) {
    if (!trimString(rawItem[field])) {
      throw new Error(`dashy item ${index + 1} missing ${field} in ${file}`);
    }
  }

  const urlTemplate = trimString(rawItem.url_template);
  const outputUrlKey = trimString(rawItem.output_url_key);
  if (!urlTemplate && !outputUrlKey) {
    throw new Error(
      `dashy item ${index + 1} for ${stepId} must define url_template or output_url_key in ${file}`
    );
  }
  if (urlTemplate && outputUrlKey) {
    throw new Error(
      `dashy item ${index + 1} for ${stepId} must not define both url_template and output_url_key in ${file}`
    );
  }
  if (urlTemplate && !/^https?:\/\//i.test(urlTemplate)) {
    throw new Error(`dashy item ${index + 1} url_template must use http(s) in ${file}`);
  }

  return {
    section: String(rawItem.section),
    title: String(rawItem.title),
    description: String(rawItem.description),
    icon: String(rawItem.icon),
    ...(urlTemplate ? { url_template: urlTemplate } : {}),
    ...(outputUrlKey ? { output_url_key: outputUrlKey } : {}),
  };
}

export function normalizeDashyConfig(dashy, file, stepId) {
  if (dashy === undefined || dashy === null) {
    return { items: [] };
  }

  if (!dashy || typeof dashy !== "object" || Array.isArray(dashy)) {
    throw new Error(`dashy must be an object in ${file}`);
  }
  if (!Array.isArray(dashy.items)) {
    throw new Error(`dashy.items must be an array in ${file}`);
  }

  return {
    items: dashy.items.map((item, index) => normalizeDashyItem(item, file, stepId, index)),
  };
}

export function normalizeCategoryManifest(manifest, file) {
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

export function normalizeStepManifest(manifest, file, categoryId) {
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
    dashy: normalizeDashyConfig(manifest.dashy, file, String(manifest.id)),
    inputs: manifest.inputs.map((input) => normalizeInputDefinition(input, file)),
    secrets: normalizeStepSecrets(manifest.secrets, file),
    depends_on: manifest.depends_on.map((dependency) => String(dependency)),
    runner: {
      kind: String(manifest.runner.kind),
      script: String(manifest.runner.script),
    },
  };
}
