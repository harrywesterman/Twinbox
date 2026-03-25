import fs from "fs";
import os from "os";
import path from "path";

import {
  configureBitwardenServer,
  downloadBitwardenAttachment,
  ensureBitwardenLogin,
  listBitwardenItems,
  syncBitwarden,
  unlockBitwarden,
} from "./bitwarden-cli.mjs";
import { normalizeSecretBundle, normalizeSecretRef } from "./schema.mjs";

function parseCacheTtlMs(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return 60_000;
  }
  return parsed * 1000;
}

function buildItemName(runtimeEnv, ref, context) {
  const prefix = runtimeEnv.VAULTWARDEN_ITEM_PREFIX || "twinbox";
  if (ref.scope === "cluster") {
    const clusterId = ref.cluster_id || context.clusterId || context.cluster_id;
    if (!clusterId) {
      throw new Error(`cluster-scoped secret ${ref.item} requires cluster_id`);
    }
    return `${prefix}/cluster/${clusterId}/${ref.item}`;
  }
  return `${prefix}/${ref.scope}/${ref.item}`;
}

function findCustomField(item, fieldName) {
  const fields = Array.isArray(item?.fields) ? item.fields : [];
  return fields.find((field) => String(field?.name || "").trim() === fieldName)?.value || "";
}

function resolveItemTextValue(item, ref) {
  if (ref.field === "username") {
    return String(item?.login?.username || "");
  }
  if (ref.field === "password") {
    return String(item?.login?.password || "");
  }
  if (ref.field === "notes") {
    return String(item?.notes || "");
  }
  return String(findCustomField(item, ref.field) || "");
}

function envValueForRef(ref, runtimeEnv) {
  if (ref.item !== "proxmox") {
    throw new Error(`env secret backend does not support item: ${ref.item}`);
  }

  const host = String(runtimeEnv.PROXMOX_HOST || "");
  const port = String(runtimeEnv.PROXMOX_PORT || "8006");
  const username = String(runtimeEnv.PROXMOX_USER || "");
  const password = String(runtimeEnv.PROXMOX_PASSWORD || "");

  const valueMap = {
    host,
    port,
    username,
    password,
    endpoint: host ? `https://${host}:${port}` : "",
  };

  const value = valueMap[ref.field];
  if (!value) {
    throw new Error(`missing ${ref.field} for env-backed proxmox secret`);
  }
  return value;
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
}

function materializeTextSecret(tempRoot, label, value) {
  ensureDir(tempRoot);
  const safeLabel = String(label || "secret").replace(/[^a-zA-Z0-9_.-]+/g, "-");
  const tempDir = fs.mkdtempSync(path.join(tempRoot, `${safeLabel}-`));
  const targetFile = path.join(tempDir, "value");
  fs.writeFileSync(targetFile, value, { mode: 0o600 });
  return targetFile;
}

export class SecretBroker {
  constructor(runtimeEnv = process.env) {
    this.runtimeEnv = { ...runtimeEnv };
    this.backend = this.runtimeEnv.TWINBOX_SECRET_BACKEND || "env";
    this.cacheTtlMs = parseCacheTtlMs(this.runtimeEnv.TWINBOX_SECRET_CACHE_TTL_SEC);
    this.itemCache = new Map();
    this.sessionCache = null;
  }

  ensureVaultwardenReady() {
    const readyFile = this.runtimeEnv.VAULTWARDEN_READY_FILE;
    if (readyFile && !fs.existsSync(readyFile)) {
      throw new Error(`Vaultwarden bootstrap is incomplete: missing ${readyFile}`);
    }
  }

  ensureSession() {
    if (this.sessionCache && this.sessionCache.expiresAt > Date.now()) {
      return this.sessionCache.value;
    }

    this.ensureVaultwardenReady();
    const serverUrl = this.runtimeEnv.VAULTWARDEN_SERVER_URL || "http://vaultwarden:80";
    ensureBitwardenLogin(this.runtimeEnv, serverUrl);
    configureBitwardenServer(this.runtimeEnv, serverUrl);
    const session = unlockBitwarden(this.runtimeEnv);
    syncBitwarden(this.runtimeEnv, session);
    this.sessionCache = {
      value: session,
      expiresAt: Date.now() + this.cacheTtlMs,
    };
    return session;
  }

  getItem(ref, context = {}) {
    const itemName = buildItemName(this.runtimeEnv, ref, context);
    const cached = this.itemCache.get(itemName);
    if (cached && cached.expiresAt > Date.now()) {
      return cached.value;
    }

    const session = this.ensureSession();
    const items = listBitwardenItems(this.runtimeEnv, itemName, session);
    const item = items.find((candidate) => String(candidate?.name || "") === itemName);
    if (!item) {
      throw new Error(`Vaultwarden item not found: ${itemName}`);
    }

    this.itemCache.set(itemName, {
      value: item,
      expiresAt: Date.now() + this.cacheTtlMs,
    });
    return item;
  }

  resolveTextRef(rawRef, context = {}) {
    const ref = normalizeSecretRef(rawRef);
    if (this.backend === "env") {
      return envValueForRef(ref, this.runtimeEnv);
    }
    if (this.backend !== "vaultwarden") {
      throw new Error(`unsupported secret backend: ${this.backend}`);
    }

    const item = this.getItem(ref, context);
    const value = resolveItemTextValue(item, ref);
    if (!value) {
      throw new Error(`Vaultwarden field not found: ${ref.field} on ${buildItemName(this.runtimeEnv, ref, context)}`);
    }
    return value;
  }

  materializeRef(rawRef, label, context = {}) {
    const ref = normalizeSecretRef(rawRef);
    const tempRoot = this.runtimeEnv.TWINBOX_SECRET_TEMP_DIR || path.join(os.tmpdir(), "twinbox-secrets");

    if (ref.attachment) {
      if (this.backend === "env") {
        throw new Error("env secret backend does not support attachments");
      }
      const item = this.getItem(ref, context);
      const targetDir = fs.mkdtempSync(path.join(tempRoot, `${label}-`));
      const targetFile = path.join(targetDir, ref.attachment);
      downloadBitwardenAttachment(this.runtimeEnv, ref.attachment, item.id, targetFile, this.ensureSession());
      return targetFile;
    }

    const value = this.resolveTextRef(ref, context);
    return materializeTextSecret(tempRoot, label, value);
  }

  resolveBundle(bundleSpec = {}, context = {}) {
    const bundle = normalizeSecretBundle(bundleSpec);
    const env = {};
    const files = {};
    const cleanupTargets = [];
    const redactions = [];

    for (const [name, ref] of Object.entries(bundle.env)) {
      if (ref.format === "file" || ref.attachment) {
        const filePath = this.materializeRef(ref, name, context);
        env[name] = filePath;
        files[name] = filePath;
        cleanupTargets.push(path.dirname(filePath));
        continue;
      }

      const value = this.resolveTextRef(ref, context);
      env[name] = value;
      if (name.includes("PASSWORD") || ref.field === "password") {
        redactions.push(value);
      }
    }

    for (const [name, ref] of Object.entries(bundle.files)) {
      const filePath = this.materializeRef(ref, name, context);
      env[name] = filePath;
      files[name] = filePath;
      cleanupTargets.push(path.dirname(filePath));
    }

    return {
      env,
      files,
      redactions,
      cleanup() {
        for (const target of cleanupTargets) {
          fs.rmSync(target, { recursive: true, force: true });
        }
      },
    };
  }
}

export function createSecretBroker(runtimeEnv = process.env) {
  return new SecretBroker(runtimeEnv);
}
