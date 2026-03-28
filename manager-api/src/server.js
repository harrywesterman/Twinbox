import express from "express";
import fs from "fs";
import path from "path";
import { spawnSync } from "child_process";

import {
  buildApplyJobPayload,
  buildBootstrapPayload,
  buildClusterFromRequest,
  normalizeClusterName,
  persistCluster,
} from "./lib/clusters.js";
import { buildCatalogResponse, validateStepInputs } from "./lib/catalog.js";
import {
  buildDataDirs,
  ensureDir,
  now,
  parseIPv4,
  pickFirstString,
  readJson,
  writeJson,
} from "./lib/common.js";
import { queueJob } from "./lib/jobs.js";
import { createSecretBroker } from "../../lib/secrets/broker.mjs";
import {
  buildProxmoxApiSecretBundle,
  normalizeSecretBaseRef,
  normalizeSecretBundle,
} from "../../lib/secrets/schema.mjs";

const app = express();
const port = Number(process.env.MANAGER_API_PORT || 8080);
const dataRoot = process.env.MANAGER_DATA_DIR || "/data";
const workspaceRoot = process.env.WORKSPACE_ROOT || process.cwd();
const dirs = buildDataDirs(dataRoot);
const secretBroker = createSecretBroker(process.env);

Object.values(dirs).forEach((dir) => ensureDir(dir));

app.use(express.json());

function parseNodeCount(value, fallback = 3) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 215) {
    return fallback;
  }
  return parsed;
}

function preferredVipOctets() {
  const values = [];
  for (let octet = 50; octet <= 240; octet += 1) values.push(octet);
  for (let octet = 241; octet <= 254; octet += 1) values.push(octet);
  for (let octet = 2; octet < 50; octet += 1) values.push(octet);
  return values;
}

function preferredStartOctets() {
  const values = [];
  for (let octet = 50; octet <= 252; octet += 1) values.push(octet);
  for (let octet = 2; octet < 50; octet += 1) values.push(octet);
  return values;
}

function preferredStartOctetsForVip(vipOctet) {
  const baseline = preferredStartOctets().filter((octet) => octet !== vipOctet + 1);
  if (Number.isInteger(vipOctet + 1) && vipOctet + 1 <= 252) {
    return [vipOctet + 1, ...baseline];
  }
  return baseline;
}

function probeIpInUse(ip) {
  const pingBin = process.env.MANAGER_API_PING_BIN || "ping";
  const isDefaultPing = path.basename(pingBin) === "ping";
  const args = isDefaultPing
    ? (process.platform === "darwin"
      ? ["-n", "-c", "1", "-W", "200", ip]
      : ["-n", "-c", "1", "-W", "0.2", ip])
    : [ip];
  const result = spawnSync(pingBin, args, {
    stdio: "ignore",
    timeout: 700,
  });

  if (result.error?.code === "ENOENT") {
    throw new Error(`Ping command not found: ${pingBin}`);
  }

  return result.status === 0;
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
    throw new Error(result.stderr?.trim() || result.stdout?.trim() || `Proxmox API ${method} ${pathname} failed`);
  }

  try {
    return JSON.parse(result.stdout || "{}");
  } catch (error) {
    throw new Error(`Failed to parse Proxmox API response: ${error instanceof Error ? error.message : "unknown error"}`);
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

  return { ok: true, cluster: readJson(clusterFile) };
}

async function listUsedVmidsViaProxmoxApi() {
  const resolved = secretBroker.resolveBundle(buildProxmoxApiSecretBundle());

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
        : [],
    );
  } finally {
    resolved.cleanup();
  }
}

async function listClusterNodeResourcesViaProxmoxApi() {
  const resolved = secretBroker.resolveBundle(buildProxmoxApiSecretBundle());

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

    return Array.isArray(resources?.data) ? resources.data : [];
  } finally {
    resolved.cleanup();
  }
}

async function listClusterVmResourcesViaProxmoxApi() {
  const resolved = secretBroker.resolveBundle(buildProxmoxApiSecretBundle());

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
    throw new Error(`Cluster resources lookup failed: ${(result.stderr || result.stdout || "").trim()}`);
  }

  try {
    const parsed = JSON.parse(result.stdout || "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    throw new Error(`Failed to parse cluster VM resources: ${error instanceof Error ? error.message : "unknown error"}`);
  }
}

async function listUsedVmids() {
  const resourcesBin = process.env.MANAGER_API_CLUSTER_RESOURCES_BIN || "pvesh";
  const isDefaultResourcesBin = path.basename(resourcesBin) === "pvesh";
  const args = isDefaultResourcesBin ? ["get", "/cluster/resources", "--type", "vm", "--output-format", "json"] : [];
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
          .map(Number),
      );
    }
    throw new Error(`Cluster resources command not found: ${resourcesBin}`);
  }

  if (result.status !== 0) {
    throw new Error(`Cluster resources lookup failed: ${(result.stderr || result.stdout || "").trim()}`);
  }

  try {
    const parsed = JSON.parse(result.stdout || "[]");
    return new Set(
      Array.isArray(parsed)
        ? parsed
          .map((entry) => Number(entry?.vmid))
          .filter((value) => Number.isInteger(value) && value >= 100)
        : [],
    );
  } catch (error) {
    throw new Error(`Failed to parse cluster VM resources: ${error instanceof Error ? error.message : "unknown error"}`);
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
    throw new Error(`Cluster resources lookup failed: ${(result.stderr || result.stdout || "").trim()}`);
  }

  try {
    const parsed = JSON.parse(result.stdout || "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    throw new Error(`Failed to parse cluster node resources: ${error instanceof Error ? error.message : "unknown error"}`);
  }
}

function summarizeClusterResources(resources, vmResources = []) {
  const MB = 1024 * 1024;
  const GB = 1024 * 1024 * 1024;
  const nodes = Array.isArray(resources) ? resources : [];
  const vms = Array.isArray(vmResources) ? vmResources : [];
  const activeVmCounts = vms.reduce((accumulator, entry) => {
    const node = String(entry?.node || "").trim();
    const status = String(entry?.status || entry?.qmpstatus || "").trim().toLowerCase();
    if (!node || (status && status !== "running")) {
      return accumulator;
    }
    accumulator[node] = (accumulator[node] || 0) + 1;
    return accumulator;
  }, {});

  const summary = nodes.reduce((accumulator, entry) => {
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
  }, {
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
  });

  summary.freeMemoryMb = Math.max(0, summary.totalMemoryMb - summary.usedMemoryMb);
  summary.freeDiskGb = Math.max(0, summary.totalDiskGb - summary.usedDiskGb);
  summary.freeCpuCores = Math.max(0, summary.totalCpuCores - summary.usedCpuCores);

  return {
    nodes: nodes.map((entry) => ({
      ...entry,
      activeVmCount: activeVmCounts[String(entry?.node || entry?.name || entry?.id || "").trim()] || 0,
    })),
    summary,
  };
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

function buildIpBlock(prefix, startOctet, nodeCount) {
  return Array.from({ length: nodeCount }, (_, offset) => `${prefix}.${startOctet + offset}`);
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
  const lines = output.split("\n").map((line) => line.trim()).filter(Boolean);
  const exact = lines.find((line) => line.includes(` inet ${managementIp}/`));
  const match = (exact || lines[0] || "").match(/\binet\s+\d+\.\d+\.\d+\.\d+\/(\d+)/);
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
  const normalized = String(domain || "").trim().toLowerCase();
  return normalized === "localdomain" || normalized === "localhost.localdomain";
}

function detectDnsDefaults() {
  const resolvConf = process.env.MANAGER_API_RESOLV_CONF || "/etc/resolv.conf";
  if (!fs.existsSync(resolvConf)) {
    return {
      dns_servers: ["1.1.1.1"],
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
    dns_servers: dnsServers.length > 0 ? dnsServers : ["1.1.1.1"],
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
  const octets = managementIp.split(".").map(Number);
  const prefix = `${octets[0]}.${octets[1]}.${octets[2]}`;
  const managementOctet = octets[3];
  const inUseCache = new Map();
  const vipCandidates = preferredVipOctets();
  const networkDefaults = detectHostNetworkDefaults(managementIp);

  const isIpInUse = (hostOctet) => {
    if (inUseCache.has(hostOctet)) {
      return inUseCache.get(hostOctet);
    }
    const inUse = probeIpInUse(`${prefix}.${hostOctet}`);
    inUseCache.set(hostOctet, inUse);
    return inUse;
  };

  const vmidSuggestion = await findFreeVmidBlock(nodeCount);
  let vipOctet = null;
  for (const candidate of vipCandidates) {
    if (candidate === managementOctet) continue;
    if (!isIpInUse(candidate)) {
      vipOctet = candidate;
      break;
    }
  }

  if (vipOctet === null) {
    throw new Error(`No free VIP address found in ${prefix}.0/24`);
  }

  let startOctet = null;
  for (const candidate of preferredStartOctetsForVip(vipOctet)) {
    const block = Array.from({ length: nodeCount }, (_, offset) => candidate + offset);
    if (block.some((octet) => octet > 254 || octet === managementOctet || octet === vipOctet)) {
      continue;
    }
    if (block.every((octet) => !isIpInUse(octet))) {
      startOctet = candidate;
      break;
    }
  }

  if (startOctet === null) {
    throw new Error(`No free consecutive ${nodeCount}-IP block found in ${prefix}.0/24`);
  }

  const ipBlock = buildIpBlock(prefix, startOctet, nodeCount);
  return {
    management_ip: managementIp,
    subnet: `${prefix}.0/24`,
    node_count: nodeCount,
    name_suggestion: suggestClusterName(),
    start_vmid: vmidSuggestion.start_vmid,
    vmid_block: vmidSuggestion.vmid_block,
    vip_ip: `${prefix}.${vipOctet}`,
    start_ip: `${prefix}.${startOctet}`,
    start_ip_block: ipBlock,
    node_prefix_length: networkDefaults.node_prefix_length,
    gateway_ip: networkDefaults.gateway_ip,
    dns_servers: networkDefaults.dns_servers,
    dns_domain: networkDefaults.dns_domain,
    probed_addresses: inUseCache.size,
  };
}

async function validateRequestedAllocation({ startVmid, vipIp, startIp, nodeCount }) {
  const usedVmids = await listUsedVmids();
  const requestedVmids = Array.from({ length: nodeCount }, (_, offset) => startVmid + offset);
  if (!requestedVmids.every((vmid) => !usedVmids.has(vmid))) {
    return {
      ok: false,
      error: `VMID range ${requestedVmids[0]}-${requestedVmids[requestedVmids.length - 1]} is not free`,
    };
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

  if (probeIpInUse(vipIp)) {
    return { ok: false, error: `VIP IP ${vipIp} is already in use` };
  }

  const occupiedIp = ipBlock.find((ip) => probeIpInUse(ip));
  if (occupiedIp) {
    return { ok: false, error: `Node IP ${occupiedIp} is already in use` };
  }

  return { ok: true };
}

function readStepState(stepId) {
  const file = path.join(dirs.stepState, `${stepId}.json`);
  if (!fs.existsSync(file)) {
    return null;
  }
  return readJson(file);
}

function writeStepState(stepId, patch) {
  const file = path.join(dirs.stepState, `${stepId}.json`);
  const current = readStepState(stepId) || {
    step_id: stepId,
    status: "not_started",
    inputs: {},
    outputs: null,
    cluster_id: null,
    error: null,
    last_job_id: null,
    created_at: now(),
  };

  const next = {
    ...current,
    ...patch,
    step_id: stepId,
    updated_at: now(),
  };
  writeJson(file, next);
  return next;
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

function resolveSecretValue(item, source, property) {
  const resolvedSource = String(source || "login").trim() || "login";
  const resolvedProperty = String(property || "").trim();

  if (!resolvedProperty) {
    throw new Error("secret property is required");
  }

  if (resolvedSource === "login") {
    const value = item?.login?.[resolvedProperty];
    if (typeof value !== "string" || !value.trim()) {
      throw new Error(`secret login property ${resolvedProperty} is not available`);
    }
    return value;
  }

  if (resolvedSource === "field") {
    const fields = Array.isArray(item?.fields) ? item.fields : [];
    const match = fields.find((field) => String(field?.name || "").trim() === resolvedProperty);
    const value = match?.value;
    if (typeof value !== "string" || !value.trim()) {
      throw new Error(`secret field ${resolvedProperty} is not available`);
    }
    return value;
  }

  throw new Error(`unsupported secret source ${resolvedSource}`);
}

app.get("/api/health", (_, res) => {
  res.json({ ok: true, time: now() });
});

app.get("/api/secrets/*", (req, res) => {
  const secretKeyPath = decodeURIComponent(String(req.originalUrl || "").split("/api/secrets/")[1] || "");

  try {
    const ref = parseSecretKeyPath(secretKeyPath);
    const item = secretBroker.getItem(ref);
    return res.json({ data: item });
  } catch (error) {
    const message = error instanceof Error ? error.message : "failed to resolve secret";
    const status = message.includes("not found") ? 404 : 400;
    return res.status(status).json({ error: message });
  }
});

app.get("/api/secret-values/*", (req, res) => {
  const secretKeyPath = decodeURIComponent(String(req.path || "").split("/api/secret-values/")[1] || "");
  const source = pickFirstString(req.query.source) || "login";
  const property = pickFirstString(req.query.property);

  try {
    const ref = parseSecretKeyPath(secretKeyPath);
    const item = secretBroker.getItem(ref);
    const value = resolveSecretValue(item, source, property);
    return res.json({ value });
  } catch (error) {
    const message = error instanceof Error ? error.message : "failed to resolve secret value";
    const status = message.includes("not found") || message.includes("not available") ? 404 : 400;
    return res.status(status).json({ error: message });
  }
});

app.get("/api/proxmox/cluster-resources", async (_, res) => {
  try {
    const [nodes, vms] = await Promise.all([
      listClusterNodeResources(),
      listClusterVmResources(),
    ]);
    return res.json(summarizeClusterResources(nodes, vms));
  } catch (error) {
    return res.status(500).json({
      error: error instanceof Error ? error.message : "failed to read cluster resources",
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

  const catalog = buildCatalogResponse({ workspaceRoot, dirs, clusterId: requestedClusterId || null });
  return res.json({
    categories: catalog.categories,
    errors: catalog.errors,
  });
});

app.get("/api/ip-suggestions", async (req, res) => {
  const queryIp = pickFirstString(req.query.management_ip);
  const fallbackHostIp = typeof req.hostname === "string" ? req.hostname : "";
  const managementIp = queryIp || fallbackHostIp;
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

app.post("/api/clusters", async (req, res) => {
  const body = req.body || {};
  const built = buildClusterFromRequest(body, process.env);
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
  } catch (e) {
    return res.status(500).json({
      error: e instanceof Error ? e.message : "failed to validate allocation",
    });
  }

  persistCluster(dirs, built.cluster);
  const job = queueJob(dirs, "apply_cluster", built.cluster.id, buildApplyJobPayload(built.cluster));
  return res.status(202).json({ cluster_id: built.cluster.id, job_id: job.id });
});

app.post("/api/clusters/:clusterId/bootstrap", (req, res) => {
  const clusterId = req.params.clusterId;
  const clusterFile = path.join(dirs.clusters, `${clusterId}.json`);

  if (!fs.existsSync(clusterFile)) {
    return res.status(404).json({ error: "cluster not found" });
  }

  const cluster = readJson(clusterFile);
  const payload = buildBootstrapPayload(cluster, req.body || {});

  const job = queueJob(dirs, "apply_cluster", clusterId, payload);
  return res.status(202).json({ cluster_id: clusterId, job_id: job.id });
});

app.post("/api/steps/:stepId/execute", async (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId = typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const catalog = buildCatalogResponse({ workspaceRoot, dirs, clusterId: requestedClusterId || null });
  const step = catalog.stepsById.get(stepId);

  if (!step) {
    return res.status(404).json({ error: "step not found" });
  }

  const visibleStep = catalog.categories.flatMap((category) => category.steps).find((candidate) => candidate.id === stepId);
  if (visibleStep?.status === "locked") {
    return res.status(409).json({ error: `${stepId} is locked until its dependencies are complete` });
  }

  const validated = validateStepInputs(step, req.body?.inputs);
  if (!validated.ok) {
    return res.status(400).json({ error: validated.error });
  }

  let clusterId = null;
  let context = {};

  if (stepId === "provision-nodes") {
    const built = buildClusterFromRequest({
      ...validated.value,
      vm_node_map: req.body?.vm_node_map,
    }, process.env);
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
    } catch (e) {
      return res.status(500).json({
        error: e instanceof Error ? e.message : "failed to validate allocation",
      });
    }

    persistCluster(dirs, built.cluster);
    clusterId = built.cluster.id;
    context = { cluster: built.cluster };
  } else if (step.category_id === "talos-cluster") {
    const requestedCluster = resolveRequestedCluster(req.body?.cluster_id);
    if (!requestedCluster.ok) {
      return res.status(requestedCluster.status || 400).json({ error: requestedCluster.error });
    }
    clusterId = requestedCluster.cluster.id;
    context = { cluster: requestedCluster.cluster };
  }

  const payload = {
    step_id: step.id,
    step_type: step.type,
    inputs: validated.value,
    runner: step.runner,
    context,
  };
  if (stepId === "provision-nodes" && context.cluster) {
    payload.secret_bundle = buildApplyJobPayload(context.cluster).secret_bundle;
  } else if (step.secrets && (Object.keys(step.secrets.env || {}).length > 0 || Object.keys(step.secrets.files || {}).length > 0)) {
    payload.secret_bundle = normalizeSecretBundle(step.secrets);
  }
  const job = queueJob(dirs, "run_step", clusterId, payload);

  writeStepState(step.id, {
    status: "pending",
    inputs: validated.value,
    outputs: null,
    error: null,
    last_job_id: job.id,
    cluster_id: clusterId,
  });

  return res.status(202).json({
    step_id: step.id,
    cluster_id: clusterId,
    job_id: job.id,
    job_type: job.type,
  });
});

app.get("/api/clusters/:clusterId", (req, res) => {
  const file = path.join(dirs.clusters, `${req.params.clusterId}.json`);
  if (!fs.existsSync(file)) {
    return res.status(404).json({ error: "cluster not found" });
  }
  return res.json(readJson(file));
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

  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => ({ line }));
  return res.json({ lines });
});

app.listen(port, () => {
  console.log(`manager-api listening on ${port}`);
});
