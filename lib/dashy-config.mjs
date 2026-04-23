import { twinboxPublicZoneName } from "./cluster-public-zone.mjs";

const FIXED_DASHY_ITEMS = [
  {
    section: "Platform",
    title: "Cloudflare",
    description: "DNS and security dashboard",
    icon: "configure-cloudflare-dns",
    url: "https://dash.cloudflare.com/",
    order: 10000,
  },
  {
    section: "Platform",
    title: "GitHub",
    description: "Twinbox source repository",
    icon: "github",
    url: "https://github.com/harrywesterman/Twinbox",
    order: 10001,
  },
];

function wizardIconUrl(zoneName, fileBase) {
  return zoneName ? `https://twinboxwizard.${zoneName}/assets/step-icons/${fileBase}.svg` : "favicon";
}

const DASHY_OFFICIAL_ICON_BY_STEP = new Map([
  ["provision-nodes", "provision-nodes"],
  ["install-argocd", "install-argocd"],
  ["install-longhorn-storage", "install-longhorn-storage"],
  ["install-secret-sync", "install-secret-sync"],
  ["install-cloudnativepg", "install-cloudnativepg"],
  ["install-traefik", "install-traefik"],
  ["install-headlamp", "install-headlamp"],
  ["install-grafana", "install-grafana"],
  ["install-prometheus", "install-prometheus"],
  ["install-loki", "install-loki"],
  ["install-pgadmin4", "install-pgadmin4"],
  ["install-wiredoor-gateway", "install-wiredoor-gateway"],
  ["install-authentik-idp", "install-authentik-idp"],
  ["configure-cloudflare-dns", "configure-cloudflare-dns"],
  ["install-dashy-dashboard", "install-dashy-dashboard"],
  ["install-twinbox-portal", "install-twinbox-portal"],
  ["install-ntfy", "install-ntfy"],
  ["install-velero-backup", "install-velero-backup"],
  ["install-velero-ui", "install-velero-ui"],
  ["install-proxmox-backup-system", "install-proxmox-backup-system"],
  ["install-nextcloud", "install-nextcloud"],
  ["install-opencloud", "install-opencloud"],
  ["install-immich", "install-immich"],
  ["install-zulip", "install-zulip"],
  ["install-paperless", "install-paperless"],
  ["install-karakeep", "install-karakeep"],
  ["install-gitea", "install-gitea"],
  ["install-uptimekuma", "install-uptimekuma"],
  ["install-n8n", "install-n8n"],
  ["install-audiobookshelf", "install-audiobookshelf"],
  ["install-freshrss", "install-freshrss"],
  ["install-jitsi", "install-jitsi"],
  ["install-flannel", "install-flannel"],
]);

const DASHY_OFFICIAL_ICON_BY_TITLE = new Map([
  ["Proxmox", "install-proxmox-backup-system"],
  ["Hubble", "provision-nodes"],
  ["SeaweedFS", "install-management-consoles"],
  ["SeaweedFS Admin", "install-management-consoles"],
  ["Wiredoor", "install-wiredoor-gateway"],
  ["Headlamp", "install-headlamp"],
  ["Grafana", "install-grafana"],
  ["Prometheus", "install-prometheus"],
  ["Loki", "install-loki"],
  ["CloudNativePG", "install-cloudnativepg"],
  ["Argo CD", "install-argocd"],
  ["Authentik", "install-authentik-idp"],
  ["Dashy", "install-dashy-dashboard"],
  ["Cloudflare", "configure-cloudflare-dns"],
  ["Ntfy", "install-ntfy"],
  ["Velero", "install-velero-backup"],
  ["Nextcloud", "install-nextcloud"],
  ["Immich", "install-immich"],
  ["Zulip", "install-zulip"],
  ["Paperless", "install-paperless"],
  ["Karakeep", "install-karakeep"],
  ["Gitea", "install-gitea"],
  ["Uptime Kuma", "install-uptimekuma"],
  ["n8n", "install-n8n"],
  ["Audiobookshelf", "install-audiobookshelf"],
  ["FreshRSS", "install-freshrss"],
  ["Jitsi", "install-jitsi"],
  ["Proxmox Backup Server", "install-proxmox-backup-system"],
  ["pgAdmin 4", "install-pgadmin4"],
  ["GitHub", "github"],
]);

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function readNestedValue(source, keyPath) {
  const normalizedPath = trimString(keyPath);
  if (!normalizedPath) {
    return "";
  }

  let cursor = source;
  for (const segment of normalizedPath.split(".")) {
    if (!cursor || typeof cursor !== "object") {
      return "";
    }
    cursor = cursor[segment];
  }

  return typeof cursor === "string" ? cursor.trim() : "";
}

function interpolateUrlTemplate(urlTemplate, zoneName) {
  if (!trimString(urlTemplate)) {
    return "";
  }

  if (urlTemplate.includes("__ZONE_NAME__")) {
    if (!zoneName) {
      return "";
    }

    return urlTemplate.replaceAll("__ZONE_NAME__", zoneName);
  }

  return urlTemplate;
}

function resolveArtwork(value, zoneName) {
  const normalized = trimString(value);
  if (!normalized) {
    return "";
  }

  if (/^https?:\/\//i.test(normalized)) {
    return normalized;
  }

  return wizardIconUrl(zoneName, normalized);
}

function resolveDashyIcon(step, dashyItem, zoneName) {
  const explicitIcon = trimString(dashyItem?.icon);
  if (/^https?:\/\//i.test(explicitIcon)) {
    return interpolateUrlTemplate(explicitIcon, zoneName);
  }

  const titleIcon = DASHY_OFFICIAL_ICON_BY_TITLE.get(trimString(dashyItem?.title));
  if (titleIcon) {
    return resolveArtwork(titleIcon, zoneName);
  }

  const stepIcon = DASHY_OFFICIAL_ICON_BY_STEP.get(step.id);
  if (stepIcon) {
    return resolveArtwork(stepIcon, zoneName);
  }

  if (/^(?:install|configure|provision)-[a-z0-9-]+$/i.test(explicitIcon)) {
    return resolveArtwork(explicitIcon, zoneName);
  }

  return resolveArtwork("install-dashy-dashboard", zoneName) || "favicon";
}

function stepStateAllowsDashyItem(state) {
  const status = trimString(state?.status);
  return status === "succeeded" || status === "configured";
}

function appendSectionItem(sectionMap, sectionName, item) {
  const key = trimString(sectionName) || "Platform";
  const section = sectionMap.get(key) || { name: key, items: [] };
  section.items.push(item);
  sectionMap.set(key, section);
}

export function stepHasDashyItems(step) {
  return Array.isArray(step?.dashy?.items) && step.dashy.items.length > 0;
}

function normalizeStepIdSet(values) {
  const stepIds = new Set();
  if (!values) {
    return stepIds;
  }

  if (typeof values === "string") {
    const stepId = trimString(values);
    if (stepId) {
      stepIds.add(stepId);
    }
    return stepIds;
  }

  if (typeof values[Symbol.iterator] !== "function") {
    return stepIds;
  }

  for (const value of values) {
    const stepId = trimString(value);
    if (stepId) {
      stepIds.add(stepId);
    }
  }

  return stepIds;
}

export function buildDashyConfig({ steps, stepStateById, cluster, excludeStepIds = [] }) {
  const clusterSlug = trimString(cluster?.slug || cluster?.id);
  const clusterDnsDomain = trimString(cluster?.dns_domain);
  const zoneName = twinboxPublicZoneName(clusterSlug, clusterDnsDomain);
  const excludedStepIds = normalizeStepIdSet(excludeStepIds);
  const sectionMap = new Map();

  const sortedSteps = [...steps].sort((left, right) => left.order - right.order);
  for (const step of sortedSteps) {
    if (excludedStepIds.has(step.id)) {
      continue;
    }

    if (!stepHasDashyItems(step)) {
      continue;
    }

    const state = stepStateById.get(step.id) || null;
    if (!stepStateAllowsDashyItem(state)) {
      continue;
    }

    step.dashy.items.forEach((dashyItem, index) => {
      const url = dashyItem.url_template
        ? interpolateUrlTemplate(dashyItem.url_template, zoneName)
        : readNestedValue(state?.outputs || {}, dashyItem.output_url_key);

      if (!trimString(url)) {
        return;
      }

      appendSectionItem(sectionMap, dashyItem.section, {
        title: dashyItem.title,
        description: dashyItem.description,
        url,
        icon: resolveDashyIcon(step, dashyItem, zoneName),
        _order: (step.order * 100) + index,
      });
    });
  }

  for (const fixedItem of FIXED_DASHY_ITEMS) {
    appendSectionItem(sectionMap, fixedItem.section, {
      title: fixedItem.title,
      description: fixedItem.description,
      url: fixedItem.url,
      icon: resolveArtwork(fixedItem.icon, zoneName) || resolveSimpleIconsUrl(fixedItem.icon) || fixedItem.icon,
      _order: fixedItem.order,
    });
  }

  const orderedSections = ["Platform", "Apps"]
    .map((sectionName) => sectionMap.get(sectionName))
    .filter(Boolean)
    .map((section) => ({
      name: section.name,
      displayData: {
        sortBy: "alphabetical",
      },
      items: section.items
        .sort((left, right) => {
          if (left._order !== right._order) {
            return left._order - right._order;
          }
          return left.title.localeCompare(right.title);
        })
        .map(({ _order, ...item }) => item),
    }))
    .filter((section) => section.items.length > 0);

  return {
    pageInfo: {
      title: "Admin",
      description: "Twinbox Admin start pagina",
    },
    appConfig: {
      preventWriteToDisk: true,
      faviconApi: "local",
      iconSize: "large",
      layout: "vertical",
      theme: "nord-frost",
      auth: {
        enableOidc: true,
        oidc: {
          clientId: "__DASHY_OIDC_CLIENT_ID__",
          endpoint: "__DASHY_OIDC_ENDPOINT__",
          scope: "__DASHY_OIDC_SCOPE__",
        },
      },
    },
    sections: orderedSections,
  };
}
