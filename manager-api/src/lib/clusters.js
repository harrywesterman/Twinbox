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

export function buildClusterFromRequest(body, env, { allowedVmHosts = [], clusterInstanceId = null } = {}) {
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
  const parsedNodePrefixLength = parseIntInRange(body.node_prefix_length, "node_prefix_length", 1, 32);
  const parsedGatewayIp = parseIPv4(body.gateway_ip, "gateway_ip");
  const parsedDnsServers = parseIPv4List(body.dns_servers, "dns_servers");
  const parsedDnsDomain = parseOptionalString(body.dns_domain, "dns_domain");
  const vmNames = [
    ...Array.from({ length: parsedControlplanes.value }, (_, index) => `cp-${index + 1}`),
    ...Array.from({ length: parsedWorkers.value }, (_, index) => `worker-${index + 1}`),
  ];
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
    parsedDisk,
    parsedStartVmid,
    parsedVipIp,
    parsedStartIp,
    parsedNodePrefixLength,
    parsedGatewayIp,
    parsedDnsServers,
    parsedDnsDomain,
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
      cluster_instance_id: clusterInstanceId || crypto.randomUUID(),
      name: normalizedName.name,
      controlplane_count: parsedControlplanes.value,
      worker_count: parsedWorkers.value,
      cpu_cores: parsedCpu.value,
      memory_mb: parsedMemory.value,
      disk_gb: parsedDisk.value,
      bridge: parsedBridge.value,
      start_vmid: parsedStartVmid.value,
      vip_ip: parsedVipIp.value,
      start_ip: parsedStartIp.value,
      node_prefix_length: parsedNodePrefixLength.value,
      gateway_ip: parsedGatewayIp.value,
      dns_servers: parsedDnsServers.value,
      dns_domain: parsedDnsDomain.value,
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
