import fs from "fs";
import path from "path";

import { id, now, writeJson } from "./common.js";

export const CANCELABLE_JOB_STATUSES = new Set(["pending", "running", "cancel_requested"]);

function resolveClusterInstanceId(payload = {}) {
  return (
    payload?.cluster_instance_id ||
    payload?.context?.cluster?.cluster_instance_id ||
    payload?.context?.cluster?.instance_id ||
    payload?.cluster?.cluster_instance_id ||
    null
  );
}

export function queueJob(dirs, type, clusterId, payload) {
  const clusterInstanceId = resolveClusterInstanceId(payload);
  const jobId = id("job");
  const job = {
    id: jobId,
    type,
    cluster_id: clusterId,
    cluster_instance_id: clusterInstanceId,
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
    cluster_instance_id: clusterInstanceId,
    payload,
    queued_at: now(),
  });

  fs.appendFileSync(path.join(dirs.logs, `${jobId}.log`), `[${now()}] queued ${type}\n`);
  return job;
}

export function cancelJob(dirs, jobId) {
  const jobFile = path.join(dirs.jobs, `${jobId}.json`);
  if (!fs.existsSync(jobFile)) {
    return null;
  }

  const job = JSON.parse(fs.readFileSync(jobFile, "utf8"));
  if (!CANCELABLE_JOB_STATUSES.has(job.status)) {
    const error = new Error(`job cannot be canceled from status ${job.status}`);
    error.code = "JOB_NOT_CANCELABLE";
    throw error;
  }

  const nextJob = {
    ...job,
    status: job.status === "pending" ? "canceled" : "cancel_requested",
    step: job.status === "pending" ? "canceled" : "cancel_requested",
    error: null,
    updated_at: now(),
    finished_at: job.status === "pending" ? now() : job.finished_at || null,
  };

  writeJson(jobFile, nextJob);

  if (job.status === "pending") {
    if (dirs.pending) {
      fs.rmSync(path.join(dirs.pending, `${jobId}.json`), { force: true });
    }
    if (dirs.running) {
      fs.rmSync(path.join(dirs.running, `${jobId}.json`), { force: true });
    }
    if (dirs.completed) {
      fs.rmSync(path.join(dirs.completed, `${jobId}.json`), { force: true });
    }
    if (dirs.logs) {
      fs.appendFileSync(
        path.join(dirs.logs, `${jobId}.log`),
        `[${now()}] job canceled before start\n`
      );
    }
  } else {
    if (dirs.logs) {
      fs.appendFileSync(path.join(dirs.logs, `${jobId}.log`), `[${now()}] cancel requested\n`);
    }
  }

  return nextJob;
}
