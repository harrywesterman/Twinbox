import path from "path";

import {
  id,
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
  const parsedNodePrefixLength = parseIntInRange(body.node_prefix_length, "node_prefix_length", 1, 32);
  const parsedGatewayIp = parseIPv4(body.gateway_ip, "gateway_ip");
  const parsedDnsServers = parseIPv4List(body.dns_servers, "dns_servers");
  const parsedDnsDomain = parseOptionalString(body.dns_domain, "dns_domain");

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
  return {
    ok: true,
    cluster: {
      id: clusterId,
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
      status: "requested",
      created_at: now(),
      updated_at: now(),
      metadata: {
        proxmox_node: body.proxmox_node || env.PROXMOX_NODE || "pve",
        storage_pool: body.storage_pool || env.PROXMOX_STORAGE_POOL || "local-lvm",
        file_datastore: body.file_datastore || env.PROXMOX_FILE_DATASTORE || "local",
        cluster_slug: normalizedName.slug,
        talos_image_preset: env.TALOS_IMAGE_PRESET || "qemu-guest-agent",
        talos_image_platform: env.TALOS_IMAGE_PLATFORM || "cloud-server",
        talos_image_arch: env.TALOS_IMAGE_ARCH || "amd64",
      },
      spec_version: "iac-v1",
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
    ...cluster,
    bootstrap_resume: true,
    controlplane_ips: body.controlplane_ips || cluster.controlplane_ips || [],
    worker_ips: body.worker_ips || cluster.worker_ips || [],
    vip_ip: body.vip_ip || cluster.vip_ip,
  };
}
