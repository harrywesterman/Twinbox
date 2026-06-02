import fs from "fs";
import path from "path";

import { now, readJsonIfExists, writeJson } from "./common.js";

export const ACTIVE_UPGRADE_STATUSES = new Set(["pending", "running", "pause_requested"]);

export function defaultUpgradeState(clusterId) {
  return {
    cluster_id: clusterId,
    phase: "idle",
    status: "idle",
    active_job_id: null,
    last_job_id: null,
    pause_requested: false,
    resumable: false,
    error: null,
    inspected_at: null,
    inventory: null,
    upstream: null,
    paths: {
      talos: [],
      kubernetes: [],
    },
    checkpoints: {
      talos: [],
      kubernetes: [],
    },
    longhorn_maintenance: {
      active: false,
      original_policy: null,
    },
    updated_at: now(),
  };
}

export function upgradeStatePath(dirs, clusterId) {
  return path.join(dirs.upgradeState, `${clusterId}.json`);
}

export function readUpgradeState(dirs, clusterId) {
  return readJsonIfExists(upgradeStatePath(dirs, clusterId)) || defaultUpgradeState(clusterId);
}

export function writeUpgradeState(dirs, clusterId, patch) {
  const current = readUpgradeState(dirs, clusterId);
  const next = {
    ...current,
    ...patch,
    cluster_id: clusterId,
    updated_at: now(),
  };
  writeJson(upgradeStatePath(dirs, clusterId), next);
  return next;
}

export function isUpgradeMaintenanceActive(state) {
  return ACTIVE_UPGRADE_STATUSES.has(state?.status);
}

export function assertNoUpgradeMaintenance(dirs, clusterId) {
  if (!clusterId) return;
  const state = readUpgradeState(dirs, clusterId);
  if (!isUpgradeMaintenanceActive(state)) return;
  const error = new Error(`cluster maintenance is active (${state.phase})`);
  error.status = 409;
  throw error;
}

export function removeUpgradeState(dirs, clusterId) {
  fs.rmSync(upgradeStatePath(dirs, clusterId), { force: true });
}
