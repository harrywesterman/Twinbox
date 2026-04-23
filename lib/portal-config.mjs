import { twinboxPublicZoneName } from "./cluster-public-zone.mjs";

const DEFAULT_APP_PALETTE = [
  "#2563eb",
  "#0ea5e9",
  "#14b8a6",
  "#22c55e",
  "#f59e0b",
  "#f97316",
  "#ef4444",
  "#ec4899",
  "#7c3aed",
  "#a855f7",
];

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function slugify(value) {
  return trimString(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function stableHash(input) {
  const text = trimString(input);
  let hash = 0;
  for (let index = 0; index < text.length; index += 1) {
    hash = (hash * 31 + text.charCodeAt(index)) >>> 0;
  }
  return hash;
}

function pickPalette(value) {
  return DEFAULT_APP_PALETTE[stableHash(value) % DEFAULT_APP_PALETTE.length];
}

function wizardIconUrl(zoneName, fileBase) {
  const normalizedFileBase = trimString(fileBase);
  if (!normalizedFileBase) {
    return "";
  }

  return `/assets/step-icons/${normalizedFileBase}.svg`;
}

function interpolateTemplate(value, zoneName, extra = {}) {
  const text = trimString(value);
  if (!text) {
    return "";
  }

  const replacements = {
    "__ZONE_NAME__": zoneName || "",
    "__PORTAL_HOST__": extra.portal_host || "",
    "__AUTHENTIK_ADMIN_URL__": extra.authentik_admin_url || "",
    "__AUTHENTIK_USER_URL__": extra.authentik_user_url || "",
  };

  let rendered = text;
  for (const [needle, replacement] of Object.entries(replacements)) {
    rendered = rendered.replaceAll(needle, replacement);
  }
  return rendered;
}

function normalizeList(value) {
  return Array.isArray(value)
    ? value.map((entry) => trimString(entry)).filter(Boolean)
    : [];
}

function normalizeManageableGroup(entry) {
  if (typeof entry === "string") {
    const name = trimString(entry);
    if (!name) {
      return null;
    }

    return {
      name,
      label: name,
      description: "",
    };
  }

  if (!entry || typeof entry !== "object") {
    return null;
  }

  const name = trimString(entry.name);
  if (!name) {
    return null;
  }

  return {
    name,
    label: trimString(entry.label) || name,
    description: trimString(entry.description),
  };
}

function buildUserAdminConfig(content = {}) {
  const rawUserAdmin = content?.userAdmin && typeof content.userAdmin === "object"
    ? content.userAdmin
    : {};

  return {
    eyebrow: trimString(rawUserAdmin.eyebrow) || "Admin",
    title: trimString(rawUserAdmin.title) || "Gebruikers en groepen",
    description: trimString(rawUserAdmin.description)
      || "Beheer gebruikers en zakelijke groepen vanuit het Twinbox Portal.",
    emptyStateTitle: trimString(rawUserAdmin.emptyStateTitle) || "Nog geen beheerbare groepen ingesteld",
    emptyStateDescription: trimString(rawUserAdmin.emptyStateDescription)
      || "Voeg eerst beheerbare groepen toe aan de portal-config.",
    manageableGroups: Array.isArray(rawUserAdmin.manageableGroups)
      ? rawUserAdmin.manageableGroups
        .map((entry) => normalizeManageableGroup(entry))
        .filter(Boolean)
      : [],
  };
}

function buildAppProfileLookup(content = {}) {
  return content?.appProfiles && typeof content.appProfiles === "object"
    ? content.appProfiles
    : {};
}

function readStepValue(step, key) {
  return trimString(step?.[key]);
}

function buildCard({
  title,
  url,
  sourceStep,
  section,
  profile,
  adminOnly = false,
  status = "ready",
  index = 0,
  zoneName,
  portalHost,
  content,
  iconFileBase = "",
}) {
  const resolvedProfile = profile || {};
  const accent = trimString(resolvedProfile.accent) || pickPalette(title);
  const summary = trimString(resolvedProfile.summary) || readStepValue(sourceStep, "summary") || "";
  const description = trimString(resolvedProfile.description)
    || readStepValue(sourceStep, "explanation")
    || readStepValue(sourceStep, "side_help")
    || summary;
  const capabilities = normalizeList(resolvedProfile.capabilities);
  const label = trimString(resolvedProfile.label) || title;
  const route = `/apps/${slugify(title)}`;
  const iconUrl = wizardIconUrl(zoneName, sourceStep?.id || trimString(iconFileBase) || slugify(title));

  return {
    id: `${slugify(title)}-${index}`.replace(/-0$/, ""),
    slug: slugify(title),
    title,
    label,
    section: trimString(section) || trimString(resolvedProfile.category) || "Apps",
    url,
    route,
    accent,
    summary,
    description,
    capabilities: capabilities.length > 0 ? capabilities : [
      summary || `Open ${title}`,
      description || `Review the ${title} workspace`,
      adminOnly ? "Admin-only launcher" : "Start the app in one click",
    ].filter(Boolean),
    adminOnly,
    status,
    sourceStepId: sourceStep?.id || null,
    sourceStepTitle: sourceStep?.title || null,
    sourceStepSummary: readStepValue(sourceStep, "summary") || null,
    sourceStepExplanation: readStepValue(sourceStep, "explanation") || null,
    sourceStepSideHelp: readStepValue(sourceStep, "side_help") || null,
    iconText: String(title || "")
      .split(/\s+/)
      .filter(Boolean)
      .map((part) => part[0])
      .join("")
      .slice(0, 2)
      .toUpperCase() || "TB",
    iconUrl,
    iconAlt: `${title} icon`,
    liveUrl: interpolateTemplate(url, zoneName, {
      portal_host: portalHost,
      authentik_user_url: content?.settings?.authentikUserUrl || "",
    }),
  };
}

function collectStepCards({
  steps = [],
  stepStateById = new Map(),
  zoneName,
  portalHost,
  content = {},
  allowedCategoryIds = null,
}) {
  const profiles = buildAppProfileLookup(content);
  const cards = [];
  const allowedCategories = Array.isArray(allowedCategoryIds) && allowedCategoryIds.length > 0
    ? new Set(allowedCategoryIds.map((value) => trimString(value)).filter(Boolean))
    : null;

  const sortedSteps = [...steps].sort((left, right) => (left.order || 0) - (right.order || 0));
  for (const step of sortedSteps) {
    if (allowedCategories && !allowedCategories.has(step?.category_id)) {
      continue;
    }

    const dashyItems = Array.isArray(step?.dashy?.items) ? step.dashy.items : [];
    if (dashyItems.length === 0) {
      continue;
    }

    const state = stepStateById.get(step.id) || {};
    const status = trimString(state?.status);
    if (!["succeeded", "configured"].includes(status)) {
      continue;
    }

    dashyItems.forEach((item, index) => {
      const title = trimString(item?.title);
      if (!title) {
        return;
      }

      const profile = profiles[title] || profiles[step.id] || {};
      const section = trimString(item?.section) || trimString(profile.category) || "Apps";
      const url = trimString(item?.url_template)
        ? interpolateTemplate(item.url_template, zoneName, {
            portal_host: portalHost,
            authentik_user_url: content?.settings?.authentikUserUrl || "",
          })
        : trimString(item?.url) || trimString(item?.launch_url);

      if (!url) {
        return;
      }

      cards.push(buildCard({
        title,
        url,
        sourceStep: step,
        section,
        profile,
        status,
        index,
        zoneName,
        portalHost,
        content,
      }));
    });
  }

  return cards;
}

function collectStaticCards(items = [], { content, zoneName, portalHost, adminOnly = false }) {
  return items.map((item, index) => {
    const title = trimString(item.title);
    const profile = content?.appProfiles?.[title] || {};
    return buildCard({
      title,
      url: interpolateTemplate(item.url || item.url_template, zoneName, {
        portal_host: portalHost,
        authentik_user_url: content?.settings?.authentikUserUrl || "",
      }),
      sourceStep: null,
      section: item.section || profile.category || (adminOnly ? "Admin" : "Links"),
      profile: {
        ...profile,
        label: item.label || profile.label || (title === "Dashy" ? "Open Admin tools" : title),
        summary: item.description || profile.summary,
        capabilities: item.capabilities || profile.capabilities,
        accent: item.accent || profile.accent,
      },
      adminOnly,
      status: "ready",
      index,
      zoneName,
      portalHost,
      content,
      iconFileBase: trimString(item.icon) || (title === "Dashy" ? "install-dashy-dashboard" : ""),
    });
  });
}

export function buildPortalConfig({
  steps = [],
  stepStateById = new Map(),
  cluster = null,
  content = {},
}) {
  const clusterSlug = trimString(cluster?.slug || cluster?.id);
  const clusterDnsDomain = trimString(cluster?.dns_domain);
  const zoneName = twinboxPublicZoneName(clusterSlug, clusterDnsDomain);
  const portalHost = zoneName ? `https://portal.${zoneName}` : "";
  const authentikAdminUrl = zoneName ? `https://authentik.${zoneName}/if/admin/` : "";
  const authentikUserUrl = zoneName ? `https://authentik.${zoneName}/if/user/` : "";

  const settings = {
    issueUrl: trimString(content?.settings?.issueUrl) || "https://github.com/harrywesterman/Twinbox/issues/new/choose",
    authentikAdminUrl: interpolateTemplate(content?.settings?.authentikAdminUrl || "", zoneName, {
      portal_host: portalHost,
      authentik_admin_url: authentikAdminUrl,
      authentik_user_url: authentikUserUrl,
    }) || authentikAdminUrl,
    authentikUserUrl: interpolateTemplate(content?.settings?.authentikUserUrl || "", zoneName, {
      portal_host: portalHost,
      authentik_user_url: authentikUserUrl,
    }) || authentikUserUrl,
    authentikOtpUrl: interpolateTemplate(content?.settings?.authentikOtpUrl || "", zoneName, {
      portal_host: portalHost,
      authentik_user_url: authentikUserUrl,
    }) || authentikUserUrl,
    languages: [
      { value: "nl", label: "Nederlands" },
      { value: "en", label: "English" },
    ],
    timezones: [
      "Europe/Amsterdam",
      "Europe/London",
      "UTC",
      "America/New_York",
      "America/Los_Angeles",
    ],
  };

  const userAdmin = buildUserAdminConfig(content);

  const userApps = collectStepCards({
    steps,
    stepStateById,
    zoneName,
    portalHost,
    content,
    allowedCategoryIds: ["apps"],
  });

  const adminCards = collectStaticCards(
    Array.isArray(content?.adminLinks) ? content.adminLinks : [
      {
        title: "Dashy",
        label: "Open Admin tools",
        description: "Legacy admin launcher",
        url_template: "https://admin.__ZONE_NAME__",
        section: "Admin",
        icon: "install-dashy-dashboard",
      },
    ],
    { content, zoneName, portalHost, adminOnly: true },
  );

  const intranetLinks = collectStaticCards(Array.isArray(content?.links) ? content.links : [], {
    content,
    zoneName,
    portalHost,
    adminOnly: false,
  });

  const statusChecks = Array.isArray(content?.statusChecks)
    ? content.statusChecks.map((item) => ({
        title: trimString(item.title),
        description: trimString(item.description),
        url: interpolateTemplate(item.url, zoneName, {
          portal_host: portalHost,
          authentik_admin_url: authentikAdminUrl,
          authentik_user_url: authentikUserUrl,
        }),
        accent: trimString(item.accent) || pickPalette(item.title),
      })).filter((item) => item.title && item.url)
    : [];

  const groupedUserApps = userApps.reduce((acc, card) => {
    const section = "Apps";
    const list = acc.get(section) || [];
    list.push(card);
    acc.set(section, list);
    return acc;
  }, new Map());

  const groupedAdminApps = adminCards.reduce((acc, card) => {
    const section = card.section || "Admin";
    const list = acc.get(section) || [];
    list.push(card);
    acc.set(section, list);
    return acc;
  }, new Map());

  const hero = {
    eyebrow: trimString(content?.hero?.eyebrow) || "User portal",
    title: trimString(content?.hero?.title) || "Twinbox",
    description: trimString(content?.hero?.description) || "Open your apps, settings, and status from one place.",
  };

  return {
    portal: {
      brand: trimString(content?.brand) || "Twinbox",
      host: portalHost,
      zoneName,
      hero,
      generatedAt: new Date().toISOString(),
    },
    settings,
    userAdmin,
    apps: userApps.sort((left, right) => left.title.localeCompare(right.title)),
    appSections: [{
      name: "Apps",
      items: Array.from(groupedUserApps.get("Apps") || []).sort((left, right) => left.title.localeCompare(right.title)),
    }],
    adminApps: adminCards.sort((left, right) => left.title.localeCompare(right.title)),
    adminSections: Array.from(groupedAdminApps.entries()).map(([name, items]) => ({
      name,
      items: items.sort((left, right) => left.title.localeCompare(right.title)),
    })),
    intranetLinks: intranetLinks.sort((left, right) => left.title.localeCompare(right.title)),
    statusChecks,
  };
}

export function slugifyPortalCardId(title) {
  return slugify(title);
}
