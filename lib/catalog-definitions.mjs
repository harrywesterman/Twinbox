import fs from "fs";
import path from "path";

import {
  normalizeCategoryManifest,
  normalizeStepManifest,
} from "./step-manifest.mjs";

function normalizeAppBundleManifest(manifest, file) {
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) {
    throw new Error(`bundle manifest must be an object in ${file}`);
  }

  for (const field of ["id", "title", "summary", "order"]) {
    if (manifest?.[field] === undefined || manifest?.[field] === null || manifest?.[field] === "") {
      throw new Error(`missing ${field} in ${file}`);
    }
  }

  if (!Array.isArray(manifest.apps)) {
    throw new Error(`apps must be an array in ${file}`);
  }

  return {
    id: String(manifest.id),
    title: String(manifest.title),
    summary: String(manifest.summary),
    order: Number(manifest.order),
    apps: manifest.apps.map((appId) => String(appId)),
    iconUrl: typeof manifest.iconUrl === "string" ? manifest.iconUrl : "",
    iconAlt: typeof manifest.iconAlt === "string" ? manifest.iconAlt : "",
  };
}

function normalizeAppStepReference(reference, file, index) {
  if (typeof reference === "string" || typeof reference === "number") {
    const id = String(reference).trim();
    if (!id) {
      throw new Error(`empty app step reference ${index + 1} in ${file}`);
    }

    return {
      id,
      overrides: {},
    };
  }

  if (!reference || typeof reference !== "object" || Array.isArray(reference)) {
    throw new Error(`invalid app step reference ${index + 1} in ${file}`);
  }

  const id = reference.id !== undefined && reference.id !== null ? String(reference.id).trim() : "";
  if (!id) {
    throw new Error(`missing app step id ${index + 1} in ${file}`);
  }

  const overrides = { ...reference };
  delete overrides.id;

  return {
    id,
    overrides,
  };
}

function applyStepOverrides(step, overrides) {
  if (!overrides || typeof overrides !== "object" || Array.isArray(overrides)) {
    return step;
  }

  const next = { ...step };
  for (const [key, value] of Object.entries(overrides)) {
    if (key === "runner" && value && typeof value === "object" && !Array.isArray(value)) {
      next.runner = {
        ...step.runner,
        ...value,
      };
      continue;
    }

    next[key] = value;
  }

  return next;
}

function loadReferencedAppStep({ categoriesRoot, categoryId, categoryFile, reference, loadYamlFn }) {
  const appStepFile = path.join(categoriesRoot, "apps", "steps", reference.id, "step.yaml");
  if (!fs.existsSync(appStepFile)) {
    throw new Error(`referenced app step ${reference.id} not found in ${categoryFile}`);
  }

  const step = normalizeStepManifest(loadYamlFn(appStepFile), appStepFile, categoryId);
  return applyStepOverrides(step, reference.overrides);
}

function loadCategorySteps({ categoriesRoot, categoryDir, categoryManifest, categoryFile, loadYamlFn }) {
  const stepsRoot = path.join(categoriesRoot, categoryDir, "steps");
  const stepsById = new Map();

  if (fs.existsSync(stepsRoot)) {
    const stepDirs = fs.readdirSync(stepsRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();

    for (const stepDir of stepDirs) {
      const stepFile = path.join(stepsRoot, stepDir, "step.yaml");
      if (!fs.existsSync(stepFile)) {
        continue;
      }

      const step = normalizeStepManifest(loadYamlFn(stepFile), stepFile, categoryManifest.id);
      stepsById.set(step.id, step);
    }
  }

  const appStepReferences = Array.isArray(categoryManifest.app_steps)
    ? categoryManifest.app_steps
    : [];

  appStepReferences
    .map((reference, index) => normalizeAppStepReference(reference, categoryFile, index))
    .forEach((reference) => {
      const step = loadReferencedAppStep({
        categoriesRoot,
        categoryId: categoryManifest.id,
        categoryFile,
        reference,
        loadYamlFn,
      });
      stepsById.set(step.id, step);
    });

  return Array.from(stepsById.values())
    .sort((left, right) => left.order - right.order || left.id.localeCompare(right.id));
}

function requireLoadYamlFn(loadYamlFn) {
  if (typeof loadYamlFn !== "function") {
    throw new Error("loadCatalogDefinitions requires loadYamlFn");
  }

  return loadYamlFn;
}

export function loadCatalogDefinitions({
  workspaceRoot,
  includeApps = false,
  includeBundles = false,
  loadYamlFn,
} = {}) {
  const loadYaml = requireLoadYamlFn(loadYamlFn);
  const categoriesRoot = process.env.TWINBOX_CATEGORIES_DIR || path.join(workspaceRoot, "categories");
  const response = {
    categoriesRoot,
    categories: [],
    steps: [],
    stepsById: new Map(),
    bundles: [],
    errors: [],
  };

  if (!fs.existsSync(categoriesRoot)) {
    response.errors.push(`categories directory not found: ${categoriesRoot}`);
    return response;
  }

  const categoryDirs = fs.readdirSync(categoriesRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();

  for (const categoryDir of categoryDirs) {
    const categoryFile = path.join(categoriesRoot, categoryDir, "category.yaml");
    try {
      const categoryManifest = loadYaml(categoryFile);
      const category = normalizeCategoryManifest(categoryManifest, categoryFile);
      if (category.id === "apps" && !includeApps) {
        continue;
      }

      const steps = loadCategorySteps({
        categoriesRoot,
        categoryDir,
        categoryManifest: { ...categoryManifest, id: category.id },
        categoryFile,
        loadYamlFn: loadYaml,
      });

      response.categories.push({
        ...category,
        steps,
      });
      response.steps.push(...steps);

      for (const step of steps) {
        if (category.id === "apps" || !response.stepsById.has(step.id)) {
          response.stepsById.set(step.id, step);
        }
      }
    } catch (error) {
      response.errors.push(error instanceof Error ? error.message : `failed to load ${categoryFile}`);
    }
  }

  response.categories.sort((left, right) => left.order - right.order);
  response.steps.sort((left, right) => left.order - right.order || left.id.localeCompare(right.id));

  if (includeBundles) {
    const bundlesRoot = path.join(categoriesRoot, "apps", "bundles");
    if (fs.existsSync(bundlesRoot)) {
      const bundleFiles = fs.readdirSync(bundlesRoot, { withFileTypes: true })
        .filter((entry) => entry.isFile() && entry.name.endsWith(".yaml"))
        .map((entry) => path.join(bundlesRoot, entry.name));

      for (const bundleFile of bundleFiles) {
        try {
          const bundle = normalizeAppBundleManifest(loadYaml(bundleFile), bundleFile);
          response.bundles.push(bundle);
        } catch (error) {
          response.errors.push(error instanceof Error ? error.message : `failed to load ${bundleFile}`);
        }
      }

      response.bundles.sort((left, right) => left.order - right.order);
    }
  }

  return response;
}
