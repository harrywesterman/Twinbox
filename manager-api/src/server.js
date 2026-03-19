import express from "express";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { spawnSync } from "child_process";

const app = express();
const port = Number(process.env.MANAGER_API_PORT || 8080);
const dataRoot = process.env.MANAGER_DATA_DIR || "/data";

const dirs = {
  clusters: path.join(dataRoot, "clusters"),
  jobs: path.join(dataRoot, "jobs"),
  logs: path.join(dataRoot, "logs"),
  pending: path.join(dataRoot, "queue", "pending"),
};

Object.values(dirs).forEach((dir) => fs.mkdirSync(dir, { recursive: true }));

app.use(express.json());

function now() {
  return new Date().toISOString();
}

function id(prefix) {
  return `${prefix}_${crypto.randomUUID().replace(/-/g, "")}`;
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function parseIntInRange(value, field, min, max) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) {
    return { ok: false, error: `${field} must be an integer between ${min} and ${max}` };
  }
  return { ok: true, value: n };
}

function parseRequiredString(value, field) {
  if (typeof value !== "string" || value.trim() === "") {
    return { ok: false, error: `${field} must be a non-empty string` };
  }
  return { ok: true, value: value.trim() };
}

function parseIPv4(value, field) {
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

function pickFirstString(value) {
  if (Array.isArray(value)) {
    return typeof value[0] === "string" ? value[0] : "";
  }
  return typeof value === "string" ? value : "";
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

function probeIpInUse(ip) {
  const pingBin = process.env.MANAGER_API_PING_BIN || "ping";
  const isDefaultPing = path.basename(pingBin) === "ping";
  const args = isDefaultPing ? ["-n", "-c", "1", "-W", "1", ip] : [ip];
  const result = spawnSync(pingBin, args, {
    stdio: "ignore",
    timeout: 1500,
  });

  if (result.error?.code === "ENOENT") {
    throw new Error(`Ping command not found: ${pingBin}`);
  }

  return result.status === 0;
}

function suggestIpRange(managementIp) {
  const octets = managementIp.split(".").map(Number);
  const prefix = `${octets[0]}.${octets[1]}.${octets[2]}`;
  const managementOctet = octets[3];
  const inUseCache = new Map();
  const vipCandidates = preferredVipOctets();
  const startCandidates = preferredStartOctets();

  const isIpInUse = (hostOctet) => {
    if (inUseCache.has(hostOctet)) {
      return inUseCache.get(hostOctet);
    }
    const inUse = probeIpInUse(`${prefix}.${hostOctet}`);
    inUseCache.set(hostOctet, inUse);
    return inUse;
  };

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
  for (const candidate of startCandidates) {
    const block = [candidate, candidate + 1, candidate + 2];
    if (block.some((octet) => octet > 254 || octet === managementOctet || octet === vipOctet)) {
      continue;
    }
    if (block.every((octet) => !isIpInUse(octet))) {
      startOctet = candidate;
      break;
    }
  }

  if (startOctet === null) {
    throw new Error(`No free consecutive 3-IP block found in ${prefix}.0/24`);
  }

  return {
    management_ip: managementIp,
    subnet: `${prefix}.0/24`,
    vip_ip: `${prefix}.${vipOctet}`,
    start_ip: `${prefix}.${startOctet}`,
    start_ip_block: [
      `${prefix}.${startOctet}`,
      `${prefix}.${startOctet + 1}`,
      `${prefix}.${startOctet + 2}`,
    ],
    probed_addresses: inUseCache.size,
  };
}

function queueJob(type, clusterId, payload) {
  const jobId = id("job");
  const job = {
    id: jobId,
    type,
    cluster_id: clusterId,
    status: "pending",
    step: "queued",
    error: null,
    payload,
    created_at: now(),
    updated_at: now(),
    started_at: null,
    finished_at: null,
    result: null,
  };

  writeJson(path.join(dirs.jobs, `${jobId}.json`), job);
  writeJson(path.join(dirs.pending, `${jobId}.json`), {
    id: jobId,
    type,
    cluster_id: clusterId,
    payload,
    queued_at: now(),
  });

  fs.appendFileSync(path.join(dirs.logs, `${jobId}.log`), `[${now()}] queued ${type}\n`);
  return job;
}

app.get("/api/health", (_, res) => {
  res.json({ ok: true, time: now() });
});

app.get("/api/ip-suggestions", (req, res) => {
  const queryIp = pickFirstString(req.query.management_ip);
  const fallbackHostIp = typeof req.hostname === "string" ? req.hostname : "";
  const managementIp = queryIp || fallbackHostIp;
  const parsedManagementIp = parseIPv4(managementIp, "management_ip");

  if (!parsedManagementIp.ok) {
    return res.status(400).json({
      error: "management_ip must be a valid IPv4 address",
    });
  }

  try {
    return res.json(suggestIpRange(parsedManagementIp.value));
  } catch (e) {
    return res.status(500).json({
      error: e instanceof Error ? e.message : "failed to suggest IP addresses",
    });
  }
});

app.post("/api/clusters", (req, res) => {
  const body = req.body || {};

  const parsedName = parseRequiredString(body.name, "name");
  const parsedBridge = parseRequiredString(body.bridge, "bridge");
  const parsedControlplanes = parseIntInRange(body.controlplane_count, "controlplane_count", 1, 15);
  const parsedWorkers = parseIntInRange(body.worker_count, "worker_count", 0, 200);
  const parsedCpu = parseIntInRange(body.cpu_cores, "cpu_cores", 1, 64);
  const parsedMemory = parseIntInRange(body.memory_mb, "memory_mb", 512, 1048576);
  const parsedDisk = parseIntInRange(body.disk_gb, "disk_gb", 10, 8192);
  const parsedStartVmid = parseIntInRange(body.start_vmid, "start_vmid", 100, 999999);
  const parsedVipIp = parseIPv4(body.vip_ip, "vip_ip");
  const parsedStartIp = parseIPv4(body.start_ip, "start_ip");

  const validations = [
    parsedName,
    parsedBridge,
    parsedControlplanes,
    parsedWorkers,
    parsedCpu,
    parsedMemory,
    parsedDisk,
    parsedStartVmid,
    parsedVipIp,
    parsedStartIp,
  ];

  const failed = validations.find((v) => !v.ok);
  if (failed) {
    return res.status(400).json({ error: failed.error });
  }

  const clusterId = id("cluster");
  const cluster = {
    id: clusterId,
    name: parsedName.value,
    controlplane_count: parsedControlplanes.value,
    worker_count: parsedWorkers.value,
    cpu_cores: parsedCpu.value,
    memory_mb: parsedMemory.value,
    disk_gb: parsedDisk.value,
    bridge: parsedBridge.value,
    start_vmid: parsedStartVmid.value,
    vip_ip: parsedVipIp.value,
    start_ip: parsedStartIp.value,
    status: "requested",
    created_at: now(),
    updated_at: now(),
    metadata: {
      proxmox_node: body.proxmox_node || process.env.PROXMOX_NODE || "pve",
      storage_pool: body.storage_pool || process.env.PROXMOX_STORAGE_POOL || "local-lvm",
    },
  };

  writeJson(path.join(dirs.clusters, `${clusterId}.json`), cluster);
  const job = queueJob("create_cluster", clusterId, cluster);

  return res.status(202).json({ cluster_id: clusterId, job_id: job.id });
});

app.post("/api/clusters/:clusterId/bootstrap", (req, res) => {
  const clusterId = req.params.clusterId;
  const clusterFile = path.join(dirs.clusters, `${clusterId}.json`);

  if (!fs.existsSync(clusterFile)) {
    return res.status(404).json({ error: "cluster not found" });
  }

  const cluster = readJson(clusterFile);
  const payload = {
    cluster,
    controlplane_ips: req.body?.controlplane_ips || cluster.controlplane_ips || [],
    worker_ips: req.body?.worker_ips || cluster.worker_ips || [],
    vip_ip: req.body?.vip_ip || cluster.vip_ip,
  };

  const job = queueJob("bootstrap_cluster", clusterId, payload);
  return res.status(202).json({ cluster_id: clusterId, job_id: job.id });
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
