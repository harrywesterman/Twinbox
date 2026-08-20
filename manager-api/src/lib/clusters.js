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
import { normalizeVmStorageMap } from "./proxmox-capacity.js";

const CONTROLPLANE_MEMORY_MB = 5120;
const CONTROLPLANE_DISK_GB = 10;
const OBSERVABILITY_PROFILES = new Set(["full", "minimal", "off"]);
const RESOURCE_PROFILES = new Set(["small", "standard", "large"]);
const STANDARD_WORKER_CPU_CORES = 16;
const STANDARD_WORKER_MEMORY_MB = 48 * 1024;
const LARGE_WORKER_CPU_CORES = 32;
const LARGE_WORKER_MEMORY_MB = 96 * 1024;

export function normalizeClusterSlug(rawName) {
  const trimmed = String(rawName || "")
    .trim()
    .toLowerCase();
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

export function normalizeObservabilityProfile(rawProfile) {
  const profile = String(rawProfile || "")
    .trim()
    .toLowerCase();
  if (OBSERVABILITY_PROFILES.has(profile)) {
    return profile;
  }
  return "full";
}

export function normalizeResourceProfile(rawProfile) {
  const profile = String(rawProfile || "")
    .trim()
    .toLowerCase();
  if (RESOURCE_PROFILES.has(profile)) {
    return profile;
  }
  return "standard";
}

export function deriveClusterResourceProfile({ vm_size_map: vmSizeMap = {} } = {}) {
  const workerEntries = Object.entries(vmSizeMap || {}).filter(([name]) =>
    String(name || "").startsWith("worker-")
  );
  const capacity = workerEntries.reduce(
    (summary, [, value]) => ({
      cpu: summary.cpu + (Number(value?.cpu) || 0),
      memoryMb: summary.memoryMb + (Number(value?.memory_mb) || 0),
    }),
    { cpu: 0, memoryMb: 0 }
  );

  let resourceProfile = "small";
  if (capacity.cpu >= LARGE_WORKER_CPU_CORES && capacity.memoryMb >= LARGE_WORKER_MEMORY_MB) {
    resourceProfile = "large";
  } else if (
    capacity.cpu >= STANDARD_WORKER_CPU_CORES &&
    capacity.memoryMb >= STANDARD_WORKER_MEMORY_MB
  ) {
    resourceProfile = "standard";
  }

  return {
    resource_profile: resourceProfile,
    worker_cpu_total: capacity.cpu,
    worker_memory_total_mb: capacity.memoryMb,
    resource_profile_reason: `${capacity.cpu} worker CPU cores and ${capacity.memoryMb} MiB worker memory`,
  };
}

export function ensureClusterResourceProfile(cluster = {}) {
  const existingProfile = String(cluster.resource_profile || "").trim();
  if (
    RESOURCE_PROFILES.has(existingProfile) &&
    Number.isFinite(Number(cluster.worker_cpu_total)) &&
    Number.isFinite(Number(cluster.worker_memory_total_mb)) &&
    String(cluster.resource_profile_reason || "").trim()
  ) {
    return {
      ...cluster,
      resource_profile: existingProfile,
    };
  }

  const resourceProfile = deriveClusterResourceProfile(cluster);
  return {
    ...cluster,
    resource_profile: resourceProfile.resource_profile,
    worker_cpu_total: resourceProfile.worker_cpu_total,
    worker_memory_total_mb: resourceProfile.worker_memory_total_mb,
    resource_profile_reason: resourceProfile.resource_profile_reason,
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

function normalizeVmNodeMap(rawMap, allowedHosts = [], vmNames = []) {
  const vmNameList = Array.isArray(vmNames)
    ? vmNames.map((name) => String(name || "").trim()).filter(Boolean)
    : [];
  if (vmNameList.length === 0) {
    return { ok: false, error: "vm_node_map cannot be built without VM names" };
  }

  if (rawMap === null || rawMap === undefined || rawMap === "") {
    return { ok: false, error: "vm_node_map is required" };
  }

  let candidate = rawMap;
  if (typeof candidate === "string") {
    try {
      candidate = JSON.parse(candidate);
    } catch {
      return { ok: false, error: "vm_node_map must be valid JSON" };
    }
  }

  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    return { ok: false, error: "vm_node_map must be an object" };
  }

  const allowedHostLookup = buildAllowedHostLookup(allowedHosts);
  const normalized = {};

  for (const vmName of vmNameList) {
    const hostName = String(candidate[vmName] ?? "").trim();
    if (!hostName) {
      return { ok: false, error: `vm_node_map is missing an entry for ${vmName}` };
    }

    const resolvedHost =
      allowedHostLookup.size > 0 ? allowedHostLookup.get(hostName.toLowerCase()) : hostName;

    if (allowedHostLookup.size > 0 && !resolvedHost) {
      return {
        ok: false,
        error: `vm_node_map references unknown Proxmox host ${hostName}`,
      };
    }

    normalized[vmName] = resolvedHost;
  }

  for (const key of Object.keys(candidate)) {
    if (!vmNameList.includes(String(key || "").trim())) {
      return { ok: false, error: `vm_node_map contains unknown VM ${String(key || "").trim()}` };
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
  const vmNameList = Array.isArray(vmNames)
    ? vmNames.map((name) => String(name || "").trim()).filter(Boolean)
    : [];
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

function parsePositiveInteger(value, field) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    return { ok: false, error: `${field} must be a positive integer` };
  }
  return { ok: true, value: parsed };
}

function normalizeVmSizeMap(rawMap, vmNames = []) {
  const vmNameList = Array.isArray(vmNames)
    ? vmNames.map((name) => String(name || "").trim()).filter(Boolean)
    : [];
  if (vmNameList.length === 0) {
    return { ok: false, error: "vm_size_map cannot be built without VM names" };
  }

  if (rawMap === null || rawMap === undefined || rawMap === "") {
    return { ok: false, error: "vm_size_map is required" };
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

  const normalized = {};

  for (const vmName of vmNameList) {
    const value = candidate[vmName];
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return { ok: false, error: `vm_size_map is missing an entry for ${vmName}` };
    }

    const parsedCpu = parsePositiveInteger(value.cpu, `vm_size_map.${vmName}.cpu`);
    const parsedMemory = parsePositiveInteger(value.memory_mb, `vm_size_map.${vmName}.memory_mb`);
    const parsedDisk = parsePositiveInteger(value.disk_gb, `vm_size_map.${vmName}.disk_gb`);
    if (!parsedCpu.ok) return { ok: false, error: parsedCpu.error };
    if (!parsedMemory.ok) return { ok: false, error: parsedMemory.error };
    if (!parsedDisk.ok) return { ok: false, error: parsedDisk.error };

    normalized[vmName] = {
      cpu: parsedCpu.value,
      memory_mb: parsedMemory.value,
      disk_gb: parsedDisk.value,
    };
  }

  for (const key of Object.keys(candidate)) {
    if (!vmNameList.includes(String(key || "").trim())) {
      return { ok: false, error: `vm_size_map contains unknown VM ${String(key || "").trim()}` };
    }
  }

  return { ok: true, value: normalized };
}

export function buildClusterFromRequest(
  body,
  env,
  { allowedVmHosts = [], allowedVmStorages = [], clusterInstanceId = null } = {}
) {
  const parsedName = parseRequiredString(body.name, "name");
  const parsedBridge = parseRequiredString(body.bridge, "bridge");
  const parsedControlplanes = parseIntInRange(body.controlplane_count, "controlplane_count", 1, 15);
  const parsedWorkers = parseIntInRange(body.worker_count, "worker_count", 0, 200);
  const parsedStartVmid = parseIntInRange(body.start_vmid, "start_vmid", 100, 999999);
  const parsedVipIp = parseIPv4(body.vip_ip, "vip_ip");
  const parsedNodePrefixLength = parseIntInRange(
    body.node_prefix_length,
    "node_prefix_length",
    1,
    32
  );
  const parsedGatewayIp = parseIPv4(body.gateway_ip, "gateway_ip");
  const parsedDnsServers = parseIPv4List(body.dns_servers, "dns_servers");
  const parsedDnsDomain = parseOptionalString(body.dns_domain, "dns_domain");
  const vmNames = [
    ...Array.from({ length: parsedControlplanes.value }, (_, index) => `cp-${index + 1}`),
    ...Array.from({ length: parsedWorkers.value }, (_, index) => `worker-${index + 1}`),
  ];
  const parsedVmIpMap = normalizeVmIpMap(
    body.vm_ip_map,
    vmNames,
    String(body.start_ip || "").trim()
  );
  const parsedVmSizeMap = normalizeVmSizeMap(body.vm_size_map, vmNames);
  const parsedVmNodeMap = normalizeVmNodeMap(body.vm_node_map, allowedVmHosts, vmNames);
  const preferredStorage =
    String(body.storage_pool || env.PROXMOX_STORAGE_POOL || "local-lvm").trim() || "local-lvm";
  const parsedVmStorageMap = parsedVmNodeMap.ok
    ? normalizeVmStorageMap(
        body.vm_storage_map,
        vmNames,
        parsedVmNodeMap.value,
        allowedVmStorages,
        preferredStorage
      )
    : { ok: false, error: parsedVmNodeMap.error };

  const validations = [
    parsedName,
    parsedBridge,
    parsedControlplanes,
    parsedWorkers,
    parsedStartVmid,
    parsedVipIp,
    parsedNodePrefixLength,
    parsedGatewayIp,
    parsedDnsServers,
    parsedDnsDomain,
    parsedVmIpMap,
    parsedVmSizeMap,
    parsedVmNodeMap.ok ? { ok: true } : { ok: false, error: parsedVmNodeMap.error },
    parsedVmStorageMap,
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
    storage_pool: preferredStorage,
    file_datastore: body.file_datastore || env.PROXMOX_FILE_DATASTORE || "local",
    cluster_slug: normalizedName.slug,
    talos_image_preset: env.TALOS_IMAGE_PRESET || "qemu-guest-agent",
    talos_image_platform: env.TALOS_IMAGE_PLATFORM || "nocloud",
    talos_image_arch: env.TALOS_IMAGE_ARCH || "amd64",
  };
  const resourceProfile = deriveClusterResourceProfile({
    vm_size_map: parsedVmSizeMap.value,
  });

  return {
    ok: true,
    cluster: ensureClusterSecretRefs({
      id: clusterId,
      slug: normalizedName.slug,
      cluster_instance_id: clusterInstanceId || crypto.randomUUID(),
      name: normalizedName.name,
      controlplane_count: parsedControlplanes.value,
      worker_count: parsedWorkers.value,
      controlplane_memory_mb: CONTROLPLANE_MEMORY_MB,
      controlplane_disk_gb: CONTROLPLANE_DISK_GB,
      worker_memory_mb: parsedVmSizeMap.value["worker-1"]?.memory_mb ?? 0,
      worker_disk_gb: parsedVmSizeMap.value["worker-1"]?.disk_gb ?? 0,
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
      vm_storage_map: parsedVmStorageMap.value,
      status: "requested",
      observability_profile: "full",
      resource_profile: resourceProfile.resource_profile,
      worker_cpu_total: resourceProfile.worker_cpu_total,
      worker_memory_total_mb: resourceProfile.worker_memory_total_mb,
      resource_profile_reason: resourceProfile.resource_profile_reason,
      observability_status: "ready",
      observability_error: null,
      observability_last_job_id: null,
      observability_updated_at: null,
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
    ...ensureClusterResourceProfile(cluster),
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
  const normalized = ensureClusterSecretRefs(ensureClusterResourceProfile(cluster));
  return {
    ...normalized,
    secret_bundle: buildClusterWorkerSecretBundle(normalized),
  };
}
