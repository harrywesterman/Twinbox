function trimString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalizeHostname(value) {
  const rawValue = trimString(value);
  if (!rawValue) {
    return '';
  }

  return rawValue
    .replace(/^https?:\/\//i, '')
    .replace(/^\/+/, '')
    .split('/')[0]
    .replace(/^\.+/, '');
}

export function twinboxPublicZoneName(clusterId, clusterDnsDomain) {
  const normalizedClusterId = trimString(clusterId).toLowerCase();
  const normalizedDnsDomain = trimString(clusterDnsDomain);

  if (!normalizedClusterId || !normalizedDnsDomain) {
    return '';
  }

  if (normalizedClusterId === 'prd') {
    return normalizedDnsDomain;
  }

  if (normalizedDnsDomain.startsWith(`${normalizedClusterId}.`)) {
    return normalizedDnsDomain;
  }

  return `${normalizedClusterId}.${normalizedDnsDomain}`;
}

export function buildAdminDashboardUrl(cluster = {}) {
  const zoneName = normalizeHostname(
    trimString(cluster?.public_zone_name)
      || twinboxPublicZoneName(cluster?.slug || cluster?.id, cluster?.dns_domain),
  );

  if (!zoneName) {
    return '';
  }

  return `https://admin.${zoneName}`;
}
