import { twinboxPublicZoneName } from "./cluster-public-zone.mjs";

const FIXED_DASHY_ITEMS = [
  {
    section: "Platform",
    title: "Cloudflare",
    description: "DNS and security dashboard",
    icon: "si-cloudflare",
    url: "https://dash.cloudflare.com/",
    order: 10000,
  },
  {
    section: "Platform",
    title: "GitHub",
    description: "Twinbox source repository",
    icon: "si-github",
    url: "https://github.com/harrywesterman/Twinbox",
    order: 10001,
  },
];

const DASHY_OFFICIAL_ICON_BY_STEP = new Map([
  ["provision-nodes", "si-cilium"],
  ["install-argocd", "si-argo"],
  ["install-longhorn-storage", "si-longhorn"],
  ["install-secret-sync", "si-openbao"],
  ["install-cloudnativepg", "https://cloudnative-pg.io/favicon.ico"],
  ["install-traefik", "si-traefikproxy"],
  ["install-whoami", "si-traefikproxy"],
  ["install-headlamp", "https://headlamp.dev/img/favicon.png"],
  ["install-grafana", "si-grafana"],
  ["install-prometheus", "si-prometheus"],
  ["install-loki", "https://raw.githubusercontent.com/grafana/loki/main/docs/sources/logo.png"],
  ["install-pgadmin4", "https://raw.githubusercontent.com/pgadmin-org/pgadmin4/master/web/pgadmin/static/favicon.ico"],
  ["install-wiredoor-gateway", "https://www.wiredoor.net/favicon.ico"],
  ["install-authentik-idp", "si-authentik"],
  ["configure-cloudflare-dns", "si-cloudflare"],
  ["install-dashy-dashboard", "https://dashy.to/favicon.ico"],
  ["install-ntfy", "si-ntfy"],
  ["install-velero-backup", "si-velero"],
  ["install-proxmox-backup-system", "si-proxmox"],
  ["install-nextcloud", "si-nextcloud"],
  ["install-immich", "si-immich"],
  ["install-zulip", "si-zulip"],
  ["install-paperless", "si-paperlessngx"],
  ["install-karakeep", "si-karakeep"],
  ["install-gitea", "si-gitea"],
  ["install-uptimekuma", "si-uptimekuma"],
  ["install-n8n", "si-n8n"],
  ["install-audiobookshelf", "si-audiobookshelf"],
  ["install-freshrss", "si-freshrss"],
  ["install-jitsi", "si-jitsi"],
  ["install-cloudtty", "https://raw.githubusercontent.com/cloudtty/cloudtty/main/docs/cloudtty.svg"],
  ["install-traefik-manager", "si-traefikproxy"],
]);

const DASHY_OFFICIAL_ICON_BY_TITLE = new Map([
  ["Twinbox Wizard", (zoneName) => (zoneName ? `https://twinboxwizard.${zoneName}/favicon.svg` : "favicon")],
  ["Proxmox", "si-proxmox"],
  ["SeaweedFS", "https://seaweedfs.com/favicon.ico"],
  ["SeaweedFS Admin", "https://seaweedfs.com/favicon.ico"],
  ["Hubble", "si-cilium"],
  ["Cloudtty", "https://raw.githubusercontent.com/cloudtty/cloudtty/main/docs/cloudtty.svg"],
  ["Wiredoor", "https://www.wiredoor.net/favicon.ico"],
  ["Headlamp", "https://headlamp.dev/img/favicon.png"],
  ["Grafana", "si-grafana"],
  ["Prometheus", "si-prometheus"],
  ["Loki", "https://raw.githubusercontent.com/grafana/loki/main/docs/sources/logo.png"],
  ["CloudNativePG", "https://cloudnative-pg.io/favicon.ico"],
  ["Argo CD", "si-argo"],
  ["Authentik", "si-authentik"],
  ["Dashy", "https://dashy.to/favicon.ico"],
  ["Whoami", "si-traefikproxy"],
  ["Cloudflare", "si-cloudflare"],
  ["Ntfy", "si-ntfy"],
  ["Velero", "si-velero"],
  ["Nextcloud", "si-nextcloud"],
  ["Immich", "si-immich"],
  ["Zulip", "si-zulip"],
  ["Paperless", "si-paperlessngx"],
  ["Karakeep", "si-karakeep"],
  ["Gitea", "si-gitea"],
  ["Uptime Kuma", "si-uptimekuma"],
  ["n8n", "si-n8n"],
  ["Audiobookshelf", "si-audiobookshelf"],
  ["FreshRSS", "si-freshrss"],
  ["Jitsi", "si-jitsi"],
  ["Traefik Manager", "si-traefikproxy"],
  ["Proxmox Backup Server", "si-proxmox"],
  ["Wiredoor", "https://www.wiredoor.net/favicon.ico"],
  ["pgAdmin 4", "https://raw.githubusercontent.com/pgadmin-org/pgadmin4/master/web/pgadmin/static/favicon.ico"],
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

function isOfficialIconValue(icon) {
  return /^si-[a-z0-9-]+$/i.test(icon) || /^https?:\/\//i.test(icon);
}

function resolveDashyIcon(step, dashyItem, zoneName) {
  const explicitIcon = trimString(dashyItem?.icon);
  if (isOfficialIconValue(explicitIcon)) {
    return interpolateUrlTemplate(explicitIcon, zoneName);
  }

  const stepIcon = DASHY_OFFICIAL_ICON_BY_STEP.get(step.id);
  if (typeof stepIcon === "string") {
    return interpolateUrlTemplate(stepIcon, zoneName);
  }

  const titleIcon = DASHY_OFFICIAL_ICON_BY_TITLE.get(trimString(dashyItem?.title));
  if (typeof titleIcon === "function") {
    return titleIcon(zoneName);
  }
  if (typeof titleIcon === "string") {
    return interpolateUrlTemplate(titleIcon, zoneName);
  }

  return "favicon";
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

export function buildDashyConfig({ steps, stepStateById, cluster }) {
  const clusterSlug = trimString(cluster?.slug || cluster?.id);
  const clusterDnsDomain = trimString(cluster?.dns_domain);
  const zoneName = twinboxPublicZoneName(clusterSlug, clusterDnsDomain);
  const sectionMap = new Map();

  const sortedSteps = [...steps].sort((left, right) => left.order - right.order);
  for (const step of sortedSteps) {
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
      icon: fixedItem.icon,
      _order: fixedItem.order,
    });
  }

  const orderedSections = ["Platform", "Apps"]
    .map((sectionName) => sectionMap.get(sectionName))
    .filter(Boolean)
    .map((section) => ({
      name: section.name,
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
      title: "Start",
      description: "Twinbox cluster start page",
    },
    appConfig: {
      preventWriteToDisk: true,
      faviconApi: "local",
      iconSize: "large",
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
