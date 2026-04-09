import test from "node:test";
import assert from "node:assert/strict";

import { checkIpAvailability, selectSuggestedIpAllocation } from "../../manager-api/src/lib/ip-allocation.js";

test("ip allocation skips partially occupied candidate blocks", async () => {
  const occupiedIps = new Set([
    "192.168.2.53",
    "192.168.2.56",
    "192.168.2.58",
  ]);

  const allocation = await selectSuggestedIpAllocation({
    managementIp: "192.168.2.50",
    nodeCount: 3,
    isIpInUse: (ip) => occupiedIps.has(ip),
  });

  assert.equal(allocation.vip_ip, "192.168.2.51");
  assert.deepEqual(allocation.vm_ips, [
    "192.168.2.52",
    "192.168.2.54",
    "192.168.2.55",
  ]);
});

test("ip allocation returns a single free vm ip when only one node is requested", async () => {
  const allocation = await selectSuggestedIpAllocation({
    managementIp: "192.168.2.50",
    nodeCount: 1,
    isIpInUse: () => false,
  });

  assert.equal(allocation.vip_ip, "192.168.2.51");
  assert.deepEqual(allocation.vm_ips, ["192.168.2.52"]);
});

test("ip availability checks deduplicate inputs and report free versus used", async () => {
  const probed = [];
  const result = await checkIpAvailability({
    ips: [
      "192.168.2.61",
      "192.168.2.61",
      "192.168.2.72",
    ],
    isIpInUse: (ip) => {
      probed.push(ip);
      return ip === "192.168.2.72";
    },
  });

  assert.deepEqual(probed, [
    "192.168.2.61",
    "192.168.2.72",
  ]);
  assert.equal(result.probed_addresses, 2);
  assert.deepEqual(result.results, [
    { ip: "192.168.2.61", in_use: false, free: true },
    { ip: "192.168.2.72", in_use: true, free: false },
  ]);
});
