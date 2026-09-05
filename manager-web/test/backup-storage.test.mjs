import test from "node:test";
import assert from "node:assert/strict";
import { mergeBackupDiscovery } from "../src/backup-storage.js";

const data = {
  ip: "192.0.2.5",
  hosts: [
    {
      node: "large",
      free_memory: 16 * 1024 ** 3,
      error: "",
      storages: [
        { storage: "fast", avail: 1000 * 1024 ** 3 },
        { storage: "shared", avail: 600 * 1024 ** 3 },
      ],
    },
    {
      node: "small",
      free_memory: 8 * 1024 ** 3,
      error: "",
      storages: [
        { storage: "other", avail: 800 * 1024 ** 3 },
        { storage: "shared", avail: 600 * 1024 ** 3 },
      ],
    },
  ],
};
test("empty answers receive suitable host, largest disk and IP", () => {
  const draft = mergeBackupDiscovery({}, data);
  assert.equal(draft.seaweedfs_node, "large");
  assert.equal(draft.seaweedfs_datastore, "fast");
  assert.equal(draft.seaweedfs_ip, data.ip);
});
test("late discovery preserves user IP and host; host changes retain only valid disks", () => {
  const draft = {
    seaweedfs_node: "small",
    seaweedfs_datastore: "shared",
    seaweedfs_ip: "192.0.2.6",
  };
  assert.equal(mergeBackupDiscovery(draft, data).seaweedfs_ip, "192.0.2.6");
  assert.equal(mergeBackupDiscovery(draft, data).seaweedfs_datastore, "shared");
  assert.equal(
    mergeBackupDiscovery({ ...draft, seaweedfs_datastore: "fast" }, data).seaweedfs_datastore,
    "other"
  );
});
test("existing VM overrides old answers and insufficient hosts are not proposed", () => {
  const existing = {
    node: "saved",
    datastore: "saved-disk",
    ip_address: "192.0.2.6",
    data_disk_gb: 800,
  };
  assert.equal(mergeBackupDiscovery({}, { ...data, existing }).seaweedfs_node, "saved");
  assert.equal(mergeBackupDiscovery({ seaweedfs_data_disk_gb: 2000 }, data).seaweedfs_node, "");
});
