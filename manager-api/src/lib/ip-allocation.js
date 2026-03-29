function preferredVipOctets() {
  const values = [];
  for (let octet = 50; octet <= 240; octet += 1) values.push(octet);
  for (let octet = 241; octet <= 254; octet += 1) values.push(octet);
  for (let octet = 2; octet < 50; octet += 1) values.push(octet);
  return values;
}

function preferredStartOctets() {
  const values = [];
  for (let octet = 50; octet <= 252; octet += 1) values.push(octet);
  for (let octet = 2; octet < 50; octet += 1) values.push(octet);
  return values;
}

function preferredStartOctetsForVip(vipOctet) {
  const baseline = preferredStartOctets().filter((octet) => octet !== vipOctet + 1);
  if (Number.isInteger(vipOctet + 1) && vipOctet + 1 <= 252) {
    return [vipOctet + 1, ...baseline];
  }
  return baseline;
}

export function buildIpBlock(prefix, startOctet, nodeCount) {
  return Array.from({ length: nodeCount }, (_, offset) => `${prefix}.${startOctet + offset}`);
}

export async function selectSuggestedIpAllocation({
  managementIp,
  nodeCount,
  isIpInUse,
  isAllocationValid = async () => true,
}) {
  if (typeof isIpInUse !== "function") {
    throw new TypeError("isIpInUse must be a function");
  }

  const octets = String(managementIp || "").split(".").map(Number);
  const prefix = `${octets[0]}.${octets[1]}.${octets[2]}`;
  const managementOctet = octets[3];
  let foundFreeVip = false;

  for (const vipOctet of preferredVipOctets()) {
    if (vipOctet === managementOctet) continue;

    const vipIp = `${prefix}.${vipOctet}`;
    if (await isIpInUse(vipIp)) {
      continue;
    }
    foundFreeVip = true;

    for (const startOctet of preferredStartOctetsForVip(vipOctet)) {
      const blockOctets = Array.from({ length: nodeCount }, (_, offset) => startOctet + offset);
      if (blockOctets.some((octet) => octet > 254 || octet === managementOctet || octet === vipOctet)) {
        continue;
      }

      const ipBlock = buildIpBlock(prefix, startOctet, nodeCount);
      const occupiedIp = [];
      for (const ip of ipBlock) {
        if (await isIpInUse(ip)) {
          occupiedIp.push(ip);
        }
      }
      if (occupiedIp.length > 0) {
        continue;
      }

      const validation = await isAllocationValid({
        vipIp,
        startIp: `${prefix}.${startOctet}`,
        nodeCount,
        ipBlock,
      });

      if (validation === false || validation?.ok === false) {
        continue;
      }

      return {
        subnet: `${prefix}.0/24`,
        vip_ip: vipIp,
        start_ip: `${prefix}.${startOctet}`,
        start_ip_block: ipBlock,
      };
    }
  }

  if (!foundFreeVip) {
    throw new Error(`No free VIP address found in ${prefix}.0/24`);
  }

  throw new Error(`No free consecutive ${nodeCount}-IP block found in ${prefix}.0/24`);
}
