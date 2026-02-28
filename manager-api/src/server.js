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
  const required = ["name", "controlplane_count", "worker_count", "cpu_cores", "memory_mb", "disk_gb", "bridge", "start_vmid", "vip_ip", "start_ip"];
  const missing = required.filter((k) => body[k] === undefined || body[k] === null || body[k] === "");

  if (missing.length > 0) {
    return res.status(400).json({ error: `missing required fields: ${missing.join(", ")}` });
  }

  const clusterId = id("cluster");
  const cluster = {
    id: clusterId,
    name: String(body.name),
    controlplane_count: Number(body.controlplane_count),
    worker_count: Number(body.worker_count),
    cpu_cores: Number(body.cpu_cores),
    memory_mb: Number(body.memory_mb),
    disk_gb: Number(body.disk_gb),
    bridge: String(body.bridge),
    start_vmid: Number(body.start_vmid),
    vip_ip: String(body.vip_ip),
    start_ip: String(body.start_ip),
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
