function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeHostname(value) {
  const rawValue = trimString(value);
  if (!rawValue) {
    return "";
  }

  return rawValue
    .replace(/^https?:\/\//i, "")
    .replace(/^\/+/, "")
    .split("/")[0]
    .replace(/^\.+/, "");
}

function normalizeClusterSlug(value) {
  const trimmed = trimString(value).toLowerCase();
  if (!trimmed) {
    return "";
  }

  const withoutPrefix = trimmed.startsWith("twinbox-") ? trimmed.slice("twinbox-".length) : trimmed;
  return withoutPrefix
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");
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

export function buildPortalUrl(cluster = {}, fallback = {}) {
  const zoneName = normalizeHostname(
    trimString(cluster?.public_zone_name) ||
      trimString(fallback?.public_zone_name) ||
      twinboxPublicZoneName(
        normalizeClusterSlug(cluster?.slug || cluster?.id || fallback?.slug || fallback?.id),
        cluster?.dns_domain || fallback?.dns_domain
      )
  );

  if (!zoneName) {
    return "";
  }

  return `https://portal.${zoneName}`;
}

export const buildAdminDashboardUrl = buildPortalUrl;
