import test from "node:test";
import assert from "node:assert/strict";

import { selectSuggestedIpAllocation } from "../../manager-api/src/lib/ip-allocation.js";

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
  assert.equal(allocation.start_ip, "192.168.2.59");
  assert.deepEqual(allocation.start_ip_block, [
    "192.168.2.59",
    "192.168.2.60",
    "192.168.2.61",
  ]);
});

test("ip allocation keeps scanning when validation rejects a free-looking block", async () => {
  const validatedStarts = [];

  const allocation = await selectSuggestedIpAllocation({
    managementIp: "192.168.2.50",
    nodeCount: 1,
    isIpInUse: () => false,
    isAllocationValid: ({ startIp }) => {
      validatedStarts.push(startIp);
      return { ok: startIp !== "192.168.2.52" };
    },
  });

  assert.deepEqual(validatedStarts.slice(0, 2), [
    "192.168.2.52",
    "192.168.2.53",
  ]);
  assert.equal(allocation.start_ip, "192.168.2.53");
});
