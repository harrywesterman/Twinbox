import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  backupHosts,
  reservedBackupIps,
  suggestBackupIp,
  validateBackupIp,
  validateBackupPlacement,
} from "../../lib/backup-placement.mjs";

const GiB = 1024 ** 3;
const cluster = {
  bridge: "vmbr-test",
  gateway_ip: "192.0.2.1",
  node_prefix_length: 29,
  vm_ip_map: { worker: "192.0.2.2" },
  vip_ip: "192.0.2.3",
};
function fixture() {
  return {
    cluster,
    nodes: [
      { node: "small", status: "online", maxmem: 8 * GiB, mem: 4 * GiB },
      { node: "large", status: "online", maxmem: 32 * GiB, mem: 4 * GiB },
      { node: "offline", status: "offline" },
    ],
    storages: ["small", "large"].flatMap((node) => [
      { node, storage: "files", content: "iso,snippets", active: 1, avail: 10 * GiB },
      { node, storage: "disk", content: "images", active: 1, avail: 520 * GiB },
      { node, storage: "disabled", content: "images", active: 1, enabled: 0, avail: 900 * GiB },
    ]),
    networks: ["small", "large"].map((node) => ({ node, iface: cluster.bridge, active: 1 })),
  };
}
const inputs = {
  seaweedfs_node: "large",
  seaweedfs_datastore: "disk",
  seaweedfs_data_disk_gb: 500,
  seaweedfs_ip: "192.0.2.5",
};

test("hosts are ordered by free RAM and disks filtered by host, content and activity", () => {
  const hosts = backupHosts(fixture());
  assert.deepEqual(
    hosts.map((h) => h.node),
    ["large", "small"]
  );
  assert.deepEqual(
    hosts[0].storages.map((s) => s.storage),
    ["disk"]
  );
  assert.equal(validateBackupPlacement(hosts, inputs).file_datastore, "files");
  assert.throws(
    () => validateBackupPlacement(hosts, { ...inputs, seaweedfs_data_disk_gb: 501 }),
    /521 GiB/
  );
  assert.throws(
    () => validateBackupPlacement(hosts, { ...inputs, seaweedfs_node: "offline" }),
    /online/
  );
});
test("missing bridge or installation storage blocks host", () => {
  const data = fixture();
  data.networks = [];
  assert.throws(() => validateBackupPlacement(backupHosts(data), inputs), /Bridge/);
  data.networks = fixture().networks;
  data.storages = data.storages.filter((s) => s.storage !== "files");
  assert.throws(() => validateBackupPlacement(backupHosts(data), inputs), /ISO\/snippets/);
});
test("existing VM cannot move; consumed capacity is not charged a second time", () => {
  const existing = {
    vm_id: 123,
    node: "large",
    datastore: "disk",
    data_disk_gb: 500,
    ip_address: inputs.seaweedfs_ip,
  };
  const hosts = backupHosts(fixture());
  hosts[0].free_memory = 0;
  hosts[0].storages[0].avail = 0;
  validateBackupPlacement(hosts, inputs, existing);
  for (const [key, value] of [
    ["seaweedfs_node", "small"],
    ["seaweedfs_ip", "192.0.2.6"],
    ["seaweedfs_datastore", "other"],
    ["seaweedfs_data_disk_gb", 600],
  ]) {
    assert.throws(
      () => validateBackupPlacement(hosts, { ...inputs, [key]: value }, existing),
      /Cannot change/
    );
  }
});
test("IP discovery respects actual prefix, reservations, occupied IPs and exhaustion", async () => {
  const reserved = reservedBackupIps([cluster], "192.0.2.4");
  const checked = [];
  assert.equal(
    await suggestBackupIp(cluster, reserved, (ip) => {
      checked.push(ip);
      return ip.endsWith(".5");
    }),
    "192.0.2.6"
  );
  assert.deepEqual(checked, ["192.0.2.5", "192.0.2.6"]);
  for (const ip of ["192.0.2.0", "192.0.2.7", "192.0.2.8", "192.0.2.2"])
    assert.throws(() => validateBackupIp(cluster, ip, reserved));
  await assert.rejects(
    suggestBackupIp(cluster, reserved, () => true),
    /No free IP/
  );
  await assert.rejects(
    suggestBackupIp(cluster, reserved, () => {
      throw new Error("probe unavailable");
    }),
    /probe unavailable/
  );
});
test("runner preflight uses explicit node and rejects missing or reserved choices", () => {
  const run = (input) =>
    spawnSync(process.execPath, ["scripts/manager/check-seaweedfs-placement.mjs"], {
      cwd: new URL("../../", import.meta.url),
      input: JSON.stringify({ ...fixture(), inputs: input }),
      encoding: "utf8",
    });
  assert.equal(run(inputs).stdout, "files");
  assert.equal(run({ ...inputs, seaweedfs_node: "" }).status, 1);
  assert.equal(run({ ...inputs, seaweedfs_ip: cluster.vip_ip }).status, 1);
});
