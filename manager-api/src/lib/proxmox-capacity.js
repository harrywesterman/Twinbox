const MB = 1024 * 1024;
const GB = 1024 * 1024 * 1024;

function text(value) {
  return String(value || "").trim();
}

export function isManagementVm(vm = {}) {
  const name = text(vm.name || vm.vm_name || vm.id).toLowerCase();
  const tags = text(vm.tags).toLowerCase();
  return tags.includes("management") || name.endsWith("-mgt") || name.endsWith("mgt");
}

export function findManagementVm(vms = []) {
  const list = Array.isArray(vms) ? vms : [];
  return list.find(isManagementVm) || null;
}

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function storageContent(entry) {
  const raw = Array.isArray(entry?.content) ? entry.content : text(entry?.content).split(",");
  return raw.map((value) => text(value).toLowerCase()).filter(Boolean);
}

export function normalizeStorageResource(entry = {}) {
  const storage = text(entry.storage || entry.name || entry.id);
  const node = text(entry.node);
  const total = number(entry.total || entry.maxdisk);
  const used = number(entry.used || entry.disk);
  const avail = number(entry.avail, Math.max(0, total - used));

  return {
    ...entry,
    storage,
    node,
    content: storageContent(entry),
    active: entry.active === undefined ? true : Boolean(number(entry.active)),
    enabled: entry.enabled === undefined ? true : Boolean(number(entry.enabled)),
    shared: Boolean(number(entry.shared)),
    total,
    used,
    avail,
  };
}

export function isVmStorageResource(entry) {
  const storage = normalizeStorageResource(entry);
  return Boolean(
    storage.storage &&
    storage.node &&
    storage.active &&
    storage.enabled &&
    storage.content.includes("images")
  );
}

export function storageCapacityKey(entry) {
  const storage = normalizeStorageResource(entry);
  return storage.shared ? `shared:${storage.storage}` : `${storage.node}:${storage.storage}`;
}

export function chooseVmStorageForHost(storages, hostName, preferredStorage = "") {
  const host = text(hostName);
  const preferred = text(preferredStorage);
  const eligible = (Array.isArray(storages) ? storages : [])
    .map(normalizeStorageResource)
    .filter((entry) => entry.node === host && isVmStorageResource(entry));

  const preferredEntry = eligible.find((entry) => entry.storage === preferred);
  if (preferredEntry) return preferredEntry.storage;

  return (
    eligible.sort(
      (left, right) => right.avail - left.avail || left.storage.localeCompare(right.storage)
    )[0]?.storage || ""
  );
}

export function normalizeVmStorageMap(
  rawMap,
  vmNames,
  vmNodeMap,
  storages,
  preferredStorage = "local-lvm"
) {
  let candidate = rawMap;
  if (typeof candidate === "string") {
    try {
      candidate = JSON.parse(candidate);
    } catch {
      return { ok: false, error: "vm_storage_map must be valid JSON" };
    }
  }
  if (candidate === null || candidate === undefined || candidate === "") candidate = {};
  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    return { ok: false, error: "vm_storage_map must be an object" };
  }

  const names = Array.isArray(vmNames) ? vmNames.map(text).filter(Boolean) : [];
  for (const key of Object.keys(candidate)) {
    if (!names.includes(text(key))) {
      return { ok: false, error: `vm_storage_map contains unknown VM ${text(key)}` };
    }
  }

  const resources = Array.isArray(storages) ? storages : [];
  const normalized = {};
  for (const vmName of names) {
    const host = text(vmNodeMap?.[vmName]);
    const requested = text(candidate[vmName]);
    const selected = requested || chooseVmStorageForHost(resources, host, preferredStorage);

    if (!selected && resources.length === 0) {
      normalized[vmName] = preferredStorage;
      continue;
    }
    if (!selected) {
      return { ok: false, error: `No VM storage is available for ${vmName} on ${host}` };
    }

    const entry = resources
      .map(normalizeStorageResource)
      .find((storage) => storage.node === host && storage.storage === selected);
    if (resources.length > 0 && !entry) {
      return {
        ok: false,
        error: `vm_storage_map selects unavailable storage ${selected} for ${vmName} on ${host}`,
      };
    }
    if (entry && !isVmStorageResource(entry)) {
      return {
        ok: false,
        error: `Storage ${selected} on ${host} is not active VM-image storage`,
      };
    }
    normalized[vmName] = selected;
  }

  return { ok: true, value: normalized };
}

function expectedVmNames(cluster) {
  return Object.keys(cluster?.vm_node_map || {});
}

function isExistingTargetVm(vm, cluster) {
  const vmid = number(vm?.vmid, -1);
  const name = text(vm?.name || vm?.vm_name);
  const expectedNames = new Set(
    expectedVmNames(cluster).map((vmName) => `${text(cluster?.name)}-${vmName}`)
  );
  const expectedVmids = new Set(
    expectedVmNames(cluster).map((_, index) => number(cluster?.start_vmid, 0) + index)
  );
  return expectedNames.has(name) || (!name && expectedVmids.has(vmid));
}

export function validateProxmoxCapacity({
  cluster,
  nodes = [],
  vms = [],
  storages = [],
  existingCluster = null,
} = {}) {
  const nodeLookup = new Map(
    (Array.isArray(nodes) ? nodes : []).map((entry) => [
      text(entry.node || entry.name || entry.id),
      entry,
    ])
  );
  const storageEntries = (Array.isArray(storages) ? storages : []).map(normalizeStorageResource);
  const storageLookup = new Map(
    storageEntries.map((entry) => [`${entry.node}:${entry.storage}`, entry])
  );
  const existingVms = (Array.isArray(vms) ? vms : []).filter(
    (vm) => !isExistingTargetVm(vm, cluster)
  );

  const plannedMemoryByHost = new Map();
  const plannedDiskByStorage = new Map();
  for (const vmName of expectedVmNames(cluster)) {
    const host = text(cluster?.vm_node_map?.[vmName]);
    const size = cluster?.vm_size_map?.[vmName];
    const storageName = text(cluster?.vm_storage_map?.[vmName]);
    const node = nodeLookup.get(host);
    if (!node) return { ok: false, error: `Unknown Proxmox host ${host} for ${vmName}` };
    if (!size || !storageName) {
      return { ok: false, error: `Incomplete VM sizing or storage configuration for ${vmName}` };
    }

    const storage = storageLookup.get(`${host}:${storageName}`);
    if (!storage || !isVmStorageResource(storage)) {
      return {
        ok: false,
        error: `Storage ${storageName} is not available for VM images on ${host}`,
      };
    }

    plannedMemoryByHost.set(
      host,
      number(plannedMemoryByHost.get(host)) + number(size.memory_mb) * MB
    );
    const capacityKey = storageCapacityKey(storage);
    plannedDiskByStorage.set(
      capacityKey,
      number(plannedDiskByStorage.get(capacityKey)) + number(size.disk_gb) * GB
    );
  }

  for (const [host, plannedMemory] of plannedMemoryByHost) {
    const node = nodeLookup.get(host);
    const hostVms = existingVms.filter((vm) => text(vm.node) === host);
    let runningMemCurrent = 0;
    let reservedMem = 0;

    for (const vm of hostVms) {
      const running = text(vm.status || vm.qmpstatus).toLowerCase() === "running";
      const configuredMem = number(vm.maxmem) > 0 ? number(vm.maxmem) : number(vm.mem);
      if (isManagementVm(vm)) {
        reservedMem += configuredMem;
        if (running) runningMemCurrent += number(vm.mem);
        continue;
      }
      if (running) {
        runningMemCurrent += number(vm.mem);
        reservedMem += configuredMem;
      }
    }

    const hostOverhead = Math.max(0, number(node?.mem) - runningMemCurrent);
    const required = hostOverhead + reservedMem + plannedMemory;
    const capacity = number(node?.maxmem);
    if (capacity <= 0 || required > capacity) {
      return {
        ok: false,
        error: `Insufficient RAM on ${host}: ${Math.ceil(required / MB)} MiB required, ${Math.floor(capacity / MB)} MiB available without overcommit`,
      };
    }
  }

  const capacityByStorage = new Map();
  for (const storage of storageEntries.filter(isVmStorageResource)) {
    const key = storageCapacityKey(storage);
    const current = capacityByStorage.get(key);
    if (!current || storage.avail < current.avail) capacityByStorage.set(key, storage);
  }

  if (existingCluster) {
    const existingVmNames = new Set(
      (Array.isArray(vms) ? vms : [])
        .filter((vm) => isExistingTargetVm(vm, cluster))
        .map((vm) => text(vm.name || vm.vm_name).replace(`${text(cluster.name)}-`, ""))
    );
    for (const vmName of existingVmNames) {
      const oldHost = text(existingCluster?.vm_node_map?.[vmName]);
      const oldStorage = text(existingCluster?.vm_storage_map?.[vmName]);
      const oldDiskGb = number(existingCluster?.vm_size_map?.[vmName]?.disk_gb);
      const entry = storageLookup.get(`${oldHost}:${oldStorage}`);
      if (entry && oldDiskGb > 0) {
        const key = storageCapacityKey(entry);
        const capacityEntry = capacityByStorage.get(key);
        if (capacityEntry) capacityEntry.avail += oldDiskGb * GB;
      }
    }
  }

  for (const [key, plannedDisk] of plannedDiskByStorage) {
    const storage = capacityByStorage.get(key);
    if (!storage || plannedDisk > storage.avail) {
      return {
        ok: false,
        error: `Insufficient disk space on ${storage?.storage || key}: ${Math.ceil(plannedDisk / GB)} GiB requested, ${Math.floor(number(storage?.avail) / GB)} GiB free`,
      };
    }
  }

  return { ok: true };
}
