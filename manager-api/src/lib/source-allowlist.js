const DEFAULT_TRUSTED_CIDRS = ["127.0.0.1/32", "::1/128", "172.16.0.0/12", "10.0.0.0/8"];

function normalizeRemoteAddress(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }
  const withoutZone = raw.replace(/%.+$/, "");
  if (withoutZone.startsWith("::ffff:")) {
    return withoutZone.slice("::ffff:".length);
  }
  return withoutZone;
}

function ipv4ToBigInt(value) {
  const parts = String(value).split(".");
  if (parts.length !== 4) {
    return null;
  }
  let result = 0n;
  for (const part of parts) {
    if (!/^\d+$/.test(part)) {
      return null;
    }
    const octet = Number(part);
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) {
      return null;
    }
    result = (result << 8n) + BigInt(octet);
  }
  return result;
}

function expandIpv6(value) {
  const [headRaw, tailRaw] = String(value).toLowerCase().split("::");
  const head = headRaw ? headRaw.split(":") : [];
  const tail = tailRaw ? tailRaw.split(":") : [];
  if (String(value).includes("::") && String(value).split("::").length > 2) {
    return null;
  }
  if (!String(value).includes("::") && head.length !== 8) {
    return null;
  }
  const missing = 8 - head.length - tail.length;
  if (missing < 0) {
    return null;
  }
  const groups = [...head, ...Array(missing).fill("0"), ...tail];
  if (groups.length !== 8) {
    return null;
  }
  return groups;
}

function ipv6ToBigInt(value) {
  const groups = expandIpv6(value);
  if (!groups) {
    return null;
  }
  let result = 0n;
  for (const group of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(group)) {
      return null;
    }
    result = (result << 16n) + BigInt(parseInt(group, 16));
  }
  return result;
}

function parseIp(value) {
  const normalized = normalizeRemoteAddress(value);
  if (!normalized) {
    return null;
  }
  if (normalized.includes(":")) {
    const numeric = ipv6ToBigInt(normalized);
    return numeric === null ? null : { family: 6, bits: 128, numeric };
  }
  const numeric = ipv4ToBigInt(normalized);
  return numeric === null ? null : { family: 4, bits: 32, numeric };
}

function parseCidr(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return null;
  }
  const [address, prefixRaw] = raw.split("/");
  if (raw.split("/").length > 2) {
    return null;
  }
  const parsed = parseIp(address);
  if (!parsed) {
    return null;
  }
  const prefix =
    prefixRaw === undefined || prefixRaw === "" ? parsed.bits : Number.parseInt(prefixRaw, 10);
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > parsed.bits) {
    return null;
  }
  return { ...parsed, prefix };
}

function isIpInCidr(ip, cidr) {
  if (!ip || !cidr || ip.family !== cidr.family) {
    return false;
  }
  if (cidr.prefix === 0) {
    return true;
  }
  const shift = BigInt(ip.bits - cidr.prefix);
  return ip.numeric >> shift === cidr.numeric >> shift;
}

function parseTrustedCidrs(value) {
  const raw = String(value || "").trim();
  const entries = raw ? raw.split(",").map((entry) => entry.trim()) : DEFAULT_TRUSTED_CIDRS;
  return entries.map(parseCidr).filter(Boolean);
}

function isSourceAllowed(remoteAddress, trustedCidrs = parseTrustedCidrs()) {
  const ip = parseIp(remoteAddress);
  return Boolean(ip && trustedCidrs.some((cidr) => isIpInCidr(ip, cidr)));
}

function createSourceAllowlistMiddleware({ trustedCidrs = parseTrustedCidrs() } = {}) {
  return (req, res, next) => {
    const remoteAddress = req.socket?.remoteAddress || req.ip || "";
    if (isSourceAllowed(remoteAddress, trustedCidrs)) {
      next();
      return;
    }
    res.status(403).json({ error: "manager api source address is not trusted" });
  };
}

export {
  DEFAULT_TRUSTED_CIDRS,
  createSourceAllowlistMiddleware,
  isSourceAllowed,
  normalizeRemoteAddress,
  parseTrustedCidrs,
};
