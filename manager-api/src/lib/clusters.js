import crypto from "crypto";
import path from "path";
import {
  buildClusterWorkerSecretBundle,
  ensureClusterSecretRefs,
} from "../../../lib/secrets/schema.mjs";

import {
  now,
  parseIPv4,
  parseIPv4List,
  parseIntInRange,
  parseOptionalString,
  parseRequiredString,
  readJson,
  writeJson,
} from "./common.js";

export function normalizeClusterSlug(rawName) {
  const trimmed = String(rawName || "").trim().toLowerCase();
  const withoutPrefix = trimmed.startsWith("twinbox-") ? trimmed.slice("twinbox-".length) : trimmed;
  return withoutPrefix
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function normalizeClusterName(rawName) {
  const slug = normalizeClusterSlug(rawName);
  if (!slug) {
    return null;
  }
  return {
    slug,
    name: `twinbox-${slug}`,
  };
}

function buildAllowedHostLookup(allowedHosts = []) {
  const lookup = new Map();

  for (const host of Array.isArray(allowedHosts) ? allowedHosts : []) {
    const normalized = String(host || "").trim();
    if (!normalized) continue;
    lookup.set(normalized.toLowerCase(), normalized);
  }

  return lookup;
}

function buildDefaultVmNodeMap(controlplaneCount, workerCount, allowedHosts = [], fallbackHost = "pve") {
  const hostList = Array.isArray(allowedHosts)
    ? allowedHosts.map((host) => String(host || "").trim()).filter(Boolean)
    : [];
  const placementHosts = hostList.length > 0
    ? hostList
    : [String(fallbackHost || "").trim() || "pve"];
  const vmNodeMap = {};
  const vmNames = [];

  for (let index = 1; index <= Math.max(1, Number(controlplaneCount) || 0); index += 1) {
    vmNames.push(`cp-${index}`);
  }
  for (let index = 1; index <= Math.max(0, Number(workerCount) || 0); index += 1) {
    vmNames.push(`worker-${index}`);
  }

  for (let index = 0; index < vmNames.length; index += 1) {
    vmNodeMap[vmNames[index]] = placementHosts[index % placementHosts.length];
  }

  return vmNodeMap;
}

function buildDefaultVmSizeMap(controlplaneCount, workerCount, cpuCores, workerMemoryMb) {
  const vmSizeMap = {};
  const workerDiskGb = 100;

  for (let index = 1; index <= Math.max(1, Number(controlplaneCount) || 0); index += 1) {
    vmSizeMap[`cp-${index}`] = {
      cpu: cpuCores,
      memory_mb: 4096,
      disk_gb: 10,
    };
  }

  for (let index = 1; index <= Math.max(0, Number(workerCount) || 0); index += 1) {
    vmSizeMap[`worker-${index}`] = {
      cpu: cpuCores,
      memory_mb: workerMemoryMb,
      disk_gb: workerDiskGb,
    };
  }

  return vmSizeMap;
}

function normalizeVmNodeMap(rawMap, allowedHosts = [], fallbackHost = "pve", vmNames = []) {
  const defaultMap = buildDefaultVmNodeMap(
    vmNames.filter((name) => String(name).startsWith("cp-")).length,
    vmNames.filter((name) => String(name).startsWith("worker-")).length,
    allowedHosts,
    fallbackHost,
  );

  if (rawMap === null || rawMap === undefined || rawMap === '') {
    return { ok: true, value: defaultMap };
  }

  let candidate = rawMap;
  if (typeof candidate === 'string') {
    try {
      candidate = JSON.parse(candidate);
    } catch {
      return { ok: false, error: "vm_node_map must be valid JSON" };
    }
  }

  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) {
    return { ok: false, error: "vm_node_map must be an object" };
  }

  const allowedHostLookup = buildAllowedHostLookup(allowedHosts);
  const normalized = { ...defaultMap };

  for (const [vmName, hostName] of Object.entries(candidate)) {
    const normalizedVmName = String(vmName || "").trim();
    if (!normalizedVmName) {
      continue;
    }

    const normalizedHostName = String(hostName || "").trim();
    if (!normalizedHostName) {
      return { ok: false, error: `vm_node_map entry ${normalizedVmName} must map to a host name` };
    }

    const resolvedHost = allowedHostLookup.size > 0
      ? allowedHostLookup.get(normalizedHostName.toLowerCase())
      : normalizedHostName;

    if (allowedHostLookup.size > 0 && !resolvedHost) {
      return { ok: false, error: `vm_node_map references unknown Proxmox host ${normalizedHostName}` };
    }

    normalized[normalizedVmName] = resolvedHost;
  }

  for (const vmName of vmNames) {
    if (!Object.prototype.hasOwnProperty.call(normalized, vmName)) {
      normalized[vmName] = defaultMap[vmName];
    }
  }

  return { ok: true, value: normalized };
}

function buildLegacyVmIpMap(startIp, vmNames = []) {
  const parsedStartIp = parseIPv4(startIp, "start_ip");
  if (!parsedStartIp.ok) {
    return parsedStartIp;
  }

  const [prefixA, prefixB, prefixC, startOctet] = parsedStartIp.value.split(".");
  const prefix = `${prefixA}.${prefixB}.${prefixC}`;
  const normalized = {};

  for (const [index, vmName] of vmNames.entries()) {
    normalized[vmName] = `${prefix}.${Number(startOctet) + index}`;
  }

  return { ok: true, value: normalized };
}

function normalizeVmIpMap(rawMap, vmNames = [], fallbackStartIp = "") {
  const vmNameList = Array.isArray(vmNames) ? vmNames.map((name) => String(name || "").trim()).filter(Boolean) : [];
  if (vmNameList.length === 0) {
    return { ok: false, error: "vm_ip_map cannot be built without VM names" };
  }

  if (rawMap === null || rawMap === undefined || rawMap === "") {
    if (fallbackStartIp) {
      return buildLegacyVmIpMap(fallbackStartIp, vmNameList);
    }
    return { ok: false, error: "vm_ip_map is required" };
  }

  let candidate = rawMap;
  if (typeof candidate === "string") {
    try {
      candidate = JSON.parse(candidate);
    } catch {
      return { ok: false, error: "vm_ip_map must be valid JSON" };
    }
  }

  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    return { ok: false, error: "vm_ip_map must be an object" };
  }

  const normalized = {};
  const seenIps = new Set();

  for (const vmName of vmNameList) {
    if (!Object.prototype.hasOwnProperty.call(candidate, vmName)) {
      return { ok: false, error: `vm_ip_map is missing an entry for ${vmName}` };
    }

    const ipValue = String(candidate[vmName] || "").trim();
    const parsedIp = parseIPv4(ipValue, `vm_ip_map.${vmName}`);
    if (!parsedIp.ok) {
      return { ok: false, error: parsedIp.error };
    }
    if (seenIps.has(parsedIp.value)) {
      return { ok: false, error: `vm_ip_map contains duplicate IP ${parsedIp.value}` };
    }

    normalized[vmName] = parsedIp.value;
    seenIps.add(parsedIp.value);
  }

  for (const key of Object.keys(candidate)) {
    if (!vmNameList.includes(String(key || "").trim())) {
      return { ok: false, error: `vm_ip_map contains unknown VM ${String(key || "").trim()}` };
    }
  }

  return { ok: true, value: normalized };
}

function normalizeVmSizeMap(rawMap, vmNames = [], cpuCores = 2, workerMemoryMb = 10240) {
  const vmNameList = Array.isArray(vmNames) ? vmNames.map((name) => String(name || "").trim()).filter(Boolean) : [];
  if (vmNameList.length === 0) {
    return { ok: false, error: "vm_size_map cannot be built without VM names" };
  }

  const defaultMap = buildDefaultVmSizeMap(
    vmNameList.filter((name) => name.startsWith("cp-")).length,
    vmNameList.filter((name) => name.startsWith("worker-")).length,
    cpuCores,
    workerMemoryMb,
  );

  if (rawMap === null || rawMap === undefined || rawMap === "") {
    return { ok: true, value: defaultMap };
  }

  let candidate = rawMap;
  if (typeof candidate === "string") {
    try {
      candidate = JSON.parse(candidate);
    } catch {
      return { ok: false, error: "vm_size_map must be valid JSON" };
    }
  }

  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    return { ok: false, error: "vm_size_map must be an object" };
  }

  const normalized = { ...defaultMap };
  const seenKeys = new Set();

  for (const [vmName, value] of Object.entries(candidate)) {
    const normalizedVmName = String(vmName || "").trim();
    if (!normalizedVmName) {
      continue;
    }
    if (!vmNameList.includes(normalizedVmName)) {
      return { ok: false, error: `vm_size_map contains unknown VM ${normalizedVmName}` };
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return { ok: false, error: `vm_size_map entry ${normalizedVmName} must be an object` };
    }

    const parsedCpu = parseIntInRange(value.cpu, `vm_size_map.${normalizedVmName}.cpu`, 1, 64);
    const parsedMemory = parseIntInRange(value.memory_mb, `vm_size_map.${normalizedVmName}.memory_mb`, 512, 1048576);
    const parsedDisk = parseIntInRange(value.disk_gb, `vm_size_map.${normalizedVmName}.disk_gb`, 10, 8192);
    if (!parsedCpu.ok) return { ok: false, error: parsedCpu.error };
    if (!parsedMemory.ok) return { ok: false, error: parsedMemory.error };
    if (!parsedDisk.ok) return { ok: false, error: parsedDisk.error };

    normalized[normalizedVmName] = {
      cpu: parsedCpu.value,
      memory_mb: parsedMemory.value,
      disk_gb: parsedDisk.value,
    };
    seenKeys.add(normalizedVmName);
  }

  for (const vmName of vmNameList) {
    if (!seenKeys.has(vmName)) {
      normalized[vmName] = defaultMap[vmName];
    }
  }

  return { ok: true, value: normalized };
}

export function buildClusterFromRequest(body, env, { allowedVmHosts = [], clusterInstanceId = null } = {}) {
  const parsedName = parseRequiredString(body.name, "name");
  const parsedBridge = parseRequiredString(body.bridge, "bridge");
  const parsedControlplanes = parseIntInRange(body.controlplane_count, "controlplane_count", 1, 15);
  const parsedWorkers = parseIntInRange(body.worker_count, "worker_count", 0, 200);
  const parsedCpu = parseIntInRange(body.cpu_cores, "cpu_cores", 1, 64);
  const parsedMemory = parseIntInRange(body.memory_mb, "memory_mb", 512, 1048576);
  const parsedWorkerDiskPercent = parseIntInRange(body.worker_disk_percent ?? 80, "worker_disk_percent", 10, 100);
  const parsedStartVmid = parseIntInRange(body.start_vmid, "start_vmid", 100, 999999);
  const parsedVipIp = parseIPv4(body.vip_ip, "vip_ip");
  const parsedNodePrefixLength = parseIntInRange(body.node_prefix_length, "node_prefix_length", 1, 32);
  const parsedGatewayIp = parseIPv4(body.gateway_ip, "gateway_ip");
  const parsedDnsServers = parseIPv4List(body.dns_servers, "dns_servers");
  const parsedDnsDomain = parseOptionalString(body.dns_domain, "dns_domain");
  const vmNames = [
    ...Array.from({ length: parsedControlplanes.value }, (_, index) => `cp-${index + 1}`),
    ...Array.from({ length: parsedWorkers.value }, (_, index) => `worker-${index + 1}`),
  ];
  const parsedVmIpMap = normalizeVmIpMap(body.vm_ip_map, vmNames, String(body.start_ip || "").trim());
  const parsedVmSizeMap = normalizeVmSizeMap(body.vm_size_map, vmNames, parsedCpu.value, parsedMemory.value);
  const parsedVmNodeMap = normalizeVmNodeMap(
    body.vm_node_map,
    allowedVmHosts,
    body.proxmox_node || env.PROXMOX_NODE || "pve",
    vmNames,
  );

  const validations = [
    parsedName,
    parsedBridge,
    parsedControlplanes,
    parsedWorkers,
    parsedCpu,
    parsedMemory,
    parsedWorkerDiskPercent,
    parsedStartVmid,
    parsedVipIp,
    parsedNodePrefixLength,
    parsedGatewayIp,
    parsedDnsServers,
    parsedDnsDomain,
    parsedVmIpMap,
    parsedVmSizeMap,
    parsedVmNodeMap.ok ? { ok: true } : { ok: false, error: parsedVmNodeMap.error },
  ];

  const failed = validations.find((value) => !value.ok);
  if (failed) {
    return { ok: false, error: failed.error };
  }

  const normalizedName = normalizeClusterName(parsedName.value);
  if (!normalizedName) {
    return { ok: false, error: "name must contain letters or numbers" };
  }

  const clusterId = normalizedName.slug;
  const metadata = {
    proxmox_node: body.proxmox_node || env.PROXMOX_NODE || "pve",
    storage_pool: body.storage_pool || env.PROXMOX_STORAGE_POOL || "local-lvm",
    file_datastore: body.file_datastore || env.PROXMOX_FILE_DATASTORE || "local",
    cluster_slug: normalizedName.slug,
    talos_image_preset: env.TALOS_IMAGE_PRESET || "qemu-guest-agent",
    talos_image_platform: env.TALOS_IMAGE_PLATFORM || "cloud-server",
    talos_image_arch: env.TALOS_IMAGE_ARCH || "amd64",
  };

  return {
    ok: true,
    cluster: ensureClusterSecretRefs({
      id: clusterId,
      slug: normalizedName.slug,
      cluster_instance_id: clusterInstanceId || crypto.randomUUID(),
      name: normalizedName.name,
      controlplane_count: parsedControlplanes.value,
      worker_count: parsedWorkers.value,
      cpu_cores: parsedCpu.value,
      memory_mb: parsedMemory.value,
      worker_disk_percent: parsedWorkerDiskPercent.value,
      controlplane_memory_mb: 4096,
      controlplane_disk_gb: 10,
      worker_memory_mb: parsedMemory.value,
      worker_disk_gb: parsedVmSizeMap.value["worker-1"]?.disk_gb ?? 100,
      bridge: parsedBridge.value,
      start_vmid: parsedStartVmid.value,
      vip_ip: parsedVipIp.value,
      start_ip: Object.values(parsedVmIpMap.value || {})[0] || String(body.start_ip || ""),
      node_prefix_length: parsedNodePrefixLength.value,
      gateway_ip: parsedGatewayIp.value,
      dns_servers: parsedDnsServers.value,
      dns_domain: parsedDnsDomain.value,
      vm_ip_map: parsedVmIpMap.value,
      vm_size_map: parsedVmSizeMap.value,
      vm_node_map: parsedVmNodeMap.value,
      status: "requested",
      created_at: now(),
      updated_at: now(),
      metadata,
      spec_version: "iac-v1",
    }),
  };
}

export function persistCluster(dirs, cluster) {
  writeJson(path.join(dirs.clusters, `${cluster.id}.json`), cluster);
}

export function loadCluster(dirs, clusterId) {
  return readJson(path.join(dirs.clusters, `${clusterId}.json`));
}

export function buildBootstrapPayload(cluster, body = {}) {
  const normalized = ensureClusterSecretRefs({
    ...cluster,
    bootstrap_resume: true,
    controlplane_ips: body.controlplane_ips || cluster.controlplane_ips || [],
    worker_ips: body.worker_ips || cluster.worker_ips || [],
    vip_ip: body.vip_ip || cluster.vip_ip,
  });

  return {
    ...normalized,
    secret_bundle: buildClusterWorkerSecretBundle(normalized),
  };
}

export function buildApplyJobPayload(cluster) {
  const normalized = ensureClusterSecretRefs(cluster);
  return {
    ...normalized,
    secret_bundle: buildClusterWorkerSecretBundle(normalized),
  };
}
