function preferredVipOctets() {
  const values = [];
  for (let octet = 50; octet <= 240; octet += 1) values.push(octet);
  for (let octet = 241; octet <= 254; octet += 1) values.push(octet);
  for (let octet = 2; octet < 50; octet += 1) values.push(octet);
  return values;
}

export function buildIpBlock(prefix, startOctet, nodeCount) {
  return Array.from({ length: nodeCount }, (_, offset) => `${prefix}.${startOctet + offset}`);
}

function preferredNodeOctetsForVip(vipOctet) {
  const ordered = [];
  for (let octet = vipOctet + 1; octet <= 254; octet += 1) {
    ordered.push(octet);
  }
  for (let octet = 2; octet < vipOctet; octet += 1) {
    ordered.push(octet);
  }
  return ordered;
}

export async function selectSuggestedIpAllocation({
  managementIp,
  nodeCount,
  isIpInUse,
}) {
  if (typeof isIpInUse !== "function") {
    throw new TypeError("isIpInUse must be a function");
  }

  const octets = String(managementIp || "").split(".").map(Number);
  const prefix = `${octets[0]}.${octets[1]}.${octets[2]}`;
  const managementOctet = octets[3];
  let probedAddresses = 0;

  for (const vipOctet of preferredVipOctets()) {
    if (vipOctet === managementOctet) continue;

    const vipIp = `${prefix}.${vipOctet}`;
    probedAddresses += 1;
    if (await isIpInUse(vipIp)) {
      continue;
    }

    const usedOctets = new Set([managementOctet, vipOctet]);
    const vmIps = [];

    for (const nodeOctet of preferredNodeOctetsForVip(vipOctet)) {
      if (nodeOctet === managementOctet || nodeOctet === vipOctet || usedOctets.has(nodeOctet)) {
        continue;
      }

      const candidateIp = `${prefix}.${nodeOctet}`;
      probedAddresses += 1;
      if (await isIpInUse(candidateIp)) {
        continue;
      }

      vmIps.push(candidateIp);
      usedOctets.add(nodeOctet);
      if (vmIps.length === nodeCount) {
        return {
          subnet: `${prefix}.0/24`,
          vip_ip: vipIp,
          vm_ips: vmIps,
          probed_addresses: probedAddresses,
        };
      }
    }
  }

  let anyVipAvailable = false;
  for (const vipOctet of preferredVipOctets()) {
    if (vipOctet === managementOctet) continue;

    const vipIp = `${prefix}.${vipOctet}`;
    probedAddresses += 1;
    if (!(await isIpInUse(vipIp))) {
      anyVipAvailable = true;
      break;
    }
  }

  if (!anyVipAvailable) {
    throw new Error(`No free VIP address found in ${prefix}.0/24`);
  }

  throw new Error(`No free ${nodeCount}-IP allocation found in ${prefix}.0/24`);
}

export async function checkIpAvailability({
  ips = [],
  isIpInUse,
}) {
  if (typeof isIpInUse !== "function") {
    throw new TypeError("isIpInUse must be a function");
  }

  const normalizedIps = [];
  const seen = new Set();
  for (const ip of Array.isArray(ips) ? ips : []) {
    const normalized = String(ip || "").trim();
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    normalizedIps.push(normalized);
  }

  const results = [];
  let probedAddresses = 0;
  for (const ip of normalizedIps) {
    probedAddresses += 1;
    const inUse = Boolean(await isIpInUse(ip));
    results.push({
      ip,
      in_use: inUse,
      free: !inUse,
    });
  }

  return {
    results,
    probed_addresses: probedAddresses,
  };
}
