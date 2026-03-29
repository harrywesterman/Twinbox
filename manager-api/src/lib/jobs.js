import fs from "fs";
import path from "path";

import { id, now, writeJson } from "./common.js";

function resolveClusterInstanceId(payload = {}) {
  return payload?.cluster_instance_id
    || payload?.context?.cluster?.cluster_instance_id
    || payload?.context?.cluster?.instance_id
    || payload?.cluster?.cluster_instance_id
    || null;
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
