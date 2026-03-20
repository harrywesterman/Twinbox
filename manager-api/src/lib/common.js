import crypto from "crypto";
import fs from "fs";
import path from "path";

export function now() {
  return new Date().toISOString();
}

export function id(prefix) {
  return `${prefix}_${crypto.randomUUID().replace(/-/g, "")}`;
}

export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

export function writeJson(file, value) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
}

export function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

export function readJsonIfExists(file) {
  if (!fs.existsSync(file)) {
    return null;
  }
  return readJson(file);
}

export function parseIntInRange(value, field, min, max) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) {
    return { ok: false, error: `${field} must be an integer between ${min} and ${max}` };
  }
  return { ok: true, value: n };
}

export function parseRequiredString(value, field) {
  if (typeof value !== "string" || value.trim() === "") {
    return { ok: false, error: `${field} must be a non-empty string` };
  }
  return { ok: true, value: value.trim() };
}

export function parseOptionalString(value, field) {
  if (value === undefined || value === null) {
    return { ok: true, value: "" };
  }
  if (typeof value !== "string") {
    return { ok: false, error: `${field} must be a string` };
  }
  return { ok: true, value: value.trim() };
}

export function parseIPv4(value, field) {
  if (typeof value !== "string") {
    return { ok: false, error: `${field} must be a valid IPv4 address` };
  }
  const parts = value.split(".");
  if (parts.length !== 4) {
    return { ok: false, error: `${field} must be a valid IPv4 address` };
  }

  const valid = parts.every((part) => {
    if (!/^\d+$/.test(part)) {
      return false;
    }
    const n = Number(part);
    return n >= 0 && n <= 255;
  });

  if (!valid) {
    return { ok: false, error: `${field} must be a valid IPv4 address` };
  }

  return { ok: true, value };
}

export function parseIPv4List(value, field) {
  const values = Array.isArray(value)
    ? value.map((entry) => String(entry ?? "").trim()).filter(Boolean)
    : (typeof value === "string"
      ? value.split(",").map((entry) => entry.trim()).filter(Boolean)
      : []);

  if (values.length === 0) {
    return { ok: false, error: `${field} must contain valid IPv4 addresses` };
  }

  for (const entry of values) {
    const parsed = parseIPv4(entry, field);
    if (!parsed.ok) {
      return { ok: false, error: `${field} must contain valid IPv4 addresses` };
    }
  }

  return { ok: true, value: values };
}

export function pickFirstString(value) {
  if (Array.isArray(value)) {
    return typeof value[0] === "string" ? value[0] : "";
  }
  return typeof value === "string" ? value : "";
}

export function buildDataDirs(dataRoot) {
  return {
    clusters: path.join(dataRoot, "clusters"),
    jobs: path.join(dataRoot, "jobs"),
    logs: path.join(dataRoot, "logs"),
    pending: path.join(dataRoot, "queue", "pending"),
    stepState: path.join(dataRoot, "step-state"),
  };
}

export function summarizeJob(job) {
  if (!job) return null;
  return {
    id: job.id,
    type: job.type,
    status: job.status,
    step: job.step,
    error: job.error,
    started_at: job.started_at,
    finished_at: job.finished_at,
    updated_at: job.updated_at,
  };
}
