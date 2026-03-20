import path from "path";

import {
  id,
  now,
  parseIPv4,
  parseIntInRange,
  parseRequiredString,
  readJson,
  writeJson,
} from "./common.js";

export function buildClusterFromRequest(body, env) {
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

  const failed = validations.find((value) => !value.ok);
  if (failed) {
    return { ok: false, error: failed.error };
  }

  const clusterId = id("cluster");
  return {
    ok: true,
    cluster: {
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
        proxmox_node: body.proxmox_node || env.PROXMOX_NODE || "pve",
        storage_pool: body.storage_pool || env.PROXMOX_STORAGE_POOL || "local-lvm",
      },
    },
  };
}

export function persistCluster(dirs, cluster) {
  writeJson(path.join(dirs.clusters, `${cluster.id}.json`), cluster);
}

export function loadCluster(dirs, clusterId) {
  return readJson(path.join(dirs.clusters, `${clusterId}.json`));
}

export function buildBootstrapPayload(cluster, body = {}) {
  return {
    cluster,
    controlplane_ips: body.controlplane_ips || cluster.controlplane_ips || [],
    worker_ips: body.worker_ips || cluster.worker_ips || [],
    vip_ip: body.vip_ip || cluster.vip_ip,
  };
}
