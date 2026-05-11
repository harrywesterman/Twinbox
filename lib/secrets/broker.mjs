import fs from "fs";
import path from "path";

import {
  bootstrapRoot,
  clusterSecretDir,
  ensureDir,
  globalSecretPath,
  itemPrefix,
  readJsonFileIfExists,
  resolveAttachmentPath,
  writeAttachment,
} from "./filesystem-store.mjs";
import { normalizeSecretBundle, normalizeSecretRef } from "./schema.mjs";

function parseCacheTtlMs(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return 60_000;
  }
  return parsed * 1000;
}

function buildItemName(runtimeEnv, ref, context) {
  const prefix = itemPrefix(runtimeEnv);
  if (ref.scope === "cluster") {
    const clusterId = ref.cluster_id || context.clusterId || context.cluster_id;
    if (!clusterId) {
      throw new Error(`cluster-scoped secret ${ref.item} requires cluster_id`);
    }
    return `${prefix}/cluster/${clusterId}/${ref.item}`;
  }
  return `${prefix}/${ref.scope}/${ref.item}`;
}

function readGlobalRecord(runtimeEnv, item) {
  return readJsonFileIfExists(globalSecretPath(runtimeEnv, item));
}

function readClusterMetadata(runtimeEnv, ref, context = {}) {
  const clusterId = ref.cluster_id || context.clusterId || context.cluster_id;
  if (!clusterId) {
    return null;
  }
  return readJsonFileIfExists(
    path.join(clusterSecretDir(runtimeEnv, clusterId, ref.item), "metadata.json")
  );
}

function readSecretRecord(runtimeEnv, ref, context = {}) {
  if (ref.scope === "cluster") {
    return readClusterMetadata(runtimeEnv, ref, context);
  }
  return readGlobalRecord(runtimeEnv, ref.item);
}

function resolveFieldValue(record, ref) {
  if (!record || typeof record !== "object") {
    return "";
  }

  const aliases = {
    "traefik-dashboard": {
      username: ["username"],
      password: ["password"],
      users: ["users"],
    },
    grafana: {
      "admin-user": ["admin-user", "username"],
      "admin-password": ["admin-password", "password"],
    },
    "wiredoor-gateway": {
      WIREDOOR_URL: ["WIREDOOR_URL", "username", "url"],
      TOKEN: ["TOKEN", "password", "token"],
      username: ["WIREDOOR_URL", "username", "url"],
      password: ["TOKEN", "password", "token"],
    },
  };

  const fieldAliases = aliases[ref.item]?.[ref.field] || [ref.field];
  for (const key of fieldAliases) {
    const value = record[key];
    if (value !== undefined && value !== null && String(value).trim() !== "") {
      return String(value);
    }
  }
  return "";
}

function listAttachmentNames(runtimeEnv, ref, context = {}) {
  const scope = String(ref.scope || "global");
  const clusterId = ref.cluster_id || context.clusterId || context.cluster_id;
  if (scope === "cluster" && clusterId) {
    const dir = clusterSecretDir(runtimeEnv, clusterId, ref.item);
    if (!fs.existsSync(dir)) {
      return [];
    }
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name !== "metadata.json")
      .map((entry) => entry.name)
      .sort();
  }

  const dir = path.join(bootstrapRoot(runtimeEnv), "secrets", "global", ref.item);
  if (!fs.existsSync(dir)) {
    return [];
  }
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
}

function buildItemObject(runtimeEnv, ref, context = {}) {
  const record = readSecretRecord(runtimeEnv, ref, context);
  if (!record) {
    return null;
  }

  const attachments = listAttachmentNames(runtimeEnv, ref, context).map((name, index) => ({
    id: `${buildItemName(runtimeEnv, ref, context)}:${name}`,
    fileName: name,
    name,
    type: 0,
    order: index,
  }));

  const login = {};
  if (record.username !== undefined) {
    login.username = String(record.username);
  }
  if (record.password !== undefined) {
    login.password = String(record.password);
  }

  const fields = Object.entries(record)
    .filter(([key]) => key !== "username" && key !== "password" && key !== "notes")
    .map(([key, value]) => ({ name: key, value: String(value), type: 0 }));

  return {
    id: buildItemName(runtimeEnv, ref, context),
    name: buildItemName(runtimeEnv, ref, context),
    type: 1,
    login: Object.keys(login).length > 0 ? login : undefined,
    notes: record.notes ? String(record.notes) : undefined,
    fields,
    attachments,
  };
}

function ensureWritablePath(targetPath) {
  ensureDir(path.dirname(targetPath));
  return targetPath;
}

export class SecretBroker {
  constructor(runtimeEnv = process.env) {
    this.runtimeEnv = { ...runtimeEnv };
    this.backend = this.runtimeEnv.TWINBOX_SECRET_BACKEND || "filesystem";
    this.cacheTtlMs = parseCacheTtlMs(this.runtimeEnv.TWINBOX_SECRET_CACHE_TTL_SEC);
    this.itemCache = new Map();
  }

  ensureSession() {
    if (this.backend !== "filesystem") {
      throw new Error(`unsupported secret backend: ${this.backend}`);
    }
    return "filesystem-session";
  }

  refreshSession() {
    return this.ensureSession();
  }

  findItem(ref, context = {}) {
    const itemName = buildItemName(this.runtimeEnv, ref, context);
    const cached = this.itemCache.get(itemName);
    if (cached && cached.expiresAt > Date.now()) {
      return cached.value;
    }

    const item = buildItemObject(this.runtimeEnv, ref, context);
    if (item) {
      this.itemCache.set(itemName, {
        value: item,
        expiresAt: Date.now() + this.cacheTtlMs,
      });
    }
    return item;
  }

  getItem(ref, context = {}) {
    const item = this.findItem(ref, context);
    if (!item) {
      throw new Error(`secret item not found: ${buildItemName(this.runtimeEnv, ref, context)}`);
    }
    return item;
  }

  resolveTextRef(rawRef, context = {}) {
    const ref = normalizeSecretRef(rawRef);
    const record = readSecretRecord(this.runtimeEnv, ref, context);
    const value = resolveFieldValue(record, ref);

    if (!value) {
      throw new Error(
        `secret field not found: ${ref.field} on ${buildItemName(this.runtimeEnv, ref, context)}`
      );
    }

    return value;
  }

  materializeRef(rawRef, label, context = {}) {
    const ref = normalizeSecretRef(rawRef);
    const tempRoot =
      this.runtimeEnv.TWINBOX_SECRET_TEMP_DIR ||
      path.join(this.runtimeEnv.MANAGER_DATA_DIR || "/tmp", "twinbox-secrets");

    if (ref.attachment) {
      const attachmentPath = resolveAttachmentPath(this.runtimeEnv, ref, context);
      if (!fs.existsSync(attachmentPath)) {
        throw new Error(`secret attachment not found: ${attachmentPath}`);
      }
      return attachmentPath;
    }

    const value = this.resolveTextRef(ref, context);
    ensureWritablePath(path.join(tempRoot, "noop"));
    const targetDir = fs.mkdtempSync(
      path.join(tempRoot, `${String(label || "secret").replace(/[^a-zA-Z0-9_.-]+/g, "-")}-`)
    );
    const targetFile = path.join(targetDir, "value");
    fs.writeFileSync(targetFile, value, { mode: 0o600 });
    return targetFile;
  }

  upsertAttachment(rawRef, sourceFile, context = {}) {
    const ref = normalizeSecretRef({
      ...rawRef,
      format: rawRef?.format || "file",
    });

    if (!ref.attachment) {
      throw new Error("attachment ref is required for upsert");
    }
    if (!fs.existsSync(sourceFile)) {
      throw new Error(`attachment source file not found: ${sourceFile}`);
    }

    const targetPath = writeAttachment(this.runtimeEnv, ref, sourceFile, context);
    this.itemCache.delete(buildItemName(this.runtimeEnv, ref, context));
    return targetPath;
  }

  resolveBundle(bundleSpec = {}, context = {}) {
    const bundle = normalizeSecretBundle(bundleSpec);
    const env = {};
    const files = {};
    const redactions = [];

    for (const [name, ref] of Object.entries(bundle.env)) {
      try {
        if (ref.format === "file" || ref.attachment) {
          const filePath = this.materializeRef(ref, name, context);
          env[name] = filePath;
          files[name] = filePath;
          continue;
        }

        const value = this.resolveTextRef(ref, context);
        env[name] = value;
        if (name.includes("PASSWORD") || ref.field === "password") {
          redactions.push(value);
        }
      } catch (error) {
        if (ref.optional) {
          continue;
        }
        throw error;
      }
    }

    for (const [name, ref] of Object.entries(bundle.files)) {
      try {
        const filePath = this.materializeRef(ref, name, context);
        env[name] = filePath;
        files[name] = filePath;
      } catch (error) {
        if (ref.optional) {
          continue;
        }
        throw error;
      }
    }

    return {
      env,
      files,
      redactions,
      cleanup() {},
    };
  }
}

export function createSecretBroker(runtimeEnv = process.env) {
  return new SecretBroker(runtimeEnv);
}
