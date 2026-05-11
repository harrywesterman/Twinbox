import fs from "fs";
import path from "path";

function normalizeRuntimeEnv(runtimeEnv = process.env) {
  return { ...process.env, ...runtimeEnv };
}

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function safePathComponent(value, label) {
  const trimmed = trimString(value);
  if (!trimmed) {
    throw new Error(`${label} is required`);
  }
  if (trimmed.includes("/") || trimmed.includes("\\") || trimmed.includes("..")) {
    throw new Error(`${label} contains unsafe path characters: ${trimmed}`);
  }
  return trimmed;
}

export function bootstrapRoot(runtimeEnv = process.env) {
  const env = normalizeRuntimeEnv(runtimeEnv);
  return trimString(env.TWINBOX_BOOTSTRAP_DIR) || "/opt/twinbox/bootstrap";
}

export function secretRoot(runtimeEnv = process.env) {
  return path.join(bootstrapRoot(runtimeEnv), "secrets");
}

export function openBaoRoot(runtimeEnv = process.env) {
  return path.join(bootstrapRoot(runtimeEnv), "openbao");
}

export function openBaoSealDir(runtimeEnv = process.env) {
  return path.join(openBaoRoot(runtimeEnv), "seal");
}

export function openBaoInitDir(runtimeEnv = process.env) {
  return path.join(openBaoRoot(runtimeEnv), "init");
}

export function itemPrefix(runtimeEnv = process.env) {
  const env = normalizeRuntimeEnv(runtimeEnv);
  return trimString(env.TWINBOX_SECRET_ITEM_PREFIX) || "twinbox";
}

export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
}

export function ensureParentDir(filePath) {
  ensureDir(path.dirname(filePath));
}

export function readJsonFileIfExists(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

export function readJsonFile(filePath, label = "file") {
  if (!fs.existsSync(filePath)) {
    throw new Error(`${label} not found: ${filePath}`);
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

export function writeJsonFile(filePath, value) {
  ensureParentDir(filePath);
  const tmpPath = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmpPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmpPath, filePath);
}

export function globalSecretPath(runtimeEnv, item) {
  return path.join(
    secretRoot(runtimeEnv),
    "global",
    `${safePathComponent(item, "secret item")}.json`
  );
}

export function clusterSecretDir(runtimeEnv, clusterId, item) {
  return path.join(
    secretRoot(runtimeEnv),
    "cluster",
    safePathComponent(clusterId, "cluster id"),
    safePathComponent(item, "secret item")
  );
}

export function clusterSecretPath(runtimeEnv, clusterId, item, attachment) {
  return path.join(
    clusterSecretDir(runtimeEnv, clusterId, item),
    safePathComponent(attachment, "attachment")
  );
}

export function clusterAttachmentPath(runtimeEnv, clusterId, item, attachment) {
  return clusterSecretPath(runtimeEnv, clusterId, item, attachment);
}

export function resolveSecretRecordPath(runtimeEnv, ref, context = {}) {
  const scope = trimString(ref?.scope || "global");
  const item = safePathComponent(ref?.item, "secret item");
  if (scope === "cluster") {
    const clusterId = safePathComponent(
      ref?.cluster_id || context.clusterId || context.cluster_id,
      "cluster id"
    );
    return path.join(secretRoot(runtimeEnv), "cluster", clusterId, item, "metadata.json");
  }
  return path.join(secretRoot(runtimeEnv), "global", `${item}.json`);
}

export function resolveAttachmentPath(runtimeEnv, ref, context = {}) {
  const scope = trimString(ref?.scope || "global");
  const item = safePathComponent(ref?.item, "secret item");
  const attachment = safePathComponent(ref?.attachment, "attachment");
  if (scope === "cluster") {
    const clusterId = safePathComponent(
      ref?.cluster_id || context.clusterId || context.cluster_id,
      "cluster id"
    );
    return clusterSecretPath(runtimeEnv, clusterId, item, attachment);
  }
  return path.join(secretRoot(runtimeEnv), "global", item, attachment);
}

export function writeFileAtomic(targetPath, contents, mode = 0o600) {
  ensureParentDir(targetPath);
  const tmpPath = `${targetPath}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmpPath, contents, { mode });
  fs.renameSync(tmpPath, targetPath);
}

export function copyFileAtomic(sourcePath, targetPath) {
  if (!fs.existsSync(sourcePath)) {
    throw new Error(`source file not found: ${sourcePath}`);
  }
  ensureParentDir(targetPath);
  const tmpPath = `${targetPath}.tmp-${process.pid}-${Date.now()}`;
  fs.copyFileSync(sourcePath, tmpPath);
  fs.chmodSync(tmpPath, 0o600);
  fs.renameSync(tmpPath, targetPath);
}

function attachmentEntries(dirPath) {
  if (!fs.existsSync(dirPath)) {
    return [];
  }

  return fs
    .readdirSync(dirPath, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
}

function parseItemName(itemName) {
  const parts = String(itemName || "")
    .split("/")
    .map((part) => part.trim())
    .filter(Boolean);

  if (parts.length >= 3 && parts[1] === "global") {
    return {
      scope: "global",
      item: parts.slice(2).join("/"),
    };
  }

  if (parts.length >= 4 && parts[1] === "cluster") {
    return {
      scope: "cluster",
      cluster_id: parts[2],
      item: parts.slice(3).join("/"),
    };
  }

  return {
    scope: "global",
    item: String(itemName || ""),
  };
}

function buildItemFromObject(itemName, rawRecord, attachmentList = []) {
  const record = rawRecord && typeof rawRecord === "object" ? rawRecord : {};
  const login = {};
  if (record.username !== undefined) {
    login.username = String(record.username ?? "");
  }
  if (record.password !== undefined) {
    login.password = String(record.password ?? "");
  }
  const fields = Object.entries(record)
    .filter(([key]) => key !== "username" && key !== "password" && key !== "notes")
    .map(([key, value]) => ({ name: key, value: String(value ?? ""), type: 0 }));

  return {
    id: itemName,
    name: itemName,
    type: 1,
    login: Object.keys(login).length > 0 ? login : undefined,
    notes: record.notes ? String(record.notes) : undefined,
    fields,
    attachments: attachmentList.map((name, index) => ({
      id: `${itemName}:${name}`,
      fileName: name,
      name,
      type: 0,
      order: index,
    })),
  };
}

export function readItemRecord(runtimeEnv, ref, context = {}) {
  const scope = trimString(ref?.scope || "global");
  const item = safePathComponent(ref?.item, "secret item");
  if (scope === "cluster") {
    const clusterId = safePathComponent(
      ref?.cluster_id || context.clusterId || context.cluster_id,
      "cluster id"
    );
    return readJsonFileIfExists(
      path.join(secretRoot(runtimeEnv), "cluster", clusterId, item, "metadata.json")
    );
  }
  return readJsonFileIfExists(globalSecretPath(runtimeEnv, item));
}

export function writeItemRecord(runtimeEnv, ref, value, context = {}) {
  const scope = trimString(ref?.scope || "global");
  const item = safePathComponent(ref?.item, "secret item");
  const record = value && typeof value === "object" ? value : {};

  if (scope === "cluster") {
    const clusterId = safePathComponent(
      ref?.cluster_id || context.clusterId || context.cluster_id,
      "cluster id"
    );
    writeJsonFile(
      path.join(secretRoot(runtimeEnv), "cluster", clusterId, item, "metadata.json"),
      record
    );
    return path.join(secretRoot(runtimeEnv), "cluster", clusterId, item, "metadata.json");
  }

  const filePath = globalSecretPath(runtimeEnv, item);
  writeJsonFile(filePath, record);
  return filePath;
}

export function listItemObjects(runtimeEnv, search, context = {}) {
  const normalized = parseItemName(search);
  const record = readItemRecord(runtimeEnv, normalized, context);
  if (record) {
    const attachmentDir =
      normalized.scope === "cluster"
        ? clusterSecretDir(
            runtimeEnv,
            normalized.cluster_id || context.clusterId || context.cluster_id,
            normalized.item
          )
        : path.join(
            secretRoot(runtimeEnv),
            "global",
            safePathComponent(normalized.item, "secret item")
          );
    return [buildItemFromObject(search, record, attachmentEntries(attachmentDir))];
  }

  return [];
}

export function readAttachment(runtimeEnv, ref, context = {}) {
  return resolveAttachmentPath(runtimeEnv, ref, context);
}

export function writeAttachment(runtimeEnv, ref, sourcePath, context = {}) {
  const targetPath = resolveAttachmentPath(runtimeEnv, ref, context);
  copyFileAtomic(sourcePath, targetPath);
  return targetPath;
}

export function removeAttachment(runtimeEnv, ref, context = {}) {
  const targetPath = resolveAttachmentPath(runtimeEnv, ref, context);
  if (fs.existsSync(targetPath)) {
    fs.unlinkSync(targetPath);
  }
}

export function configureSecretStore() {}

export function logoutSecretSession() {}

export function readSecretSessionStatus() {
  return { status: "filesystem" };
}

export function ensureSecretSession() {
  return readSecretSessionStatus();
}

export function unlockSecretSession(runtimeEnv) {
  const env = normalizeRuntimeEnv(runtimeEnv);
  return trimString(env.TWINBOX_SECRET_SESSION) || "filesystem-session";
}

export function syncSecretStore() {}

export function listSecretItems(runtimeEnv, search, session, context = {}) {
  return listItemObjects(runtimeEnv, search, context);
}

export function getSecretItem(runtimeEnv, itemId, session, context = {}) {
  const items = listSecretItems(runtimeEnv, itemId, session, context);
  return items.find((item) => item.name === itemId) || {};
}

export function getSecretItemTemplate() {
  return { login: { uris: [] }, fields: [], attachments: [] };
}

export function createSecretItem(runtimeEnv, itemJson, session, context = {}) {
  const name = trimString(itemJson?.name);
  if (!name) {
    throw new Error("item name is required");
  }
  const record = {};
  if (itemJson?.login?.username !== undefined) {
    record.username = String(itemJson.login.username ?? "");
  }
  if (itemJson?.login?.password !== undefined) {
    record.password = String(itemJson.login.password ?? "");
  }
  if (itemJson?.notes !== undefined) {
    record.notes = String(itemJson.notes ?? "");
  }
  for (const field of Array.isArray(itemJson?.fields) ? itemJson.fields : []) {
    const fieldName = trimString(field?.name);
    if (!fieldName) continue;
    record[fieldName] = String(field?.value ?? "");
  }

  const ref = parseItemName(name);

  writeItemRecord(runtimeEnv, ref, record, context);
  return buildItemFromObject(name, record);
}

export function editSecretItem(runtimeEnv, itemId, itemJson, session, context = {}) {
  return createSecretItem(runtimeEnv, { ...itemJson, name: itemId }, session, context);
}

export function downloadSecretAttachment(
  runtimeEnv,
  attachmentName,
  itemId,
  outputFile,
  session,
  context = {}
) {
  const ref = {
    ...parseItemName(itemId),
    attachment: attachmentName,
  };

  const sourcePath = resolveAttachmentPath(runtimeEnv, ref, context);
  if (!fs.existsSync(sourcePath)) {
    throw new Error(`attachment not found: ${sourcePath}`);
  }
  ensureParentDir(outputFile);
  fs.copyFileSync(sourcePath, outputFile);
  fs.chmodSync(outputFile, 0o600);
}

export function createSecretAttachment(runtimeEnv, filePath, itemId, session, context = {}) {
  const ref = {
    ...parseItemName(itemId),
    attachment: path.basename(filePath),
  };

  return writeAttachment(runtimeEnv, ref, filePath, context);
}

export function deleteSecretAttachment(runtimeEnv, attachmentId, itemId, session, context = {}) {
  const attachmentName = path.basename(String(attachmentId || ""));
  const ref = {
    ...parseItemName(itemId),
    attachment: attachmentName,
  };

  removeAttachment(runtimeEnv, ref, context);
}
