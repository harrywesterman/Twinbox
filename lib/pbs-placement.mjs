const GiB = 1024 ** 3;

function values(storage, key) {
  return (Array.isArray(storage?.[key]) ? storage[key] : String(storage?.[key] || "").split(","))
    .map((value) => String(value).trim())
    .filter(Boolean);
}

function active(storage) {
  return Number(storage?.active ?? 1) === 1 && Number(storage?.enabled ?? 1) === 1;
}

function hasContent(storage, contentType) {
  return values(storage, "content").includes(contentType);
}

export function pbsHosts({ nodes = [], storages = [], networks = [], cluster = {} }) {
  return nodes
    .filter((node) => String(node?.status || "").toLowerCase() === "online")
    .map((node) => {
      const nodeName = String(node.node || node.name || "").trim();
      const available = storages
        .filter(
          (storage) => storage.node === nodeName && active(storage) && hasContent(storage, "images")
        )
        .map((storage) => ({
          storage: storage.storage,
          avail: Number(
            storage.avail ?? Math.max(0, Number(storage.total || 0) - Number(storage.used || 0))
          ),
        }))
        .filter((storage) => storage.storage && Number.isFinite(storage.avail))
        .sort(
          (left, right) => right.avail - left.avail || left.storage.localeCompare(right.storage)
        );
      const imageDatastores = storages
        .filter(
          (storage) =>
            storage.node === nodeName &&
            active(storage) &&
            (hasContent(storage, "import") || hasContent(storage, "iso"))
        )
        .map((storage) => storage.storage)
        .filter(Boolean)
        .sort();
      const bridge =
        !cluster.bridge ||
        networks.some(
          (network) =>
            network.node === nodeName &&
            network.iface === cluster.bridge &&
            Number(network.active ?? 1) === 1
        );
      return {
        node: nodeName,
        free_memory: Math.max(0, Number(node.maxmem || 0) - Number(node.mem || 0)),
        storages: available,
        image_datastores: imageDatastores,
        error: !bridge
          ? `Bridge ${cluster.bridge} is unavailable`
          : !available.length
            ? "No active VM datastore"
            : !imageDatastores.length
              ? "No active datastore for the Debian cloud image"
              : "",
      };
    })
    .sort(
      (left, right) => right.free_memory - left.free_memory || left.node.localeCompare(right.node)
    );
}

export function validatePbsPlacement(hosts, inputs) {
  const host = hosts.find((entry) => entry.node === inputs.pbs_node);
  if (!host) throw new Error("Select an online Proxmox host for PBS");
  if (host.error) throw new Error(host.error);
  const system = host.storages.find((entry) => entry.storage === inputs.pbs_datastore);
  const cache = host.storages.find((entry) => entry.storage === inputs.pbs_cache_datastore);
  if (!system) throw new Error("Select an active system datastore on the selected PBS host");
  if (!cache) throw new Error("Select an active cache datastore on the selected PBS host");
  const cpu = Number(inputs.pbs_cpu);
  const memory = Number(inputs.pbs_memory_gb);
  const systemDisk = Number(inputs.pbs_system_disk_gb);
  const cacheDisk = Number(inputs.pbs_cache_disk_gb);
  if (!Number.isInteger(cpu) || cpu < 2) throw new Error("PBS needs at least 2 vCPU");
  if (!Number.isInteger(memory) || memory < 4) throw new Error("PBS needs at least 4 GiB RAM");
  if (!Number.isInteger(systemDisk) || systemDisk < 32)
    throw new Error("PBS system disk must be at least 32 GiB");
  if (!Number.isInteger(cacheDisk) || cacheDisk < 64)
    throw new Error("PBS cache disk must be at least 64 GiB");
  if (host.free_memory < memory * GiB) throw new Error(`PBS host needs ${memory} GiB free RAM`);
  if (system.avail < systemDisk * GiB)
    throw new Error(`PBS system datastore needs ${systemDisk} GiB free`);
  if (cache.storage === system.storage) {
    if (system.avail < (systemDisk + cacheDisk) * GiB)
      throw new Error(`PBS datastore needs ${systemDisk + cacheDisk} GiB free for both disks`);
  } else if (cache.avail < cacheDisk * GiB) {
    throw new Error(`PBS cache datastore needs ${cacheDisk} GiB free`);
  }
  return host;
}
