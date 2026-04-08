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
      throw new Error(`missing public zone name for Dashy URL template ${urlTemplate}`);
    }

    return urlTemplate.replaceAll("__ZONE_NAME__", zoneName);
  }

  return urlTemplate;
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
        icon: dashyItem.icon,
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
