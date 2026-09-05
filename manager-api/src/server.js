import express from "express";
import fs from "fs";
import path from "path";
import { spawnSync } from "child_process";

import {
  buildApplyJobPayload,
  buildBootstrapPayload,
  buildClusterFromRequest,
  ensureClusterResourceProfile,
  loadCluster,
  normalizeClusterName,
  normalizeClusterSlug,
  normalizeObservabilityProfile,
  persistCluster,
} from "./lib/clusters.js";
import { buildClusterPressureSummary } from "./lib/cluster-pressure.js";
import { normalizeStorageResource, validateProxmoxCapacity } from "./lib/proxmox-capacity.js";
import { computePlacement } from "./lib/placement.js";
import { backupHosts, reservedBackupIps, suggestBackupIp } from "../../lib/backup-placement.mjs";
import {
  buildAppCatalogResponse,
  buildCatalogResponse,
  partitionStepInputs,
  validateStepInputs,
} from "./lib/catalog.js";
import {
  buildDataDirs,
  buildDataFiles,
  ensureDir,
  now,
  parseIPv4,
  pickFirstString,
  readJson,
  readJsonIfExists,
  writeJson,
} from "./lib/common.js";
import { createSourceAllowlistMiddleware, parseTrustedCidrs } from "./lib/source-allowlist.js";
import {
  buildIpBlock,
  checkIpAvailability,
  selectSuggestedIpAllocation,
} from "./lib/ip-allocation.js";
import { cancelJob, queueJob } from "./lib/jobs.js";
import {
  clearAgentEndpointSecret,
  ensureAgentInternalToken,
  hasAgentApiKey,
  normalizeOpenAICompatibleProvider,
  queueAgentConfigSyncForLatestCluster,
  readAgentEndpointSecret,
  readAgentProviderConfig,
  resolveAgentProviderTestApiKey,
  writeAgentEndpointSecret,
  writeAgentProviderConfig,
} from "./lib/agents.js";
import {
  assertNoUpgradeMaintenance,
  isUpgradeMaintenanceActive,
  readUpgradeState,
  writeUpgradeState,
} from "./lib/upgrades.js";
import {
  buildProxmoxApiSecretBundle,
  buildClusterWorkerSecretBundle,
  mergeSecretBundles,
  normalizeSecretBaseRef,
  normalizeSecretBundle,
} from "../../lib/secrets/schema.mjs";
import { isClusterScopedStep } from "../../lib/step-scope.mjs";
import {
  readItemRecord,
  resolveAttachmentPath,
  secretRoot,
  clusterSecretDir,
  itemPrefix,
  writeItemRecord,
} from "../../lib/secrets/filesystem-store.mjs";

const app = express();
const port = Number(process.env.MANAGER_API_PORT || 8080);
const dataRoot = process.env.MANAGER_DATA_DIR || "/data";
const workspaceRoot = process.env.WORKSPACE_ROOT || process.cwd();
const dirs = buildDataDirs(dataRoot);
const dataFiles = buildDataFiles(dataRoot);
const trustedSourceCidrs = parseTrustedCidrs(process.env.MANAGER_API_TRUSTED_CIDRS);

Object.values(dirs).forEach((dir) => ensureDir(dir));

app.use(createSourceAllowlistMiddleware({ trustedCidrs: trustedSourceCidrs }));
app.use(express.json());

app.use((req, res, next) => {
  if (!["POST", "PUT", "PATCH", "DELETE"].includes(req.method)) {
    next();
    return;
  }
  if (
    req.path.includes("/upgrades") ||
    req.path.endsWith("/cancel") ||
    req.path === "/api/ip-availability" ||
    req.path === "/api/backup-storage/discovery" ||
    req.path === "/api/clusters" ||
    req.path === "/api/wizard/state"
  ) {
    next();
    return;
  }

  const clusterPathMatch = req.path.match(/^\/api\/clusters\/([^/]+)/);
  const clusterId =
    (typeof req.params?.clusterId === "string" && req.params.clusterId) ||
    (typeof req.body?.cluster_id === "string" && req.body.cluster_id) ||
    (clusterPathMatch ? decodeURIComponent(clusterPathMatch[1]) : "") ||
    "";
  try {
    assertNoUpgradeMaintenance(dirs, clusterId.trim());
    next();
  } catch (error) {
    res.status(error?.status || 409).json({ error: error.message });
  }
});

function parseNodeCount(value, fallback = 3) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 215) {
    return fallback;
  }
  return parsed;
}

function probeIpInUse(ip, options = {}) {
  const pingBin = process.env.MANAGER_API_PING_BIN || "ping";
  const attempts = Number.isInteger(Number(options.attempts))
    ? Math.max(1, Number(options.attempts))
    : 2;
  const isDefaultPing = path.basename(pingBin) === "ping";
  const args = isDefaultPing
    ? process.platform === "darwin"
      ? ["-n", "-c", "1", "-W", "1000", ip]
      : ["-n", "-c", "1", "-W", "1", ip]
    : [ip];

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const result = spawnSync(pingBin, args, {
      stdio: "ignore",
      timeout: 1500,
    });

    if (result.error?.code === "ENOENT") {
      throw new Error(`Ping command not found: ${pingBin}`);
    }

    if (result.status === 0) {
      return true;
    }
  }

  return false;
}

function proxmoxApiRequest(pathname, proxmoxEnv, { method = "GET", body, headers = {} } = {}) {
  const proxmoxHost = proxmoxEnv.PROXMOX_HOST;
  const proxmoxPort = proxmoxEnv.PROXMOX_PORT || "8006";
  const payload = body ? body.toString() : "";
  const args = ["-k", "-sS", "-X", method];

  for (const [key, value] of Object.entries(headers)) {
    args.push("-H", `${key}: ${value}`);
  }
  if (payload) {
    args.push("--data", payload);
  }
  args.push(`https://${proxmoxHost}:${proxmoxPort}${pathname}`);

  const result = spawnSync("curl", args, {
    encoding: "utf8",
    timeout: 5000,
  });
  if (result.error?.code === "ENOENT") {
    throw new Error("curl is required for Proxmox API suggestions");
  }
  if (result.status !== 0) {
    throw new Error(
      result.stderr?.trim() || result.stdout?.trim() || `Proxmox API ${method} ${pathname} failed`
    );
  }

  try {
    return JSON.parse(result.stdout || "{}");
  } catch (error) {
    throw new Error(
      `Failed to parse Proxmox API response: ${error instanceof Error ? error.message : "unknown error"}`,
      { cause: error }
    );
  }
}

function normalizeStoragePoolName(value) {
  return typeof value === "string" ? value.trim() : "";
}

function readClusterStorageStatusViaProxmoxApi(
  nodeNames,
  storagePoolName,
  resolved = null,
  ticket = ""
) {
  const ownsResolution = !resolved;
  const bundle = resolved || resolveSecretBundle(buildProxmoxApiSecretBundle());

  try {
    const username = bundle.env.PROXMOX_USER;
    const password = bundle.env.PROXMOX_PASSWORD;
    const proxmoxHost = bundle.env.PROXMOX_HOST;
    const storagePool = normalizeStoragePoolName(storagePoolName) || "local-lvm";

    if (!proxmoxHost || !username || !password) {
      throw new Error("Unable to inspect Proxmox storage: missing API credentials");
    }

    let authTicket = ticket;
    if (!authTicket) {
      const auth = proxmoxApiRequest("/api2/json/access/ticket", bundle.env, {
        method: "POST",
        body: new URLSearchParams({
          username,
          password,
        }),
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
      });
      authTicket = auth?.data?.ticket;
      if (!authTicket) {
        throw new Error("Proxmox auth failed while reading storage resources");
      }
    }

    const storageResources = proxmoxApiRequest(
      "/api2/json/cluster/resources?type=storage",
      bundle.env,
      {
        headers: {
          Cookie: `PVEAuthCookie=${authTicket}`,
        },
      }
    );
    const nodeLookup = new Set(
      Array.isArray(nodeNames)
        ? nodeNames.map((entry) => String(entry || "").trim()).filter(Boolean)
        : []
    );
    const storageByNode = new Map();
    for (const entry of Array.isArray(storageResources?.data) ? storageResources.data : []) {
      const nodeName = String(entry?.node || "").trim();
      const storageName = normalizeStoragePoolName(entry?.storage);
      if (!nodeName || !nodeLookup.has(nodeName) || storageName !== storagePool) {
        continue;
      }
      storageByNode.set(nodeName, entry);
    }

    return { storagePool, storageByNode };
  } finally {
    if (ownsResolution) {
      bundle.cleanup();
    }
  }
}

function resolveRequestedCluster(clusterId) {
  if (typeof clusterId !== "string" || clusterId.trim() === "") {
    return { ok: false, error: "cluster_id is required for follow-up cluster steps" };
  }

  const normalizedClusterId = clusterId.trim();
  const clusterFile = path.join(dirs.clusters, `${normalizedClusterId}.json`);
  if (!fs.existsSync(clusterFile)) {
    return { ok: false, status: 404, error: "cluster not found" };
  }

  return { ok: true, cluster: ensureClusterResourceProfile(readJson(clusterFile)) };
}

function buildSecretItemName(ref, context = {}) {
  const prefix = itemPrefix(process.env);
  if (ref?.scope === "cluster") {
    const clusterId = ref?.cluster_id || context.clusterId || context.cluster_id;
    return `${prefix}/cluster/${clusterId}/${ref.item}`;
  }
  return `${prefix}/${ref?.scope || "global"}/${ref?.item || ""}`;
}

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function resolveFieldValue(record, ref) {
  if (!record || typeof record !== "object") {
    return "";
  }

  const aliases = {
    proxmox: {
      host: ["host"],
      port: ["port"],
      username: ["username", "user"],
      password: ["password"],
      endpoint: ["endpoint"],
    },
    "traefik-dashboard": {
      username: ["username"],
      password: ["password"],
      users: ["users"],
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

function envFallbackRecord(ref) {
  if (ref.scope !== "global" || ref.item !== "proxmox") {
    return null;
  }

  const host = trimString(process.env.PROXMOX_HOST);
  const port = trimString(process.env.PROXMOX_PORT);
  const username = trimString(process.env.PROXMOX_USER || process.env.PROXMOX_USERNAME);
  const password = trimString(process.env.PROXMOX_PASSWORD || process.env.TF_VAR_proxmox_password);
  const endpoint = trimString(
    process.env.TF_VAR_proxmox_endpoint || (host && port ? `https://${host}:${port}` : "")
  );

  const record = {};
  if (host) record.host = host;
  if (port) record.port = port;
  if (username) record.username = username;
  if (password) record.password = password;
  if (endpoint) record.endpoint = endpoint;

  return Object.keys(record).length > 0 ? record : null;
}

function readSecretRecord(ref, context = {}) {
  return readItemRecord(process.env, ref, context) || envFallbackRecord(ref);
}

function resolveTextRef(rawRef, context = {}) {
  const ref = rawRef;
  const record = readSecretRecord(ref, context);
  const value = resolveFieldValue(record, ref);

  if (!value) {
    throw new Error(`secret field not found: ${ref.field} on ${ref.item}`);
  }

  return value;
}

function materializeRef(rawRef, label, context = {}) {
  const ref = rawRef;
  if (ref.attachment) {
    const attachmentPath = resolveAttachmentPath(process.env, ref, context);
    if (!fs.existsSync(attachmentPath)) {
      throw new Error(`secret attachment not found: ${attachmentPath}`);
    }
    return attachmentPath;
  }

  const value = resolveTextRef(ref, context);
  const tempRoot =
    process.env.TWINBOX_SECRET_TEMP_DIR ||
    path.join(process.env.MANAGER_DATA_DIR || "/tmp", "twinbox-secrets");
  fs.mkdirSync(tempRoot, { recursive: true, mode: 0o700 });
  const targetDir = fs.mkdtempSync(
    path.join(tempRoot, `${String(label || "secret").replace(/[^a-zA-Z0-9_.-]+/g, "-")}-`)
  );
  const targetFile = path.join(targetDir, "value");
  fs.writeFileSync(targetFile, value, { mode: 0o600 });
  return targetFile;
}

function resolveSecretBundle(bundleSpec = {}, context = {}) {
  const bundle = normalizeSecretBundle(bundleSpec);
  const env = {};
  const files = {};
  const redactions = [];
  const cleanupDirs = new Set();

  for (const [name, ref] of Object.entries(bundle.env)) {
    try {
      const fileLike = ref.format === "file" || ref.attachment;
      if (fileLike) {
        const filePath = materializeRef(ref, name, context);
        env[name] = filePath;
        files[name] = filePath;
        if (!ref.attachment) {
          cleanupDirs.add(path.dirname(filePath));
        }
        continue;
      }

      const value = resolveTextRef(ref, context);
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
      const filePath = materializeRef(ref, name, context);
      env[name] = filePath;
      files[name] = filePath;
      if (!ref.attachment) {
        cleanupDirs.add(path.dirname(filePath));
      }
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
    cleanup() {
      for (const dir of cleanupDirs) {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    },
  };
}

function listAttachmentNames(ref, context = {}) {
  const scope = String(ref?.scope || "global");
  const item = String(ref?.item || "");
  if (!item) {
    return [];
  }

  const dir =
    scope === "cluster"
      ? clusterSecretDir(
          process.env,
          ref?.cluster_id || context.clusterId || context.cluster_id,
          item
        )
      : path.join(secretRoot(process.env), "global", item);

  if (!fs.existsSync(dir)) {
    return [];
  }

  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
}

function buildSecretItemObject(ref, context = {}) {
  const record = readSecretRecord(ref, context);
  if (!record || typeof record !== "object") {
    return null;
  }

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

  const attachments = listAttachmentNames(ref, context).map((name, index) => ({
    id: `${buildSecretItemName(ref, context)}:${name}`,
    fileName: name,
    name,
    type: 0,
    order: index,
  }));

  return {
    id: buildSecretItemName(ref, context),
    name: buildSecretItemName(ref, context),
    type: 1,
    login: Object.keys(login).length > 0 ? login : undefined,
    notes: record.notes ? String(record.notes) : undefined,
    fields,
    attachments,
  };
}

async function listUsedVmidsViaProxmoxApi() {
  const resolved = resolveSecretBundle(buildProxmoxApiSecretBundle());

  try {
    const username = resolved.env.PROXMOX_USER;
    const password = resolved.env.PROXMOX_PASSWORD;
    const proxmoxHost = resolved.env.PROXMOX_HOST;

    if (!proxmoxHost || !username || !password) {
      throw new Error("Unable to inspect cluster VMIDs: pvesh and qm are both unavailable");
    }

    const body = new URLSearchParams({
      username,
      password,
    });
    const auth = proxmoxApiRequest("/api2/json/access/ticket", resolved.env, {
      method: "POST",
      body,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
    });
    const ticket = auth?.data?.ticket;
    if (!ticket) {
      throw new Error("Proxmox auth failed while suggesting VMIDs");
    }

    const resources = proxmoxApiRequest("/api2/json/cluster/resources?type=vm", resolved.env, {
      headers: {
        Cookie: `PVEAuthCookie=${ticket}`,
      },
    });

    return new Set(
      Array.isArray(resources?.data)
        ? resources.data
            .map((entry) => Number(entry?.vmid))
            .filter((value) => Number.isInteger(value) && value >= 100)
        : []
    );
  } finally {
    resolved.cleanup();
  }
}

async function listClusterNodeResourcesViaProxmoxApi() {
  const resolved = resolveSecretBundle(buildProxmoxApiSecretBundle());

  try {
    const username = resolved.env.PROXMOX_USER;
    const password = resolved.env.PROXMOX_PASSWORD;
    const proxmoxHost = resolved.env.PROXMOX_HOST;

    if (!proxmoxHost || !username || !password) {
      throw new Error("Unable to inspect Proxmox resources: missing API credentials");
    }

    const body = new URLSearchParams({
      username,
      password,
    });
    const auth = proxmoxApiRequest("/api2/json/access/ticket", resolved.env, {
      method: "POST",
      body,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
    });
    const ticket = auth?.data?.ticket;
    if (!ticket) {
      throw new Error("Proxmox auth failed while reading cluster resources");
    }

    const resources = proxmoxApiRequest("/api2/json/cluster/resources?type=node", resolved.env, {
      headers: {
        Cookie: `PVEAuthCookie=${ticket}`,
      },
    });

    const nodes = Array.isArray(resources?.data) ? resources.data : [];
    const storagePoolName = normalizeStoragePoolName(
      process.env.PROXMOX_STORAGE_POOL || "local-lvm"
    );
    const nodeNames = nodes
      .map((entry) => String(entry?.node || entry?.name || entry?.id || "").trim())
      .filter(Boolean);
    const { storageByNode } = readClusterStorageStatusViaProxmoxApi(
      nodeNames,
      storagePoolName,
      resolved,
      ticket
    );

    return nodes.map((entry) => {
      const nodeName = String(entry?.node || entry?.name || entry?.id || "").trim();
      const storage = storageByNode.get(nodeName);
      if (!storage) {
        return entry;
      }

      const totalDisk = Number(storage.total || storage.maxdisk || entry?.maxdisk || 0);
      const usedDisk = Number(storage.used || storage.disk || entry?.disk || 0);
      const availDisk = Number(storage.avail || Math.max(0, totalDisk - usedDisk));

      return {
        ...entry,
        maxdisk: Number.isFinite(totalDisk) && totalDisk > 0 ? totalDisk : entry?.maxdisk,
        disk: Number.isFinite(usedDisk) && usedDisk >= 0 ? usedDisk : entry?.disk,
        storage_pool: storagePoolName,
        storage_total: Number.isFinite(totalDisk) && totalDisk > 0 ? totalDisk : undefined,
        storage_used: Number.isFinite(usedDisk) && usedDisk >= 0 ? usedDisk : undefined,
        storage_avail: Number.isFinite(availDisk) && availDisk >= 0 ? availDisk : undefined,
      };
    });
  } finally {
    resolved.cleanup();
  }
}

async function listClusterStorageResourcesViaProxmoxApi() {
  const resolved = resolveSecretBundle(buildProxmoxApiSecretBundle());

  try {
    const username = resolved.env.PROXMOX_USER;
    const password = resolved.env.PROXMOX_PASSWORD;
    const proxmoxHost = resolved.env.PROXMOX_HOST;
    if (!proxmoxHost || !username || !password) {
      throw new Error("Unable to inspect Proxmox storage resources: missing API credentials");
    }

    const auth = proxmoxApiRequest("/api2/json/access/ticket", resolved.env, {
      method: "POST",
      body: new URLSearchParams({ username, password }),
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
    const ticket = auth?.data?.ticket;
    if (!ticket) throw new Error("Proxmox auth failed while reading storage resources");

    const resources = proxmoxApiRequest("/api2/json/cluster/resources?type=storage", resolved.env, {
      headers: { Cookie: `PVEAuthCookie=${ticket}` },
    });
    return (Array.isArray(resources?.data) ? resources.data : []).map(normalizeStorageResource);
  } finally {
    resolved.cleanup();
  }
}

async function listClusterVmResourcesViaProxmoxApi() {
  const resolved = resolveSecretBundle(buildProxmoxApiSecretBundle());

  try {
    const username = resolved.env.PROXMOX_USER;
    const password = resolved.env.PROXMOX_PASSWORD;
    const proxmoxHost = resolved.env.PROXMOX_HOST;

    if (!proxmoxHost || !username || !password) {
      throw new Error("Unable to inspect Proxmox VM resources: missing API credentials");
    }

    const body = new URLSearchParams({
      username,
      password,
    });
    const auth = proxmoxApiRequest("/api2/json/access/ticket", resolved.env, {
      method: "POST",
      body,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
    });
    const ticket = auth?.data?.ticket;
    if (!ticket) {
      throw new Error("Proxmox auth failed while reading VM resources");
    }

    const resources = proxmoxApiRequest("/api2/json/cluster/resources?type=vm", resolved.env, {
      headers: {
        Cookie: `PVEAuthCookie=${ticket}`,
      },
    });

    return Array.isArray(resources?.data) ? resources.data : [];
  } finally {
    resolved.cleanup();
  }
}

async function listClusterVmResources() {
  const resourcesBin = process.env.MANAGER_API_CLUSTER_RESOURCES_BIN || "pvesh";
  const isDefaultResourcesBin = path.basename(resourcesBin) === "pvesh";
  const args = isDefaultResourcesBin
    ? ["get", "/cluster/resources", "--type", "vm", "--output-format", "json"]
    : [];
  const result = spawnSync(resourcesBin, args, {
    encoding: "utf8",
    timeout: 3000,
  });

  if (result.error?.code === "ENOENT") {
    if (isDefaultResourcesBin) {
      return listClusterVmResourcesViaProxmoxApi();
    }
    throw new Error(`Cluster resources command not found: ${resourcesBin}`);
  }

  if (result.status !== 0) {
    throw new Error(
      `Cluster resources lookup failed: ${(result.stderr || result.stdout || "").trim()}`
    );
  }

  try {
    const parsed = JSON.parse(result.stdout || "[]");
    return Array.isArray(parsed)
      ? parsed.filter((entry) => Number.isInteger(Number(entry?.vmid)))
      : [];
  } catch (error) {
    throw new Error(
      `Failed to parse cluster VM resources: ${error instanceof Error ? error.message : "unknown error"}`,
      { cause: error }
    );
  }
}

async function listUsedVmids() {
  const resourcesBin = process.env.MANAGER_API_CLUSTER_RESOURCES_BIN || "pvesh";
  const isDefaultResourcesBin = path.basename(resourcesBin) === "pvesh";
  const args = isDefaultResourcesBin
    ? ["get", "/cluster/resources", "--type", "vm", "--output-format", "json"]
    : [];
  const result = spawnSync(resourcesBin, args, {
    encoding: "utf8",
    timeout: 3000,
  });

  if (result.error?.code === "ENOENT") {
    if (isDefaultResourcesBin) {
      const qmResult = spawnSync("qm", ["list"], {
        encoding: "utf8",
        timeout: 3000,
      });
      if (qmResult.error?.code === "ENOENT") {
        return listUsedVmidsViaProxmoxApi();
      }
      if (qmResult.status !== 0) {
        throw new Error(`qm list failed: ${(qmResult.stderr || qmResult.stdout || "").trim()}`);
      }
      return new Set(
        (qmResult.stdout || "")
          .split("\n")
          .slice(1)
          .map((line) => line.trim().split(/\s+/)[0])
          .filter((value) => /^\d+$/.test(value))
          .map(Number)
      );
    }
    throw new Error(`Cluster resources command not found: ${resourcesBin}`);
  }

  if (result.status !== 0) {
    throw new Error(
      `Cluster resources lookup failed: ${(result.stderr || result.stdout || "").trim()}`
    );
  }

  try {
    const parsed = JSON.parse(result.stdout || "[]");
    return new Set(
      Array.isArray(parsed)
        ? parsed
            .map((entry) => Number(entry?.vmid))
            .filter((value) => Number.isInteger(value) && value >= 100)
        : []
    );
  } catch (error) {
    throw new Error(
      `Failed to parse cluster VM resources: ${error instanceof Error ? error.message : "unknown error"}`,
      { cause: error }
    );
  }
}

async function listClusterNodeResources() {
  const resourcesBin = process.env.MANAGER_API_CLUSTER_RESOURCES_BIN || "pvesh";
  const isDefaultResourcesBin = path.basename(resourcesBin) === "pvesh";
  const args = isDefaultResourcesBin
    ? ["get", "/cluster/resources", "--type", "node", "--output-format", "json"]
    : [];
  const result = spawnSync(resourcesBin, args, {
    encoding: "utf8",
    timeout: 3000,
  });

  if (result.error?.code === "ENOENT") {
    if (isDefaultResourcesBin) {
      return listClusterNodeResourcesViaProxmoxApi();
    }
    throw new Error(`Cluster resources command not found: ${resourcesBin}`);
  }

  if (result.status !== 0) {
    throw new Error(
      `Cluster resources lookup failed: ${(result.stderr || result.stdout || "").trim()}`
    );
  }

  try {
    const parsed = JSON.parse(result.stdout || "[]");
    return Array.isArray(parsed)
      ? parsed.filter((entry) => !String(entry?.storage || "").trim())
      : [];
  } catch (error) {
    throw new Error(
      `Failed to parse cluster node resources: ${error instanceof Error ? error.message : "unknown error"}`,
      { cause: error }
    );
  }
}

async function listClusterStorageResources() {
  const resourcesBin = process.env.MANAGER_API_CLUSTER_RESOURCES_BIN || "pvesh";
  const isDefaultResourcesBin = path.basename(resourcesBin) === "pvesh";
  const args = isDefaultResourcesBin
    ? ["get", "/cluster/resources", "--type", "storage", "--output-format", "json"]
    : [];
  const result = spawnSync(resourcesBin, args, { encoding: "utf8", timeout: 3000 });

  if (result.error?.code === "ENOENT") {
    if (isDefaultResourcesBin) return listClusterStorageResourcesViaProxmoxApi();
    throw new Error(`Cluster resources command not found: ${resourcesBin}`);
  }
  if (result.status !== 0) {
    throw new Error(
      `Cluster storage lookup failed: ${(result.stderr || result.stdout || "").trim()}`
    );
  }

  let parsed;
  try {
    parsed = JSON.parse(result.stdout || "[]");
  } catch (error) {
    throw new Error(
      `Failed to parse cluster storage resources: ${error instanceof Error ? error.message : "unknown error"}`,
      { cause: error }
    );
  }
  const entries = Array.isArray(parsed) ? parsed : [];
  const storages = entries.filter((entry) => String(entry?.storage || "").trim());
  if (storages.length > 0) return storages.map(normalizeStorageResource);

  const fallbackStorage = process.env.PROXMOX_STORAGE_POOL || "local-lvm";
  return entries
    .filter((entry) => String(entry?.node || entry?.name || entry?.id || "").trim())
    .map((entry) =>
      normalizeStorageResource({
        node: entry.node || entry.name || entry.id,
        storage: fallbackStorage,
        content: "images",
        active: 1,
        enabled: 1,
        shared: 0,
        total: entry.maxdisk,
        used: entry.disk,
        avail: Math.max(0, Number(entry.maxdisk || 0) - Number(entry.disk || 0)),
      })
    );
}

function summarizeClusterResources(resources, vmResources = [], storageResources = []) {
  const MB = 1024 * 1024;
  const GB = 1024 * 1024 * 1024;
  const nodes = Array.isArray(resources) ? resources : [];
  const vms = Array.isArray(vmResources) ? vmResources : [];
  const activeVmCounts = vms.reduce((accumulator, entry) => {
    const node = String(entry?.node || "").trim();
    const status = String(entry?.status || entry?.qmpstatus || "")
      .trim()
      .toLowerCase();
    if (!node || (status && status !== "running")) {
      return accumulator;
    }
    accumulator[node] = (accumulator[node] || 0) + 1;
    return accumulator;
  }, {});

  const summary = nodes.reduce(
    (accumulator, entry) => {
      const maxMem = Number(entry?.maxmem || 0);
      const usedMem = Number(entry?.mem || 0);
      const maxDisk = Number(entry?.maxdisk || 0);
      const usedDisk = Number(entry?.disk || 0);
      const maxCpu = Number(entry?.maxcpu || 0);
      const cpuLoad = Number(entry?.cpu || 0);

      accumulator.nodeCount += 1;
      accumulator.totalMemoryMb += maxMem > 0 ? maxMem / MB : 0;
      accumulator.usedMemoryMb += usedMem > 0 ? usedMem / MB : 0;
      accumulator.totalDiskGb += maxDisk > 0 ? maxDisk / GB : 0;
      accumulator.usedDiskGb += usedDisk > 0 ? usedDisk / GB : 0;
      accumulator.totalCpuCores += maxCpu > 0 ? maxCpu : 0;
      accumulator.usedCpuCores += maxCpu > 0 ? maxCpu * Math.min(Math.max(cpuLoad, 0), 1) : 0;
      return accumulator;
    },
    {
      nodeCount: 0,
      totalMemoryMb: 0,
      usedMemoryMb: 0,
      freeMemoryMb: 0,
      totalDiskGb: 0,
      usedDiskGb: 0,
      freeDiskGb: 0,
      totalCpuCores: 0,
      usedCpuCores: 0,
      freeCpuCores: 0,
    }
  );

  summary.freeMemoryMb = Math.max(0, summary.totalMemoryMb - summary.usedMemoryMb);
  summary.freeDiskGb = Math.max(0, summary.totalDiskGb - summary.usedDiskGb);
  summary.freeCpuCores = Math.max(0, summary.totalCpuCores - summary.usedCpuCores);

  return {
    nodes: nodes.map((entry) => ({
      ...entry,
      activeVmCount:
        activeVmCounts[String(entry?.node || entry?.name || entry?.id || "").trim()] || 0,
    })),
    vms,
    storages: (Array.isArray(storageResources) ? storageResources : []).map(
      normalizeStorageResource
    ),
    summary,
  };
}

const KUBECTL_MAX_BUFFER_BYTES = 32 * 1024 * 1024;

function runKubectl(kubeconfigPath, args, { optional = false } = {}) {
  const kubectlBin = process.env.MANAGER_API_KUBECTL_BIN || "kubectl";
  const result = spawnSync(kubectlBin, ["--kubeconfig", kubeconfigPath, ...args], {
    encoding: "utf8",
    maxBuffer: KUBECTL_MAX_BUFFER_BYTES,
    timeout: 5000,
  });

  if (result.error?.code === "ENOENT") {
    if (optional) return { ok: false, error: `kubectl not found: ${kubectlBin}` };
    throw new Error(`kubectl not found: ${kubectlBin}`);
  }
  if (result.error) {
    if (optional) return { ok: false, error: result.error.message };
    throw result.error;
  }
  if (result.status !== 0) {
    const message =
      (result.stderr || result.stdout || "").trim() || `kubectl ${args.join(" ")} failed`;
    if (optional) return { ok: false, error: message };
    throw new Error(message);
  }

  return { ok: true, stdout: result.stdout || "" };
}

function runKubectlJson(kubeconfigPath, args, { optional = false } = {}) {
  const result = runKubectl(kubeconfigPath, args, { optional });
  if (!result.ok) return { ok: false, error: result.error };
  try {
    return { ok: true, data: JSON.parse(result.stdout || "{}") };
  } catch (error) {
    const message = `failed to parse kubectl ${args.join(" ")}: ${
      error instanceof Error ? error.message : "unknown error"
    }`;
    if (optional) return { ok: false, error: message };
    throw new Error(message, { cause: error });
  }
}

function resolveClusterKubeconfigPath(cluster) {
  const secretBundle = buildClusterWorkerSecretBundle(cluster);
  const kubeconfigRef = secretBundle.files.TWINBOX_KUBECONFIG_FILE;
  if (!kubeconfigRef) {
    throw new Error("cluster kubeconfig secret reference is missing");
  }
  return resolveAttachmentPath(process.env, kubeconfigRef, { clusterId: cluster.id });
}

function readClusterPressure(cluster) {
  const kubeconfigPath = resolveClusterKubeconfigPath(cluster);
  if (!fs.existsSync(kubeconfigPath)) {
    const error = new Error(`cluster kubeconfig not found: ${kubeconfigPath}`);
    error.status = 404;
    throw error;
  }

  const errors = [];
  const required = [
    ["nodes", ["get", "nodes", "-o", "json"]],
    ["pods", ["get", "pods", "-A", "-o", "json"]],
    ["events", ["get", "events", "-A", "--field-selector", "type=Warning", "-o", "json"]],
  ].reduce((accumulator, [key, args]) => {
    accumulator[key] = runKubectlJson(kubeconfigPath, args).data;
    return accumulator;
  }, {});

  const topNodesResult = runKubectl(kubeconfigPath, ["top", "nodes"], { optional: true });
  if (!topNodesResult.ok) errors.push(topNodesResult.error);

  const longhornNodesResult = runKubectlJson(
    kubeconfigPath,
    ["-n", "longhorn-system", "get", "nodes.longhorn.io", "-o", "json"],
    { optional: true }
  );
  if (!longhornNodesResult.ok) errors.push(longhornNodesResult.error);

  const longhornVolumesResult = runKubectlJson(
    kubeconfigPath,
    ["-n", "longhorn-system", "get", "volumes.longhorn.io", "-o", "json"],
    { optional: true }
  );
  if (!longhornVolumesResult.ok) errors.push(longhornVolumesResult.error);

  return buildClusterPressureSummary({
    ...required,
    topNodes: topNodesResult.stdout || "",
    longhornNodes: longhornNodesResult.data || {},
    longhornVolumes: longhornVolumesResult.data || {},
    errors,
  });
}

async function findFreeVmidBlock(nodeCount) {
  const usedVmids = await listUsedVmids();
  let candidate = 100;

  while (candidate <= 999999) {
    const block = Array.from({ length: nodeCount }, (_, offset) => candidate + offset);
    if (block.every((vmid) => !usedVmids.has(vmid))) {
      return {
        start_vmid: candidate,
        vmid_block: block,
      };
    }
    candidate += 1;
  }

  throw new Error(`No free consecutive ${nodeCount}-VMID block found`);
}

function readIpCommand(args) {
  const ipBin = process.env.MANAGER_API_IP_BIN || "ip";
  const result = spawnSync(ipBin, args, {
    encoding: "utf8",
    timeout: 1000,
  });

  if (result.error?.code === "ENOENT") {
    return "";
  }
  if (result.status !== 0) {
    return "";
  }
  return result.stdout || "";
}

function detectNodePrefixLength(managementIp) {
  const output = readIpCommand(["-o", "-f", "inet", "addr", "show", "scope", "global"]);
  const lines = output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const exact = lines.find((line) => line.includes(` inet ${managementIp}/`));
  if (!exact) {
    return 24;
  }

  const match = exact.match(/\binet\s+\d+\.\d+\.\d+\.\d+\/(\d+)/);
  const parsed = Number(match?.[1] || 24);
  return Number.isInteger(parsed) && parsed >= 1 && parsed <= 32 ? parsed : 24;
}

function inSame24Subnet(left, right) {
  const leftOctets = String(left || "").split(".");
  const rightOctets = String(right || "").split(".");
  if (leftOctets.length !== 4 || rightOctets.length !== 4) {
    return false;
  }
  return leftOctets.slice(0, 3).join(".") === rightOctets.slice(0, 3).join(".");
}

function detectGatewayIp(managementIp) {
  const output = readIpCommand(["route"]);
  const match = output.match(/^default via (\d+\.\d+\.\d+\.\d+)/m);
  if (match?.[1] && inSame24Subnet(match[1], managementIp)) {
    return match[1];
  }

  const octets = managementIp.split(".");
  return `${octets[0]}.${octets[1]}.${octets[2]}.1`;
}

function isLoopbackIpv4(ip) {
  return String(ip || "").startsWith("127.");
}

function isPlaceholderDnsDomain(domain) {
  const normalized = String(domain || "")
    .trim()
    .toLowerCase();
  return normalized === "localdomain" || normalized === "localhost.localdomain";
}

function detectDnsDefaults() {
  const resolvConf = process.env.MANAGER_API_RESOLV_CONF || "/etc/resolv.conf";
  if (!fs.existsSync(resolvConf)) {
    return {
      dns_servers: ["1.1.1.1", "8.8.8.8"],
      dns_domain: "",
    };
  }

  const lines = fs.readFileSync(resolvConf, "utf8").split(/\r?\n/);
  const dnsServers = [];
  let dnsDomain = "";

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    if (line.startsWith("nameserver ")) {
      const candidate = line.split(/\s+/)[1] || "";
      const parsed = parseIPv4(candidate, "nameserver");
      if (parsed.ok && !isLoopbackIpv4(parsed.value) && !dnsServers.includes(parsed.value)) {
        dnsServers.push(parsed.value);
      }
      continue;
    }

    if (line.startsWith("search ") || line.startsWith("domain ")) {
      const parts = line.split(/\s+/).slice(1).filter(Boolean);
      const candidate = parts.find((entry) => !isPlaceholderDnsDomain(entry));
      if (candidate) {
        dnsDomain = candidate;
      }
    }
  }

  return {
    dns_servers: dnsServers.length > 0 ? dnsServers : ["1.1.1.1", "8.8.8.8"],
    dns_domain: dnsDomain,
  };
}

function detectHostNetworkDefaults(managementIp) {
  const dnsDefaults = detectDnsDefaults();
  return {
    node_prefix_length: detectNodePrefixLength(managementIp),
    gateway_ip: detectGatewayIp(managementIp),
    dns_servers: dnsDefaults.dns_servers,
    dns_domain: dnsDefaults.dns_domain,
  };
}

function suggestClusterName() {
  const envSlug = process.env.TWINBOX_CLUSTER_SLUG || "";
  const normalized = normalizeClusterName(envSlug);
  return normalized?.name || "twinbox-cluster";
}

async function suggestAllocation(managementIp, nodeCount) {
  const inUseCache = new Map();
  const networkDefaults = detectHostNetworkDefaults(managementIp);

  const isIpInUse = (ip) => {
    if (inUseCache.has(ip)) {
      return inUseCache.get(ip);
    }
    const inUse = probeIpInUse(ip);
    inUseCache.set(ip, inUse);
    return inUse;
  };

  const vmidSuggestion = await findFreeVmidBlock(nodeCount);
  const ipSuggestion = await selectSuggestedIpAllocation({
    managementIp,
    nodeCount,
    isIpInUse,
  });

  return {
    management_ip: managementIp,
    node_count: nodeCount,
    name_suggestion: suggestClusterName(),
    start_vmid: vmidSuggestion.start_vmid,
    vmid_block: vmidSuggestion.vmid_block,
    ...ipSuggestion,
    node_prefix_length: networkDefaults.node_prefix_length,
    gateway_ip: networkDefaults.gateway_ip,
    dns_servers: networkDefaults.dns_servers,
    dns_domain: networkDefaults.dns_domain,
    probed_addresses: inUseCache.size,
  };
}

async function validateRequestedAllocation({ startVmid, vipIp, startIp, nodeCount }, options = {}) {
  const { skipVmidCheck = false, usedVmids = null, probeIpInUseFn = probeIpInUse } = options;
  const requestedVmids = Array.from({ length: nodeCount }, (_, offset) => startVmid + offset);

  if (!skipVmidCheck) {
    const vmidLookup = usedVmids || (await listUsedVmids());
    if (!requestedVmids.every((vmid) => !vmidLookup.has(vmid))) {
      return {
        ok: false,
        error: `VMID range ${requestedVmids[0]}-${requestedVmids[requestedVmids.length - 1]} is not free`,
      };
    }
  }

  const vipParts = vipIp.split(".");
  const startParts = startIp.split(".");
  const vipPrefix = vipParts.slice(0, 3).join(".");
  const startPrefix = startParts.slice(0, 3).join(".");
  if (vipPrefix !== startPrefix) {
    return { ok: false, error: "vip_ip and start_ip must be in the same /24 subnet" };
  }

  const startOctet = Number(startParts[3]);
  const vipOctet = Number(vipParts[3]);
  const ipBlock = buildIpBlock(startPrefix, startOctet, nodeCount);
  if (ipBlock.some((ip) => Number(ip.split(".")[3]) > 254)) {
    return { ok: false, error: `Node IP range starting at ${startIp} exceeds the /24 subnet` };
  }

  if (vipOctet === startOctet || ipBlock.includes(vipIp)) {
    return { ok: false, error: "vip_ip must not overlap with the node IP range" };
  }

  if (probeIpInUseFn(vipIp)) {
    return { ok: false, error: `VIP IP ${vipIp} is already in use` };
  }

  const occupiedIp = ipBlock.find((ip) => probeIpInUseFn(ip));
  if (occupiedIp) {
    return { ok: false, error: `Node IP ${occupiedIp} is already in use` };
  }

  return { ok: true };
}

function shouldReuseProvisionClusterInstance(existingCluster, requestedClusterInstanceId) {
  if (!requestedClusterInstanceId || !existingCluster?.cluster_instance_id) {
    return false;
  }

  if (requestedClusterInstanceId !== existingCluster.cluster_instance_id) {
    return false;
  }

  return !["bootstrapped", "provisioned"].includes(String(existingCluster.status || ""));
}

function stepStatePath(stepId, clusterScope = null) {
  const scope = clusterScope ? path.join("clusters", clusterScope) : "global";
  return path.join(dirs.stepState, scope, `${stepId}.json`);
}

function readStepState(stepId, clusterScope = null) {
  const file = stepStatePath(stepId, clusterScope);
  if (!fs.existsSync(file)) {
    return null;
  }
  return readJson(file);
}

function writeStepState(stepId, patch, clusterScope = null) {
  const file = stepStatePath(stepId, clusterScope);
  const current = readStepState(stepId, clusterScope) || {
    step_id: stepId,
    status: "not_started",
    inputs: {},
    outputs: null,
    cluster_id: clusterScope || null,
    cluster_instance_id: patch.cluster_instance_id ?? clusterScope ?? null,
    error: null,
    last_job_id: null,
    created_at: now(),
  };

  const next = {
    ...current,
    ...patch,
    step_id: stepId,
    cluster_id: patch.cluster_id ?? current.cluster_id ?? clusterScope ?? null,
    cluster_instance_id:
      patch.cluster_instance_id ?? current.cluster_instance_id ?? clusterScope ?? null,
    updated_at: now(),
  };
  writeJson(file, next);
  return next;
}

function prepareStepInputs(step, normalizedInputs, clusterId) {
  const { publicInputs, secretFields } = partitionStepInputs(step, normalizedInputs);
  if (Object.keys(secretFields).length === 0) {
    return publicInputs;
  }

  const secretRef = { scope: "cluster", item: "backup-storage-pending", cluster_id: clusterId };
  const existing = readItemRecord(process.env, secretRef, { clusterId }) || {};
  writeItemRecord(process.env, secretRef, { ...existing, ...secretFields }, { clusterId });
  return publicInputs;
}

function parseSecretKeyPath(secretKeyPath) {
  const segments = String(secretKeyPath || "")
    .split("/")
    .map((segment) => segment.trim())
    .filter(Boolean);

  if (segments.length < 3) {
    throw new Error("secret key must include a prefix, scope, and item");
  }

  const [, scope, ...rest] = segments;
  if (!scope) {
    throw new Error("secret scope is required");
  }

  if (scope === "cluster") {
    const [clusterId, ...itemParts] = rest;
    const item = itemParts.join("/");
    if (!clusterId || !item) {
      throw new Error("cluster secret key must include a cluster id and item");
    }
    return normalizeSecretBaseRef({
      scope,
      cluster_id: clusterId,
      item,
    });
  }

  const item = rest.join("/");
  if (!item) {
    throw new Error("secret item is required");
  }

  return normalizeSecretBaseRef({
    scope,
    item,
  });
}

app.get("/api/health", (_, res) => {
  res.json({ ok: true, time: now(), image_tag: process.env.TWINBOX_IMAGE_TAG || "unknown" });
});

app.get(/^\/api\/secrets\/.*$/, (req, res) => {
  const secretKeyPath = decodeURIComponent(
    String(req.originalUrl || "").split("/api/secrets/")[1] || ""
  );

  try {
    const ref = parseSecretKeyPath(secretKeyPath);
    const item = buildSecretItemObject(ref);
    if (!item) {
      throw new Error(`secret item not found: ${ref.item}`);
    }
    return res.json({ data: item });
  } catch (error) {
    const message = error instanceof Error ? error.message : "failed to resolve secret";
    const status = message.includes("not found") ? 404 : 400;
    return res.status(status).json({ error: message });
  }
});

app.get("/api/proxmox/cluster-resources", async (_, res) => {
  try {
    const [nodes, vms, storages] = await Promise.all([
      listClusterNodeResources(),
      listClusterVmResources(),
      listClusterStorageResources(),
    ]);
    return res.json(summarizeClusterResources(nodes, vms, storages));
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to read cluster resources",
    });
  }
});

app.post("/api/backup-storage/discovery", async (req, res) => {
  let resolved;
  try {
    if (req.body.cluster_id && !/^[a-zA-Z0-9_-]+$/.test(req.body.cluster_id)) {
      return res.status(400).json({ error: "Invalid cluster id" });
    }
    const requestedCluster = req.body.cluster_id
      ? loadCluster(dirs, req.body.cluster_id)
      : req.body.cluster || {};
    const managementIp = process.env.MANAGEMENT_VM_IP || req.body.management_ip;
    if (!parseIPv4(managementIp, "management_ip").ok)
      throw new Error("Management VM IP is unavailable");
    // Question 2 can be reached before the generated defaults from question 1 have
    // been persisted. Use the Management VM's live network as the fallback, while
    // preserving every explicit cluster value.
    const cluster = { ...detectHostNetworkDefaults(managementIp), ...requestedCluster };
    const clusters = fs
      .readdirSync(dirs.clusters)
      .filter((file) => file.endsWith(".json"))
      .map((file) => readJson(path.join(dirs.clusters, file)));
    const profiles = clusters.map((c) => ({
      id: c.id,
      vm: readJsonIfExists(
        path.join(clusterSecretDir(process.env, c.id, "backup-storage"), "metadata.json")
      )?.vm,
    }));
    const saved = profiles.find((p) => p.id === cluster.id)?.vm;
    // Never return credentials or the SSH key path from the backup profile.
    const existing = saved?.vm_id
      ? {
          vm_id: saved.vm_id,
          node: saved.node,
          datastore: saved.datastore,
          ip_address: saved.ip_address,
          data_disk_gb: saved.data_disk_gb,
        }
      : null;
    resolved = resolveSecretBundle(buildProxmoxApiSecretBundle());
    const auth = proxmoxApiRequest("/api2/json/access/ticket", resolved.env, {
      method: "POST",
      body: new URLSearchParams({
        username: resolved.env.PROXMOX_USER,
        password: resolved.env.PROXMOX_PASSWORD,
      }),
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
    if (!auth?.data?.ticket) throw new Error("Proxmox authentication failed");
    const headers = { Cookie: `PVEAuthCookie=${auth.data.ticket}` };
    const get = (route) => {
      const result = proxmoxApiRequest(`/api2/json${route}`, resolved.env, { headers });
      if (!Array.isArray(result?.data)) throw new Error(`Unable to inspect Proxmox ${route}`);
      return result.data;
    };
    const nodes = get("/cluster/resources?type=node");
    const storages = [],
      networks = [];
    for (const node of nodes.filter((n) => n.status === "online")) {
      const base = `/nodes/${encodeURIComponent(node.node)}`;
      storages.push(...get(`${base}/storage`).map((s) => ({ ...s, node: node.node })));
      networks.push(...get(`${base}/network`).map((n) => ({ ...n, node: node.node })));
    }
    const reserved = reservedBackupIps([...clusters, cluster], managementIp, [
      ...profiles.map((p) => p.vm?.ip_address),
    ]);
    let ip = existing?.ip_address || "",
      ip_error = "";
    if (!ip && req.body.suggest_ip !== false) {
      try {
        const excluded = Array.isArray(req.body.exclude_ips) ? req.body.exclude_ips : [];
        ip = await suggestBackupIp(cluster, new Set([...reserved, ...excluded]), probeIpInUse);
      } catch (error) {
        ip_error = error.message;
      }
    }
    return res.json({
      hosts: backupHosts({ nodes, storages, networks, cluster }),
      existing,
      ip,
      ip_error,
      network: { gateway_ip: cluster.gateway_ip, node_prefix_length: cluster.node_prefix_length },
      reserved_ips: [...reserved].filter((ip) => ip !== existing?.ip_address),
    });
  } catch (error) {
    return res.status(400).json({ error: error.message || "Backup discovery failed" });
  } finally {
    resolved?.cleanup();
  }
});

app.post("/api/proxmox/placement-plan", async (req, res) => {
  try {
    const [nodes, vms, storages] = await Promise.all([
      listClusterNodeResources(),
      listClusterVmResources(),
      listClusterStorageResources(),
    ]);
    const placement = computePlacement({
      nodes,
      vms,
      storages,
      controlplaneCount: Number(req.body?.controlplane_count ?? 3),
      workerCount: Number(req.body?.worker_count ?? 0),
      clusterName: req.body?.name ? `twinbox-${normalizeClusterSlug(req.body.name)}` : "",
    });
    if (!placement.ok) {
      return res.status(400).json({ error: placement.error });
    }
    return res.json(placement);
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to compute placement",
    });
  }
});

app.get("/api/catalog", (req, res) => {
  const requestedClusterId = pickFirstString(req.query.cluster_id);
  if (requestedClusterId) {
    const requestedCluster = resolveRequestedCluster(requestedClusterId);
    if (!requestedCluster.ok) {
      return res.status(requestedCluster.status || 400).json({ error: requestedCluster.error });
    }
  }

  const catalog = buildCatalogResponse({
    workspaceRoot,
    dirs,
    clusterId: requestedClusterId || null,
  });
  return res.json({
    categories: catalog.categories,
    errors: catalog.errors,
  });
});

app.get("/api/apps/catalog", (req, res) => {
  const requestedClusterId = pickFirstString(req.query.cluster_id);
  if (requestedClusterId) {
    const requestedCluster = resolveRequestedCluster(requestedClusterId);
    if (!requestedCluster.ok) {
      return res.status(requestedCluster.status || 400).json({ error: requestedCluster.error });
    }
  }

  const catalog = buildAppCatalogResponse({
    workspaceRoot,
    dirs,
    clusterId: requestedClusterId || null,
  });
  if (!catalog.active_cluster?.id) {
    return res.status(404).json({ error: "cluster not found" });
  }

  return res.json(catalog);
});

app.post("/api/apps/:stepId/install", async (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId =
    typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const requestedClusterInstanceId =
    typeof req.body?.cluster_instance_id === "string" ? req.body.cluster_instance_id.trim() : "";
  const catalog = buildAppCatalogResponse({
    workspaceRoot,
    dirs,
    clusterId: requestedClusterId || null,
  });
  const appCategory = catalog.categories.find((category) => category.id === "apps");
  const step = appCategory?.steps.find((candidate) => candidate.id === stepId);

  if (!step || step.category_id !== "apps") {
    return res.status(404).json({ error: "app not found" });
  }

  const visibleStep = appCategory?.steps.find((candidate) => candidate.id === stepId);
  if (!visibleStep) {
    return res.status(404).json({ error: "app not found" });
  }

  if (visibleStep.app_state === "planned") {
    return res.status(409).json({ error: `${stepId} is not installable yet` });
  }

  if (visibleStep.app_state === "installing") {
    return res.status(409).json({ error: `${stepId} is already installing` });
  }

  const forceInstall = req.body?.force === true || req.query?.force === "true";
  if (!forceInstall && visibleStep.app_state === "installed") {
    return res.status(409).json({ error: `${stepId} is already installed` });
  }

  if (
    requestedClusterId &&
    catalog.active_cluster?.id &&
    requestedClusterId !== catalog.active_cluster.id
  ) {
    return res.status(409).json({ error: "cluster mismatch" });
  }

  const activeClusterId = catalog.active_cluster?.id;
  if (!activeClusterId) {
    return res.status(404).json({ error: "cluster not found" });
  }

  const resolvedCluster = resolveRequestedCluster(activeClusterId);
  if (!resolvedCluster.ok || !resolvedCluster.cluster?.id) {
    return res
      .status(resolvedCluster.status || 404)
      .json({ error: resolvedCluster.error || "cluster not found" });
  }
  const activeCluster = resolvedCluster.cluster;

  const activeClusterInstanceId =
    activeCluster.cluster_instance_id || activeCluster.instance_id || null;
  if (
    requestedClusterInstanceId &&
    activeClusterInstanceId &&
    requestedClusterInstanceId !== activeClusterInstanceId
  ) {
    return res.status(409).json({ error: "cluster instance mismatch" });
  }

  const validated = validateStepInputs(step, req.body?.inputs);
  if (!validated.ok) {
    return res.status(400).json({ error: validated.error });
  }
  const jobInputs = prepareStepInputs(step, validated.value, activeCluster.id);

  const payload = {
    step_id: step.id,
    step_type: step.type,
    inputs: jobInputs,
    runner: step.runner,
    context: { cluster: activeCluster },
  };

  if (
    step.secrets &&
    (Object.keys(step.secrets.env || {}).length > 0 ||
      Object.keys(step.secrets.files || {}).length > 0)
  ) {
    payload.secret_bundle = normalizeSecretBundle(step.secrets);
  }

  const job = queueJob(dirs, "run_step", activeCluster.id, payload);
  writeStepState(
    step.id,
    {
      status: "pending",
      inputs: jobInputs,
      outputs: null,
      error: null,
      last_job_id: job.id,
      cluster_id: activeCluster.id,
      cluster_instance_id: activeClusterInstanceId,
    },
    activeClusterInstanceId || activeCluster.id
  );

  return res.status(202).json({
    step_id: step.id,
    cluster_id: activeCluster.id,
    cluster_instance_id: activeClusterInstanceId,
    job_id: job.id,
    job_type: job.type,
  });
});

app.post("/api/apps/:stepId/uninstall", async (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId =
    typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const requestedClusterInstanceId =
    typeof req.body?.cluster_instance_id === "string" ? req.body.cluster_instance_id.trim() : "";
  const catalog = buildAppCatalogResponse({
    workspaceRoot,
    dirs,
    clusterId: requestedClusterId || null,
  });
  const appCategory = catalog.categories.find((category) => category.id === "apps");
  const step = appCategory?.steps.find((candidate) => candidate.id === stepId);

  if (!step || step.category_id !== "apps") {
    return res.status(404).json({ error: "app not found" });
  }

  const forceUninstall = req.body?.force === true || req.query?.force === "true";
  if (!forceUninstall && step.app_state !== "installed") {
    return res.status(409).json({ error: `${stepId} is not installed` });
  }

  if (
    requestedClusterId &&
    catalog.active_cluster?.id &&
    requestedClusterId !== catalog.active_cluster.id
  ) {
    return res.status(409).json({ error: "cluster mismatch" });
  }

  const activeClusterId = catalog.active_cluster?.id;
  if (!activeClusterId) {
    return res.status(404).json({ error: "cluster not found" });
  }

  const resolvedCluster = resolveRequestedCluster(activeClusterId);
  if (!resolvedCluster.ok || !resolvedCluster.cluster?.id) {
    return res
      .status(resolvedCluster.status || 404)
      .json({ error: resolvedCluster.error || "cluster not found" });
  }
  const activeCluster = resolvedCluster.cluster;

  const activeClusterInstanceId =
    activeCluster.cluster_instance_id || activeCluster.instance_id || null;
  if (
    requestedClusterInstanceId &&
    activeClusterInstanceId &&
    requestedClusterInstanceId !== activeClusterInstanceId
  ) {
    return res.status(409).json({ error: "cluster instance mismatch" });
  }

  const appName = stepId.startsWith("install-") ? stepId.slice("install-".length) : stepId;
  const manifestPath = path.join(workspaceRoot, "gitops", "apps", `${appName}.yaml`);
  if (!fs.existsSync(manifestPath)) {
    return res.status(404).json({ error: "app manifest not found" });
  }

  const stepSecretBundle = normalizeSecretBundle(step.secrets);
  const payload = {
    step_id: step.id,
    step_type: step.type,
    cluster_id: activeCluster.id,
    cluster_instance_id: activeClusterInstanceId,
    secret_bundle: mergeSecretBundles(
      buildClusterWorkerSecretBundle(activeCluster),
      stepSecretBundle
    ),
    app_name: appName,
    manifest_path: manifestPath,
    application_set_name: `${appName}-set`,
    context: { cluster: activeCluster },
  };

  const job = queueJob(dirs, "uninstall_step", activeCluster.id, payload);
  writeStepState(
    step.id,
    {
      status: "running",
      inputs: {},
      outputs: null,
      error: null,
      last_job_id: job.id,
      cluster_id: activeCluster.id,
      cluster_instance_id: activeClusterInstanceId,
    },
    activeClusterInstanceId || activeCluster.id
  );

  return res.status(202).json({
    step_id: step.id,
    cluster_id: activeCluster.id,
    cluster_instance_id: activeClusterInstanceId,
    job_id: job.id,
    job_type: job.type,
  });
});

app.get("/api/ip-suggestions", async (req, res) => {
  const queryIp = pickFirstString(req.query.management_ip);
  const envManagementIp = pickFirstString(process.env.MANAGEMENT_VM_IP);
  const fallbackHostIp = typeof req.hostname === "string" ? req.hostname : "";
  const managementIp = queryIp || envManagementIp || fallbackHostIp;
  const nodeCount = parseNodeCount(pickFirstString(req.query.node_count));
  const parsedManagementIp = parseIPv4(managementIp, "management_ip");

  if (!parsedManagementIp.ok) {
    return res.status(400).json({
      error: "management_ip must be a valid IPv4 address",
    });
  }

  try {
    return res.json(await suggestAllocation(parsedManagementIp.value, nodeCount));
  } catch (e) {
    return res.status(500).json({
      error: e instanceof Error ? e.message : "failed to suggest IP addresses",
    });
  }
});

app.post("/api/ip-availability", async (req, res) => {
  const ips = Array.isArray(req.body?.ips) ? req.body.ips : [];
  const normalizedIps = [];

  for (const candidate of ips) {
    const parsed = parseIPv4(candidate, "ips");
    if (!parsed.ok) {
      return res.status(400).json({
        error: "ips must contain only valid IPv4 addresses",
      });
    }
    normalizedIps.push(parsed.value);
  }

  if (normalizedIps.length === 0) {
    return res.status(400).json({
      error: "ips is required",
    });
  }

  try {
    return res.json(
      await checkIpAvailability({
        ips: normalizedIps,
        isIpInUse: probeIpInUse,
      })
    );
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to check IP availability",
    });
  }
});

app.post("/api/clusters", async (req, res) => {
  const body = req.body || {};
  try {
    const [proxmoxNodes, proxmoxVms, proxmoxStorages] = await Promise.all([
      listClusterNodeResources(),
      listClusterVmResources(),
      listClusterStorageResources(),
    ]);
    const allowedVmHosts = proxmoxNodes
      .map((entry) => String(entry?.node || entry?.name || entry?.id || "").trim())
      .filter(Boolean);
    if (allowedVmHosts.length === 0) {
      return res.status(400).json({ error: "No Proxmox nodes available to place VMs" });
    }

    const placement = computePlacement({
      nodes: proxmoxNodes,
      vms: proxmoxVms,
      storages: proxmoxStorages,
      controlplaneCount: Number(body.controlplane_count ?? 3),
      workerCount: Number(body.worker_count ?? 0),
      clusterName: body.name ? `twinbox-${normalizeClusterSlug(body.name)}` : "",
    });
    if (!placement.ok) {
      return res.status(400).json({ error: placement.error });
    }

    const built = buildClusterFromRequest(
      {
        ...body,
        vm_node_map: placement.vmNodeMap,
        vm_size_map: placement.vmSizeMap,
        vm_storage_map: placement.vmStorageMap,
      },
      process.env,
      {
        allowedVmHosts,
        allowedVmStorages: proxmoxStorages,
      }
    );
    if (!built.ok) {
      return res.status(400).json({ error: built.error });
    }

    try {
      const allocation = await validateRequestedAllocation({
        startVmid: built.cluster.start_vmid,
        vipIp: built.cluster.vip_ip,
        startIp: built.cluster.start_ip,
        nodeCount: built.cluster.controlplane_count + built.cluster.worker_count,
      });
      if (!allocation.ok) {
        return res.status(400).json({ error: allocation.error });
      }
    } catch (error) {
      return res.status(500).json({
        error: error instanceof Error ? error.message : "failed to validate allocation",
      });
    }

    persistCluster(dirs, built.cluster);
    const job = queueJob(
      dirs,
      "apply_cluster",
      built.cluster.id,
      buildApplyJobPayload(built.cluster)
    );
    return res.status(202).json({
      cluster_id: built.cluster.id,
      cluster_instance_id: built.cluster.cluster_instance_id,
      job_id: job.id,
    });
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to read Proxmox hosts",
    });
  }
});

app.post("/api/clusters/:clusterId/bootstrap", (req, res) => {
  const clusterId = req.params.clusterId;
  const clusterFile = path.join(dirs.clusters, `${clusterId}.json`);

  if (!fs.existsSync(clusterFile)) {
    return res.status(404).json({ error: "cluster not found" });
  }

  const cluster = readJson(clusterFile);
  const requestedClusterInstanceId =
    typeof req.body?.cluster_instance_id === "string" ? req.body.cluster_instance_id.trim() : "";
  if (
    requestedClusterInstanceId &&
    requestedClusterInstanceId !== (cluster.cluster_instance_id || "")
  ) {
    return res.status(409).json({ error: "cluster instance mismatch" });
  }
  const payload = buildBootstrapPayload(cluster, req.body || {});

  const job = queueJob(dirs, "apply_cluster", clusterId, payload);
  return res.status(202).json({
    cluster_id: clusterId,
    cluster_instance_id: cluster.cluster_instance_id || null,
    job_id: job.id,
  });
});

app.post("/api/steps/:stepId/execute", async (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId =
    typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const requestedClusterInstanceId =
    typeof req.body?.cluster_instance_id === "string" ? req.body.cluster_instance_id.trim() : "";
  const catalog = buildCatalogResponse({
    workspaceRoot,
    dirs,
    clusterId: requestedClusterId || null,
  });
  const step = catalog.stepsById.get(stepId);

  if (!step) {
    return res.status(404).json({ error: "step not found" });
  }

  const visibleStep = catalog.categories
    .flatMap((category) => category.steps)
    .find((candidate) => candidate.id === stepId);
  if (!visibleStep) {
    return res.status(404).json({ error: "step not found" });
  }

  const validated = validateStepInputs(step, req.body?.inputs);
  if (!validated.ok) {
    return res.status(400).json({ error: validated.error });
  }

  let clusterId = null;
  let context = {};

  if (stepId === "provision-nodes") {
    try {
      const [proxmoxNodes, proxmoxVms, proxmoxStorages] = await Promise.all([
        listClusterNodeResources(),
        listClusterVmResources(),
        listClusterStorageResources(),
      ]);
      const allowedVmHosts = proxmoxNodes
        .map((entry) => String(entry?.node || entry?.name || entry?.id || "").trim())
        .filter(Boolean);
      if (allowedVmHosts.length === 0) {
        throw new Error("No Proxmox nodes available to validate VM placement");
      }

      const requestedClusterFile = requestedClusterId
        ? path.join(dirs.clusters, `${requestedClusterId}.json`)
        : "";
      const existingCluster =
        requestedClusterFile && fs.existsSync(requestedClusterFile)
          ? readJson(requestedClusterFile)
          : null;
      if (
        requestedClusterInstanceId &&
        existingCluster?.cluster_instance_id &&
        requestedClusterInstanceId !== existingCluster.cluster_instance_id
      ) {
        return res.status(409).json({ error: "cluster instance mismatch" });
      }
      const reuseProvisionClusterInstance = shouldReuseProvisionClusterInstance(
        existingCluster,
        requestedClusterInstanceId
      );

      const placement = computePlacement({
        nodes: proxmoxNodes,
        vms: proxmoxVms,
        storages: proxmoxStorages,
        controlplaneCount: Number(validated.value.controlplane_count ?? 3),
        workerCount: Number(validated.value.worker_count ?? 0),
        clusterName: `twinbox-${normalizeClusterSlug(validated.value.name)}`,
      });
      if (!placement.ok) {
        return res.status(400).json({ error: placement.error });
      }

      const built = buildClusterFromRequest(
        {
          ...validated.value,
          vm_ip_map: req.body?.vm_ip_map,
          vm_size_map: placement.vmSizeMap,
          vm_node_map: placement.vmNodeMap,
          vm_storage_map: placement.vmStorageMap,
        },
        process.env,
        {
          allowedVmHosts,
          allowedVmStorages: proxmoxStorages,
          clusterInstanceId: reuseProvisionClusterInstance ? requestedClusterInstanceId : null,
        }
      );
      if (!built.ok) {
        return res.status(400).json({ error: built.error });
      }

      const capacity = validateProxmoxCapacity({
        cluster: built.cluster,
        nodes: proxmoxNodes,
        vms: proxmoxVms,
        storages: proxmoxStorages,
        existingCluster: reuseProvisionClusterInstance ? existingCluster : null,
      });
      if (!capacity.ok) {
        return res.status(400).json({ error: capacity.error });
      }

      persistCluster(dirs, built.cluster);
      clusterId = built.cluster.id;
      context = { cluster: built.cluster };
    } catch (error) {
      return res.status(500).json({
        error: error instanceof Error ? error.message : "failed to read Proxmox hosts",
      });
    }
  } else if (isClusterScopedStep(step)) {
    const requestedCluster = resolveRequestedCluster(req.body?.cluster_id);
    if (!requestedCluster.ok) {
      return res.status(requestedCluster.status || 400).json({ error: requestedCluster.error });
    }
    if (
      requestedClusterInstanceId &&
      requestedCluster.cluster.cluster_instance_id &&
      requestedClusterInstanceId !== requestedCluster.cluster.cluster_instance_id
    ) {
      return res.status(409).json({ error: "cluster instance mismatch" });
    }
    clusterId = requestedCluster.cluster.id;
    context = { cluster: requestedCluster.cluster };
  }

  const jobInputs = prepareStepInputs(step, validated.value, clusterId);
  const payload = {
    step_id: step.id,
    step_type: step.type,
    inputs: jobInputs,
    runner: step.runner,
    context,
  };
  if (stepId === "provision-nodes" && context.cluster) {
    payload.secret_bundle = buildApplyJobPayload(context.cluster).secret_bundle;
  } else if (
    step.secrets &&
    (Object.keys(step.secrets.env || {}).length > 0 ||
      Object.keys(step.secrets.files || {}).length > 0)
  ) {
    payload.secret_bundle = normalizeSecretBundle(step.secrets);
  }
  const job = queueJob(dirs, "run_step", clusterId, payload);
  const clusterInstanceId = context?.cluster?.cluster_instance_id || null;

  writeStepState(
    step.id,
    {
      status: "pending",
      inputs: jobInputs,
      outputs: null,
      error: null,
      last_job_id: job.id,
      cluster_id: clusterId,
      cluster_instance_id: clusterInstanceId,
    },
    isClusterScopedStep(step) ? clusterInstanceId || clusterId : null
  );

  return res.status(202).json({
    step_id: step.id,
    cluster_id: clusterId,
    cluster_instance_id: context?.cluster?.cluster_instance_id || null,
    job_id: job.id,
    job_type: job.type,
  });
});

app.post("/api/steps/:stepId/skip", (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId =
    typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const catalog = buildCatalogResponse({
    workspaceRoot,
    dirs,
    clusterId: requestedClusterId || null,
  });
  const step = catalog.stepsById.get(stepId);

  if (!step) {
    return res.status(404).json({ error: "step not found" });
  }

  const visibleStep = catalog.categories
    .flatMap((category) => category.steps)
    .find((candidate) => candidate.id === stepId);
  if (!visibleStep) {
    return res.status(404).json({ error: "step not found" });
  }

  if (visibleStep.status === "running") {
    return res.status(409).json({ error: "cannot skip a running step" });
  }

  if (visibleStep.status === "done") {
    return res.status(409).json({ error: "cannot skip a completed step" });
  }

  const clusterScopeId = isClusterScopedStep(visibleStep)
    ? requestedClusterId || catalog.activeClusterScopeId || null
    : null;

  writeStepState(
    stepId,
    {
      status: "skipped",
      inputs: {},
      outputs: null,
      error: null,
      last_job_id: null,
    },
    clusterScopeId
  );

  return res.status(200).json({
    step_id: stepId,
    status: "skipped",
  });
});

app.post("/api/steps/:stepId/unskip", (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId =
    typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const catalog = buildCatalogResponse({
    workspaceRoot,
    dirs,
    clusterId: requestedClusterId || null,
  });
  const step = catalog.stepsById.get(stepId);

  if (!step) {
    return res.status(404).json({ error: "step not found" });
  }

  const visibleStep = catalog.categories
    .flatMap((category) => category.steps)
    .find((candidate) => candidate.id === stepId);
  if (!visibleStep) {
    return res.status(404).json({ error: "step not found" });
  }

  if (visibleStep.status !== "skipped") {
    return res.status(409).json({ error: "step is not skipped" });
  }

  const clusterScopeId = isClusterScopedStep(visibleStep)
    ? requestedClusterId || catalog.activeClusterScopeId || null
    : null;

  const file = stepStatePath(stepId, clusterScopeId);
  if (fs.existsSync(file)) {
    fs.unlinkSync(file);
  }

  return res.status(200).json({
    step_id: stepId,
    status: "ready",
  });
});

app.get("/api/clusters/:clusterId", (req, res) => {
  const file = path.join(dirs.clusters, `${req.params.clusterId}.json`);
  if (!fs.existsSync(file)) {
    return res.status(404).json({ error: "cluster not found" });
  }
  return res.json(ensureClusterResourceProfile(readJson(file)));
});

app.get("/api/clusters/:clusterId/pressure", (req, res) => {
  try {
    const cluster = ensureClusterResourceProfile(loadCluster(dirs, req.params.clusterId));
    return res.json(readClusterPressure(cluster));
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to read cluster pressure",
    });
  }
});

app.put("/api/clusters/:clusterId/observability", (req, res) => {
  try {
    const file = path.join(dirs.clusters, `${req.params.clusterId}.json`);
    if (!fs.existsSync(file)) {
      return res.status(404).json({ error: "cluster not found" });
    }

    const cluster = ensureClusterResourceProfile(readJson(file));
    const profile = normalizeObservabilityProfile(req.body?.profile);
    const clusterInstanceId = cluster.cluster_instance_id || cluster.instance_id || null;
    const updatedCluster = {
      ...cluster,
      observability_profile: profile,
      observability_status: "applying",
      observability_error: null,
      observability_last_job_id: null,
      observability_updated_at: now(),
      updated_at: now(),
    };

    persistCluster(dirs, updatedCluster);
    const job = queueJob(
      dirs,
      "reconcile_observability",
      updatedCluster.id,
      buildApplyJobPayload(updatedCluster)
    );
    persistCluster(dirs, {
      ...updatedCluster,
      observability_last_job_id: job.id,
      observability_status: "applying",
      observability_updated_at: now(),
    });

    return res.status(202).json({
      cluster_id: updatedCluster.id,
      cluster_instance_id: clusterInstanceId,
      observability_profile: profile,
      observability_status: "applying",
      job_id: job.id,
      cluster: updatedCluster,
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to update observability",
    });
  }
});

function resolveUpgradeCluster(clusterId) {
  const resolved = resolveRequestedCluster(clusterId);
  if (!resolved.ok) {
    const error = new Error(resolved.error || "cluster not found");
    error.status = resolved.status || 404;
    throw error;
  }
  return resolved.cluster;
}

function queueUpgradeJob(cluster, phase, type) {
  const current = readUpgradeState(dirs, cluster.id);
  if (isUpgradeMaintenanceActive(current)) {
    const error = new Error(`cluster maintenance is already active (${current.phase})`);
    error.status = 409;
    throw error;
  }

  const payload = {
    phase,
    cluster,
    secret_bundle: buildClusterWorkerSecretBundle(cluster),
  };
  const job = queueJob(dirs, type, cluster.id, payload);
  const state = writeUpgradeState(dirs, cluster.id, {
    phase,
    status: phase === "inspect" ? "inspecting" : "pending",
    active_job_id: job.id,
    last_job_id: job.id,
    pause_requested: false,
    resumable: false,
    error: null,
  });
  return { job, state };
}

app.get("/api/clusters/:clusterId/upgrades", (req, res) => {
  try {
    resolveUpgradeCluster(req.params.clusterId);
    return res.json(readUpgradeState(dirs, req.params.clusterId));
  } catch (error) {
    return res.status(error?.status || 500).json({ error: error.message });
  }
});

app.post("/api/clusters/:clusterId/upgrades/refresh", (req, res) => {
  try {
    const cluster = resolveUpgradeCluster(req.params.clusterId);
    const { job, state } = queueUpgradeJob(cluster, "inspect", "inspect_cluster_upgrades");
    return res.status(202).json({ job_id: job.id, state });
  } catch (error) {
    return res.status(error?.status || 500).json({ error: error.message });
  }
});

app.post("/api/clusters/:clusterId/upgrades/talos", (req, res) => {
  try {
    const cluster = resolveUpgradeCluster(req.params.clusterId);
    const current = readUpgradeState(dirs, cluster.id);
    if (!current.inspected_at || current.status === "inspection_failed") {
      return res.status(409).json({ error: "run a successful upgrade inspection first" });
    }
    const { job, state } = queueUpgradeJob(cluster, "talos", "upgrade_talos");
    return res.status(202).json({ job_id: job.id, state });
  } catch (error) {
    return res.status(error?.status || 500).json({ error: error.message });
  }
});

app.post("/api/clusters/:clusterId/upgrades/kubernetes", (req, res) => {
  try {
    const cluster = resolveUpgradeCluster(req.params.clusterId);
    const current = readUpgradeState(dirs, cluster.id);
    if (current.status !== "talos_completed" && current.status !== "kubernetes_completed") {
      return res.status(409).json({ error: "complete the Talos upgrade first" });
    }
    const { job, state } = queueUpgradeJob(cluster, "kubernetes", "upgrade_kubernetes");
    return res.status(202).json({ job_id: job.id, state });
  } catch (error) {
    return res.status(error?.status || 500).json({ error: error.message });
  }
});

app.post("/api/clusters/:clusterId/upgrades/resume", (req, res) => {
  try {
    const cluster = resolveUpgradeCluster(req.params.clusterId);
    const current = readUpgradeState(dirs, cluster.id);
    if (!current.resumable || !["talos", "kubernetes"].includes(current.phase)) {
      return res.status(409).json({ error: "there is no resumable upgrade phase" });
    }
    const type = current.phase === "talos" ? "upgrade_talos" : "upgrade_kubernetes";
    const { job, state } = queueUpgradeJob(cluster, current.phase, type);
    return res.status(202).json({ job_id: job.id, state });
  } catch (error) {
    return res.status(error?.status || 500).json({ error: error.message });
  }
});

app.post("/api/clusters/:clusterId/upgrades/pause", (req, res) => {
  try {
    resolveUpgradeCluster(req.params.clusterId);
    const current = readUpgradeState(dirs, req.params.clusterId);
    if (!isUpgradeMaintenanceActive(current)) {
      return res.status(409).json({ error: "no running maintenance phase to pause" });
    }
    return res.json(
      writeUpgradeState(dirs, req.params.clusterId, {
        status: "pause_requested",
        pause_requested: true,
      })
    );
  } catch (error) {
    return res.status(error?.status || 500).json({ error: error.message });
  }
});

app.get("/api/jobs/:jobId", (req, res) => {
  const file = path.join(dirs.jobs, `${req.params.jobId}.json`);
  if (!fs.existsSync(file)) {
    return res.status(404).json({ error: "job not found" });
  }
  return res.json(readJson(file));
});

app.get("/api/jobs/:jobId/logs", (req, res) => {
  const file = path.join(dirs.logs, `${req.params.jobId}.log`);
  if (!fs.existsSync(file)) {
    return res.json({ lines: [] });
  }

  const lines = fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => ({ line }));
  return res.json({ lines });
});

app.post("/api/jobs/:jobId/cancel", (req, res) => {
  try {
    const job = cancelJob(dirs, req.params.jobId);
    if (!job) {
      return res.status(404).json({ error: "job not found" });
    }
    return res.json({ job_id: job.id, status: job.status });
  } catch (error) {
    if (error?.code === "JOB_NOT_CANCELABLE") {
      return res.status(409).json({ error: error.message });
    }
    return res.status(500).json({ error: error?.message || "failed to cancel job" });
  }
});

function ensureWizardStateFilePath(file) {
  if (!fs.existsSync(file)) {
    return;
  }

  const stat = fs.statSync(file);
  if (!stat.isDirectory()) {
    return;
  }

  try {
    const backup = `${file}.dir-backup-${Date.now()}`;
    fs.renameSync(file, backup);
  } catch (error) {
    if (error?.code !== "ENOENT") {
      throw error;
    }
  }
}

ensureWizardStateFilePath(dataFiles.wizardState);

function normalizeWizardState(value = {}) {
  const answers =
    value.answers && typeof value.answers === "object" && !Array.isArray(value.answers)
      ? value.answers
      : {};
  const sanitizedAnswers = structuredClone(answers);
  for (const stepAnswers of Object.values(sanitizedAnswers)) {
    if (!stepAnswers || typeof stepAnswers !== "object" || Array.isArray(stepAnswers)) continue;
    delete stepAnswers.s3_access_key_id;
    delete stepAnswers.s3_secret_access_key;
  }

  return {
    selectedStepId: typeof value.selectedStepId === "string" ? value.selectedStepId : "",
    wizardPhase: value.wizardPhase === "install" ? "install" : "questions",
    answers: sanitizedAnswers,
    clusterId: typeof value.clusterId === "string" ? value.clusterId : "",
    clusterCreatedAt: typeof value.clusterCreatedAt === "string" ? value.clusterCreatedAt : "",
    clusterInstanceId: typeof value.clusterInstanceId === "string" ? value.clusterInstanceId : "",
  };
}

app.get("/api/wizard/state", (_, res) => {
  try {
    const state = normalizeWizardState(readJsonIfExists(dataFiles.wizardState) || {});
    return res.json(state);
  } catch {
    return res.status(500).json({ error: "failed to read wizard state" });
  }
});

app.put("/api/wizard/state", (req, res) => {
  try {
    const normalized = normalizeWizardState(req.body || {});
    writeJson(dataFiles.wizardState, normalized);
    return res.json(normalized);
  } catch {
    return res.status(500).json({ error: "failed to write wizard state" });
  }
});

app.get("/api/agents/provider", (req, res) => {
  const config = readAgentProviderConfig(dirs);
  return res.json({
    config,
    hasApiKey: hasAgentApiKey(dirs),
  });
});

app.post("/api/agents/provider/openai-compatible", (req, res) => {
  try {
    const { displayName, baseUrl, model, apiKey, apiKeyMode, timeoutMs } = req.body || {};
    const normalized = normalizeOpenAICompatibleProvider({
      displayName,
      baseUrl,
      model,
      timeoutMs,
    });

    if (!normalized.ok) {
      return res.status(400).json({ error: normalized.error });
    }

    writeAgentProviderConfig(dirs, normalized.value);

    if (typeof apiKey === "string" && apiKey.trim()) {
      writeAgentEndpointSecret(process.env, apiKey.trim());
    } else if (apiKeyMode === "clear") {
      clearAgentEndpointSecret(process.env);
    }

    ensureAgentInternalToken(process.env);
    const job = queueAgentConfigSyncForLatestCluster(dirs);
    return res.json({
      ...normalized.value,
      hasApiKey: hasAgentApiKey(dirs),
      job_id: job.id,
    });
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to save provider config",
    });
  }
});

app.post("/api/agents/provider/test", async (req, res) => {
  try {
    const { baseUrl, model, apiKey, useStoredApiKey, timeoutMs } = req.body || {};
    const resolvedApiKey = resolveAgentProviderTestApiKey(
      { apiKey, useStoredApiKey },
      useStoredApiKey === true ? readAgentEndpointSecret(dirs) : null
    );

    if (!baseUrl) {
      return res.status(400).json({ error: "baseUrl is required" });
    }

    if (!model) {
      return res.status(400).json({ error: "model is required" });
    }

    const url = `${baseUrl.replace(/\/+$/, "")}/models`;
    const timeout = Number.isFinite(Number(timeoutMs)) ? Math.max(1000, Number(timeoutMs)) : 10000;
    const start = Date.now();

    let response;
    try {
      response = await fetch(url, {
        headers: resolvedApiKey ? { Authorization: `Bearer ${resolvedApiKey}` } : {},
        signal: AbortSignal.timeout(timeout),
      });
    } catch (fetchError) {
      const latencyMs = Date.now() - start;
      return res.json({
        status: "error",
        latencyMs,
        message: fetchError instanceof Error ? fetchError.message : "connection failed",
      });
    }

    const latencyMs = Date.now() - start;
    if (response.ok) {
      return res.json({ status: "ok", latencyMs, message: "Provider responded successfully" });
    }
    return res.json({
      status: "error",
      latencyMs,
      message: `Provider returned HTTP ${response.status}`,
    });
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to test provider",
    });
  }
});

app.post("/api/agents/sync-config", (req, res) => {
  try {
    ensureAgentInternalToken(process.env);
    const job = queueAgentConfigSyncForLatestCluster(dirs);
    return res.json({ job_id: job.id });
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to queue agent config sync",
    });
  }
});

const isTestEnv = process.env.NODE_ENV === "test" || process.env.MANAGER_API_TEST === "true";
if (!isTestEnv) {
  app.listen(port, () => {
    console.log(`manager-api listening on ${port}`);
  });
}

export { app };
