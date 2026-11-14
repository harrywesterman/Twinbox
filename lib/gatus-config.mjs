import { createHash } from "node:crypto";
import { twinboxPublicZoneName } from "./cluster-public-zone.mjs";

export const GATUS_PROVIDERS = ["telegram", "ntfy", "pushover"];
const credentialFields = {
  telegram: ["telegram_token", "telegram_chat_id"],
  ntfy: ["ntfy_url", "ntfy_topic"],
  pushover: ["pushover_token", "pushover_user_key"],
};

export function mergeGatusCredentials(previous = {}, values = {}) {
  return Object.fromEntries(
    Object.entries({
      ...previous,
      ...Object.fromEntries(
        Object.entries(values).filter(([, value]) => String(value ?? "").trim())
      ),
    }).map(([key, value]) => [key, String(value).trim()])
  );
}

export function validateGatusNotifications(inputs, credentials) {
  for (const provider of GATUS_PROVIDERS) {
    if (!inputs[`${provider}_enabled`]) continue;
    for (const field of credentialFields[provider]) {
      if (!credentials[field]) throw new Error(`${provider}: ${field} is required`);
    }
  }
  if (inputs.ntfy_enabled) {
    const url = new URL(credentials.ntfy_url);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
      throw new Error("ntfy requires an HTTPS server URL without credentials or query parameters");
    }
    if (!/^[A-Za-z0-9_-]+$/.test(credentials.ntfy_topic)) throw new Error("Invalid ntfy topic");
    if (credentials.ntfy_token && !credentials.ntfy_token.startsWith("tk_"))
      throw new Error("Invalid ntfy token");
  }
  if (
    inputs.pushover_enabled &&
    [credentials.pushover_token, credentials.pushover_user_key].some((value) => value.length !== 30)
  ) {
    throw new Error("Pushover keys must contain 30 characters");
  }
}

export function gatusAlerting(inputs = {}, credentials = {}) {
  validateGatusNotifications(inputs, credentials);
  const alerting = {};
  if (inputs.telegram_enabled)
    alerting.telegram = { token: credentials.telegram_token, id: credentials.telegram_chat_id };
  if (inputs.ntfy_enabled)
    alerting.ntfy = {
      url: credentials.ntfy_url,
      topic: credentials.ntfy_topic,
      ...(credentials.ntfy_token ? { token: credentials.ntfy_token } : {}),
    };
  if (inputs.pushover_enabled)
    alerting.pushover = {
      "application-token": credentials.pushover_token,
      "user-key": credentials.pushover_user_key,
    };
  return alerting;
}

export function gatusEndpoint({ identity, title, group, url, monitoring = {}, providers = [] }) {
  const id = createHash("sha256").update(identity).digest("hex").slice(0, 12);
  const target = new URL(url);
  if (monitoring.path) {
    if (!monitoring.path.startsWith("/") || monitoring.path.startsWith("//"))
      throw new Error("Invalid monitoring path");
    target.pathname = monitoring.path;
    target.search = "";
    target.hash = "";
  }
  const codes = monitoring.status_codes || [200, 301, 302, 303, 307, 308];
  return {
    name: `${title} · ${id}`,
    group,
    url: target.href,
    interval: "60s",
    client: { timeout: "10s", "ignore-redirect": true },
    ui: {
      "hide-hostname": true,
      "hide-url": true,
      "hide-port": true,
      "hide-errors": true,
      "hide-conditions": true,
    },
    conditions: [
      codes.length === 1 ? `[STATUS] == ${codes[0]}` : `[STATUS] == any(${codes.join(", ")})`,
      ...(monitoring.body_contains ? [`[BODY] == pat(*${monitoring.body_contains}*)`] : []),
    ],
    alerts: providers.map((type) => ({
      type,
      "failure-threshold": 3,
      "success-threshold": 2,
      "send-on-resolved": true,
      "minimum-reminder-interval": "60m",
    })),
  };
}

// Previous endpoints survive temporary pending/running/failed states. An explicit
// not_started state (successful uninstall) or a removed catalog item deletes them.
export function buildGatusEndpoints({ steps, states, cluster, previous = [], providers = [] }) {
  const zone = twinboxPublicZoneName(cluster.slug || cluster.id, cluster.dns_domain);
  if (!zone) throw new Error("Public zone is required for Gatus");
  const scope = cluster.cluster_instance_id || cluster.instance_id || cluster.id;
  const endpoints = [];
  const seen = new Set();
  for (const step of steps) {
    const state = states.get(step.id);
    if (!state) continue;
    for (const [index, item] of (step.dashy?.items || []).entries()) {
      if (["install-gatus", "provision-netbird-bastion"].includes(step.id)) continue;
      const identity = `${scope}/${step.id}/${item.id || index}`;
      const id = createHash("sha256").update(identity).digest("hex").slice(0, 12);
      const old = previous.find((endpoint) => endpoint.name.endsWith(` · ${id}`));
      if (!["succeeded", "configured"].includes(state.status)) {
        if (state.status !== "not_started" && old && !seen.has(old.url)) {
          endpoints.push({
            ...old,
            alerts: gatusEndpoint({
              identity,
              title: item.title,
              group: old.group,
              url: old.url,
              providers,
            }).alerts,
          });
          seen.add(old.url);
        }
        continue;
      }
      const raw = item.url_template
        ? item.url_template.replaceAll("__ZONE_NAME__", zone)
        : String(item.output_url_key || "")
            .split(".")
            .reduce((value, key) => value?.[key], state.outputs);
      if (!raw || /__[A-Z_]+__/.test(raw)) continue;
      let target;
      try {
        target = new URL(raw);
      } catch {
        continue;
      }
      if (
        !["https:", "http:"].includes(target.protocol) ||
        target.username ||
        target.password ||
        target.hostname === `status.${zone}`
      )
        continue;
      target.hash = "";
      const endpoint = gatusEndpoint({
        identity,
        title: item.title,
        group: `${cluster.id} / ${item.section}`,
        url: target.href,
        monitoring: item.monitoring,
        providers,
      });
      if (seen.has(endpoint.url)) continue;
      seen.add(endpoint.url);
      endpoints.push(endpoint);
    }
  }
  return endpoints.sort((a, b) => a.name.localeCompare(b.name));
}

export function buildGatusConfig(endpoints, alerting = {}) {
  return {
    storage: {
      type: "sqlite",
      path: "/data/gatus.db",
      "maximum-number-of-results": 1440,
      "maximum-number-of-events": 100,
    },
    ui: {
      title: "Twinbox Status",
      header: "Twinbox Status",
      "dashboard-heading": "Beschikbaarheid van Twinbox",
      "dashboard-subheading":
        "Ingangscontroles achter een login controleren alleen de bereikbaarheid.",
      description:
        "Beschikbaarheid van Twinbox-diensten. Ingangscontroles achter een login controleren alleen de bereikbaarheid.",
      "default-sort-by": "group",
    },
    "skip-invalid-config-update": true,
    metrics: false,
    alerting,
    endpoints,
  };
}
