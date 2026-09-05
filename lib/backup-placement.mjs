const GiB = 1024 ** 3;

function content(storage, type) {
  return (
    Array.isArray(storage.content) ? storage.content : String(storage.content || "").split(",")
  ).includes(type);
}

function active(storage) {
  return Number(storage.active) === 1 && Number(storage.enabled ?? 1) === 1;
}

export function backupHosts({ nodes, storages, networks, cluster }) {
  return nodes
    .filter((node) => node.status === "online")
    .map((node) => {
      const name = node.node;
      const disks = storages
        .filter((s) => s.node === name && active(s) && content(s, "images"))
        .map((s) => ({
          storage: s.storage,
          avail: Number(s.avail ?? Math.max(0, s.total - s.used)),
        }))
        .sort((a, b) => b.avail - a.avail || a.storage.localeCompare(b.storage));
      const files = storages
        .filter((s) => s.node === name && active(s) && content(s, "iso") && content(s, "snippets"))
        .sort((a, b) => a.storage.localeCompare(b.storage));
      const preferred = cluster.file_datastore || cluster.metadata?.file_datastore;
      const file = files.find((s) => s.storage === preferred) || files[0];
      const bridge = networks.some(
        (n) => n.node === name && n.iface === cluster.bridge && Number(n.active) === 1
      );
      return {
        node: name,
        free_memory: Math.max(0, Number(node.maxmem) - Number(node.mem)),
        storages: disks,
        file_datastore: file?.storage || "",
        error:
          cluster.bridge && !bridge
            ? `Bridge ${cluster.bridge} is unavailable`
            : !file
              ? "No active ISO/snippets datastore"
              : !disks.length
                ? "No active VM datastore"
                : "",
      };
    })
    .sort((a, b) => b.free_memory - a.free_memory || a.node.localeCompare(b.node));
}

export function validateBackupPlacement(hosts, inputs, existing = null) {
  for (const [field, key] of [
    ["seaweedfs_node", "node"],
    ["seaweedfs_datastore", "datastore"],
    ["seaweedfs_ip", "ip_address"],
    ["seaweedfs_data_disk_gb", "data_disk_gb"],
  ]) {
    if (existing?.vm_id && String(inputs[field]) !== String(existing[key]))
      throw new Error(`Cannot change existing SeaweedFS ${key}`);
  }
  const host = hosts.find((h) => h.node === inputs.seaweedfs_node);
  if (!host) throw new Error("Select an online Proxmox host");
  if (host.error) throw new Error(host.error);
  const disk = host.storages.find((s) => s.storage === inputs.seaweedfs_datastore);
  if (!disk) throw new Error("Select an active VM datastore on the selected host");
  const size = Number(inputs.seaweedfs_data_disk_gb);
  if (!Number.isInteger(size) || size < 100) throw new Error("Data disk must be at least 100 GiB");
  if (!existing?.vm_id && (!Number.isFinite(host.free_memory) || host.free_memory < 4 * GiB))
    throw new Error("Host needs at least 4 GiB free RAM");
  if (!existing?.vm_id && (!Number.isFinite(disk.avail) || disk.avail < (size + 20) * GiB))
    throw new Error(`Datastore needs ${size + 20} GiB free (including the system disk)`);
  return host;
}

function ipNumber(ip) {
  const parts = String(ip || "").split(".");
  if (parts.length !== 4 || parts.some((p) => !/^\d{1,3}$/.test(p) || Number(p) > 255))
    throw new Error("Invalid IPv4 address");
  return parts.reduce((n, part) => n * 256 + Number(part), 0);
}

function ipString(n) {
  return [24, 16, 8, 0].map((shift) => (n >>> shift) & 255).join(".");
}

export function backupSubnet(cluster) {
  const prefix = Number(cluster.node_prefix_length);
  if (cluster.node_prefix_length == null || !Number.isInteger(prefix) || prefix < 1 || prefix > 30)
    throw new Error("Cluster subnet prefix is unavailable");
  const size = 2 ** (32 - prefix);
  const start = Math.floor(ipNumber(cluster.gateway_ip) / size) * size;
  return { start, end: start + size - 1 };
}

export function reservedBackupIps(clusters, managementIp, extra = []) {
  const list = (value) =>
    Array.isArray(value)
      ? value
      : String(value || "")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
  return new Set(
    [
      managementIp,
      ...extra,
      ...clusters.flatMap((c) => [
        c.gateway_ip,
        c.vip_ip,
        ...list(c.dns_servers),
        ...Object.values(c.vm_ip_map || {}),
        ...list(c.controlplane_ips),
        ...list(c.worker_ips),
        ...list(c.reserved_ips),
      ]),
    ].filter(Boolean)
  );
}

export function validateBackupIp(cluster, ip, reserved) {
  const { start, end } = backupSubnet(cluster);
  const number = ipNumber(ip);
  if (number <= start || number >= end)
    throw new Error("SeaweedFS IP must be a usable address in the cluster subnet");
  if (reserved.has(ip)) throw new Error("SeaweedFS IP is reserved or assigned to another machine");
}

export async function suggestBackupIp(cluster, reserved, isInUse) {
  const { start, end } = backupSubnet(cluster);
  // Bound discovery time on large networks; a manual address remains possible.
  let probes = 0;
  for (let n = start + 1; n < end; n++) {
    const ip = ipString(n);
    if (reserved.has(ip)) continue;
    if (++probes > 64) break;
    if (!(await isInUse(ip))) return ip;
  }
  throw new Error("No free IP found in the scanned addresses. Enter an address or retry.");
}
