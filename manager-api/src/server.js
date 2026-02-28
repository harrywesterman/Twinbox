import express from "express";
import fs from "fs";
import path from "path";
import crypto from "crypto";

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
      talos_version: body.talos_version || "v1.7.4",
      proxmox_node: body.proxmox_node || process.env.PROXMOX_NODE || "pve",
      storage_pool: body.storage_pool || process.env.PROXMOX_STORAGE_POOL || "local-lvm",
      iso_storage: body.iso_storage || process.env.PROXMOX_ISO_STORAGE || "local",
      talos_iso_file: body.talos_iso_file || process.env.TALOS_ISO_FILE || "talos-v1.7.4.iso",
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
