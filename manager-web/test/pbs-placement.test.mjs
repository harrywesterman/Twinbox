import assert from "node:assert/strict";
import test from "node:test";
import { pbsHosts, validatePbsPlacement } from "../../lib/pbs-placement.mjs";

const nodes = [{ node: "pve1", status: "online", maxmem: 16 * 1024 ** 3, mem: 4 * 1024 ** 3 }];
const storages = [
  {
    node: "pve1",
    storage: "local-lvm",
    content: "images,import",
    active: 1,
    enabled: 1,
    avail: 300 * 1024 ** 3,
  },
  { node: "pve1", storage: "local", content: "iso", active: 1, enabled: 1, avail: 20 * 1024 ** 3 },
];

test("PBS discovery returns online hosts and VM datastores", () => {
  const hosts = pbsHosts({
    nodes,
    storages,
    networks: [{ node: "pve1", iface: "vmbr0", active: 1 }],
    cluster: { bridge: "vmbr0" },
  });
  assert.equal(hosts[0].node, "pve1");
  assert.equal(hosts[0].storages[0].storage, "local-lvm");
  assert.equal(hosts[0].error, "");
});

test("PBS placement counts system and cache capacity", () => {
  const hosts = pbsHosts({
    nodes,
    storages,
    networks: [{ node: "pve1", iface: "vmbr0", active: 1 }],
    cluster: { bridge: "vmbr0" },
  });
  assert.doesNotThrow(() =>
    validatePbsPlacement(hosts, {
      pbs_node: "pve1",
      pbs_datastore: "local-lvm",
      pbs_cache_datastore: "local-lvm",
      pbs_cpu: 4,
      pbs_memory_gb: 8,
      pbs_system_disk_gb: 32,
      pbs_cache_disk_gb: 128,
    })
  );
  assert.throws(
    () =>
      validatePbsPlacement(hosts, {
        pbs_node: "pve1",
        pbs_datastore: "local-lvm",
        pbs_cache_datastore: "local-lvm",
        pbs_cpu: 4,
        pbs_memory_gb: 8,
        pbs_system_disk_gb: 200,
        pbs_cache_disk_gb: 128,
      }),
    /needs 328 GiB/
  );
});
