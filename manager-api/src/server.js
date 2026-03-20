import express from "express";
import fs from "fs";
import path from "path";
import { spawnSync } from "child_process";

import { buildBootstrapPayload, buildClusterFromRequest, loadCluster, persistCluster } from "./lib/clusters.js";
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

const app = express();
const port = Number(process.env.MANAGER_API_PORT || 8080);
const dataRoot = process.env.MANAGER_DATA_DIR || "/data";
const workspaceRoot = process.env.WORKSPACE_ROOT || process.cwd();
const dirs = buildDataDirs(dataRoot);

Object.values(dirs).forEach((dir) => ensureDir(dir));

app.use(express.json());

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

app.get("/api/health", (_, res) => {
  res.json({ ok: true, time: now() });
});

app.get("/api/catalog", (_, res) => {
  const catalog = buildCatalogResponse({ workspaceRoot, dirs });
  return res.json({
    categories: catalog.categories,
    errors: catalog.errors,
  });
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
  const built = buildClusterFromRequest(body, process.env);
  if (!built.ok) {
    return res.status(400).json({ error: built.error });
  }

  persistCluster(dirs, built.cluster);
  const job = queueJob(dirs, "create_cluster", built.cluster.id, built.cluster);
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

  const job = queueJob(dirs, "bootstrap_cluster", clusterId, payload);
  return res.status(202).json({ cluster_id: clusterId, job_id: job.id });
});

app.post("/api/steps/:stepId/execute", (req, res) => {
  const stepId = req.params.stepId;
  const catalog = buildCatalogResponse({ workspaceRoot, dirs });
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
    const built = buildClusterFromRequest(validated.value, process.env);
    if (!built.ok) {
      return res.status(400).json({ error: built.error });
    }

    persistCluster(dirs, built.cluster);
    clusterId = built.cluster.id;
    context = { cluster: built.cluster };
  } else if (stepId === "bootstrap-cluster") {
    const provisionState = readStepState("provision-nodes");
    clusterId = provisionState?.cluster_id || null;
    if (!clusterId) {
      return res.status(409).json({ error: "bootstrap-cluster requires a completed provision-nodes step" });
    }

    const cluster = loadCluster(dirs, clusterId);
    context = buildBootstrapPayload(cluster, {});
  }

  const payload = {
    step_id: step.id,
    step_type: step.type,
    inputs: validated.value,
    runner: step.runner,
    context,
  };
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
