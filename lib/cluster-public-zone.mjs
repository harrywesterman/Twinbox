function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function twinboxPublicZoneName(clusterId, clusterDnsDomain) {
  const normalizedClusterId = trimString(clusterId).toLowerCase();
  const normalizedDnsDomain = trimString(clusterDnsDomain);

  if (!normalizedClusterId || !normalizedDnsDomain) {
    return "";
  }

  if (normalizedClusterId === "prd") {
    return normalizedDnsDomain;
  }

  if (normalizedDnsDomain.startsWith(`${normalizedClusterId}.`)) {
    return normalizedDnsDomain;
  }

  return `${normalizedClusterId}.${normalizedDnsDomain}`;
}
