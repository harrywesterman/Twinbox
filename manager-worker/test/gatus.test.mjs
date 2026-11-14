import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import YAML from "yaml";
import { loadCatalogDefinitions } from "../../lib/catalog-definitions.mjs";
import {
  buildGatusConfig,
  buildGatusEndpoints,
  gatusAlerting,
  mergeGatusCredentials,
  validateGatusNotifications,
} from "../../lib/gatus-config.mjs";
import { normalizeMonitoring } from "../../lib/step-manifest.mjs";
import { reconcileGatus } from "../src/gatus-sync.mjs";

const cluster = { id: "prd", dns_domain: "example.test", cluster_instance_id: "instance-a" };
const steps = [
  {
    id: "app",
    dashy: {
      items: [{ title: "Example", section: "Apps", url_template: "https://app.__ZONE_NAME__" }],
    },
  },
];
const generate = (status, extra = {}) =>
  buildGatusEndpoints({ cluster, steps, states: new Map([["app", { status }]]), ...extra });

test("Gatus uses public zone, private results, thresholds and stable identities", () => {
  const [endpoint] = generate("succeeded", { providers: ["telegram"] });
  assert.equal(endpoint.url, "https://app.example.test/");
  assert.equal(endpoint.client["ignore-redirect"], true);
  assert.equal(endpoint.conditions[0], "[STATUS] == any(200, 301, 302, 303, 307, 308)");
  assert.equal(endpoint.group, "prd / Apps");
  assert.equal(endpoint.ui["hide-errors"], true);
  assert.equal(endpoint.ui["hide-hostname"], true);
  assert.equal(endpoint.ui["hide-url"], true);
  assert.equal(endpoint.ui["hide-conditions"], true);
  assert.equal(endpoint.alerts[0]["failure-threshold"], 3);
  assert.equal(endpoint.alerts[0]["success-threshold"], 2);
  assert.equal(endpoint.alerts[0]["minimum-reminder-interval"], "60m");
  assert.equal(generate("configured")[0].name, endpoint.name);
  assert.notEqual(
    generate("succeeded", { cluster: { ...cluster, cluster_instance_id: "instance-b" } })[0].name,
    endpoint.name
  );
});

test("failed and pending upgrades retain monitors, explicit uninstall removes them", () => {
  const previous = generate("succeeded");
  for (const status of ["pending", "running", "failed", "canceled"])
    assert.equal(generate(status, { previous }).length, 1);
  assert.equal(generate("not_started", { previous }).length, 0);
  assert.equal(generate("failed").length, 0);
  assert.equal(generate("succeeded", { steps: [], previous }).length, 0);
});

test("URLs deduplicate, unresolved templates and status self-checks are excluded", () => {
  const item = steps[0].dashy.items[0];
  const variants = [
    item,
    item,
    { ...item, url_template: "https://__UNKNOWN__" },
    { ...item, url_template: "https://status.__ZONE_NAME__" },
  ];
  assert.equal(
    generate("succeeded", { steps: [{ id: "app", dashy: { items: variants } }] }).length,
    1
  );
  const changed = generate("succeeded", {
    cluster: { ...cluster, dns_domain: "new.example.test" },
  });

  assert.equal(changed[0].url, "https://app.new.example.test/");
});

test("explicit health conditions replace login reachability checks", () => {
  const metadata = { path: "/health", status_codes: [200], body_contains: "healthy" };
  const [endpoint] = generate("succeeded", {
    steps: [
      { id: "app", dashy: { items: [{ ...steps[0].dashy.items[0], monitoring: metadata }] } },
    ],
  });
  assert.equal(endpoint.url, "https://app.example.test/health");
  assert.deepEqual(endpoint.conditions, ["[STATUS] == 200", "[BODY] == pat(*healthy*)"]);
  assert.deepEqual(normalizeMonitoring(metadata, "fixture"), metadata);
  assert.throws(() => normalizeMonitoring({ path: "//other.test" }, "fixture"));
  assert.throws(() => normalizeMonitoring({ status_codes: [999] }, "fixture"));
  assert.throws(() => normalizeMonitoring({ body_contains: "x) || true" }, "fixture"));
});

test("monitoring opt-out removes cached internal monitors without removing their catalog links", () => {
  const previous = generate("succeeded");
  const item = { ...steps[0].dashy.items[0], monitoring: { enabled: false } };
  const internal = [{ id: "app", dashy: { items: [item] } }];
  for (const status of ["succeeded", "configured", "pending", "failed"]) {
    assert.deepEqual(generate(status, { steps: internal, previous }), []);
  }
  assert.equal(internal[0].dashy.items[0].url_template, steps[0].dashy.items[0].url_template);
  assert.deepEqual(normalizeMonitoring({ enabled: false }, "fixture"), { enabled: false });
  assert.throws(() => normalizeMonitoring({ enabled: "false" }, "fixture"));
});

test("Apps catalog classification wins over legacy Platform sections, including cached monitors", () => {
  const platform = {
    ...steps[0],
    category_id: "talos-cluster",
    dashy: { items: [{ ...steps[0].dashy.items[0], section: "Platform" }] },
  };
  const app = { ...platform, category_id: "apps" };
  const previous = generate("succeeded", { steps: [platform] });
  for (const status of ["succeeded", "pending", "failed"]) {
    const endpoints = generate(status, { steps: [platform, app], previous });
    assert.equal(endpoints.length, 1);
    assert.equal(endpoints[0].group, "prd / Apps");
  }
});

test("real user-facing apps are all included in Apps, while infrastructure remains Platform", () => {
  const catalog = loadCatalogDefinitions({
    workspaceRoot: path.resolve(import.meta.dirname, "../.."),
    includeApps: true,
    loadYamlFn: (file) => YAML.parse(fs.readFileSync(file, "utf8")),
  });
  const ids = [
    "install-copyparty",
    "install-immich",
    "install-nextcloud",
    "install-stirling-pdf",
    "install-matrix",
    "install-jitsi",
    "install-mailu",
    "install-outline",
    "install-authentik-idp",
  ];
  const selected = ids.map((id) => {
    const step = catalog.stepsById.get(id);
    assert.ok(step, id);
    return step;
  });
  const states = new Map(ids.map((id) => [id, { status: "succeeded" }]));
  const endpoints = buildGatusEndpoints({ steps: selected, states, cluster });
  for (const title of [
    "copyparty",
    "Immich",
    "Nextcloud",
    "Stirling PDF",
    "Element",
    "Jitsi",
    "Mailu",
    "Outline",
  ]) {
    const endpoint = endpoints.find((entry) => entry.name.startsWith(`${title} · `));
    assert.ok(endpoint, title);
    assert.equal(endpoint.group, "prd / Apps", title);
  }
  assert.equal(
    endpoints.find((endpoint) => endpoint.name.startsWith("Authentik · ")).group,
    "prd / Platform"
  );
});

test("notification credentials retain blank fields and disabled providers do not alert", () => {
  assert.deepEqual(
    mergeGatusCredentials(
      { telegram_token: "saved" },
      { telegram_token: "", ntfy_token: "tk_new" }
    ),
    { telegram_token: "saved", ntfy_token: "tk_new" }
  );
  assert.throws(() => validateGatusNotifications({ telegram_enabled: true }, {}));
  assert.deepEqual(gatusAlerting({}, { telegram_token: "saved" }), {});
  const alerting = gatusAlerting(
    { telegram_enabled: true, ntfy_enabled: true, pushover_enabled: true },
    {
      telegram_token: "secret",
      telegram_chat_id: "chat",
      ntfy_url: "https://push.example.test",
      ntfy_topic: "alerts",
      pushover_token: "a".repeat(30),
      pushover_user_key: "b".repeat(30),
    }
  );
  assert.deepEqual(Object.keys(alerting), ["telegram", "ntfy", "pushover"]);
  assert.throws(() =>
    gatusAlerting(
      { ntfy_enabled: true },
      { ntfy_url: "http://push.example.test", ntfy_topic: "alerts" }
    )
  );
  assert.equal(buildGatusConfig([], alerting).storage.type, "sqlite");
});

test("shared bastions reconcile all clusters, preserve monitors on failed deployment, and publish only safe outputs", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gatus-test-"));
  const previousRoot = process.env.TWINBOX_BOOTSTRAP_DIR;
  process.env.TWINBOX_BOOTSTRAP_DIR = path.join(directory, "bootstrap");
  const write = (file, value) => {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(value));
  };
  try {
    for (const id of ["prd", "dev"]) {
      write(path.join(directory, "clusters", `${id}.json`), {
        ...cluster,
        id,
        cluster_instance_id: id,
      });
      write(path.join(directory, "step-state/clusters", id, "install-gatus.json"), {
        status: "succeeded",
      });
      write(path.join(directory, "step-state/clusters", id, "install-authentik-idp.json"), {
        status: "succeeded",
      });
      write(path.join(directory, "step-state/clusters", id, "configure-backup-storage.json"), {
        status: "configured",
        outputs: { seaweedfs_backup_admin_url: "https://backup.internal.example.test/" },
      });
      write(
        path.join(
          process.env.TWINBOX_BOOTSTRAP_DIR,
          "secrets/global",
          `netbird-bastion-${id}.json`
        ),
        {
          BASTION_SSH_HOST: "bastion.example.test",
          SSH_PRIVATE_KEY: "do-not-print",
          MANAGEMENT_HEALTH_URL: "https://management.example.test/api/health",
        }
      );
      write(path.join(directory, "gatus", `${id}.json`), {
        installed: true,
        endpoints: [
          {
            name: "Management VM · legacy",
            group: `${id} / Basisdiensten`,
            url: "https://management.example.test/api/health",
          },
        ],
      });
    }
    const captured = [];
    const options = {
      dataRoot: directory,
      workspace: path.resolve(import.meta.dirname, "../.."),
      targetId: "prd",
      remote: (_secret, payload) => {
        captured.push(payload);
        return { changed: true };
      },
    };
    const results = reconcileGatus(options);
    assert.equal(captured.length, 1);
    assert.equal(captured[0].hosts.length, 2);
    assert.ok(captured[0].config.endpoints.length >= 2);
    assert.equal(
      captured[0].config.endpoints.some((endpoint) => endpoint.name.startsWith("Management VM · ")),
      false
    );
    assert.equal(
      captured[0].config.endpoints.some((endpoint) =>
        endpoint.name.startsWith("SeaweedFS Backup VM · ")
      ),
      false
    );
    const netbird = captured[0].config.endpoints.filter((endpoint) =>
      endpoint.name.startsWith("NetBird · ")
    );
    assert.equal(netbird.length, 2);
    assert.deepEqual(netbird.map((endpoint) => endpoint.group).sort(), [
      "dev / Platform",
      "prd / Platform",
    ]);
    assert.equal(
      captured[0].config.endpoints.some((endpoint) => endpoint.group.includes("Basisdiensten")),
      false
    );
    assert.equal(JSON.stringify(results).includes("do-not-print"), false);
    assert.deepEqual(results[0].warnings, []);
    assert.throws(() =>
      reconcileGatus({
        ...options,
        remote: () => {
          throw new Error("offline");
        },
      })
    );
    const cache = JSON.parse(fs.readFileSync(path.join(directory, "gatus/prd.json")));
    assert.ok(cache.endpoints.length);
    assert.ok(cache.last_success_at);
    assert.equal(cache.error, "Bastion synchronisation failed");
    const beforeTest = fs.readFileSync(path.join(directory, "gatus/prd.json"), "utf8");
    assert.throws(() =>
      reconcileGatus({
        ...options,
        mode: "configure",
        inputs: { test_only: true, test_provider: "telegram" },
        remote: () => {
          throw new Error("notification rejected");
        },
      })
    );
    assert.equal(fs.readFileSync(path.join(directory, "gatus/prd.json"), "utf8"), beforeTest);
    assert.ok(
      JSON.parse(
        fs.readFileSync(path.join(directory, "step-state/clusters/prd/install-gatus.json"))
      ).outputs.sync_warning
    );
  } finally {
    if (previousRoot === undefined) delete process.env.TWINBOX_BOOTSTRAP_DIR;
    else process.env.TWINBOX_BOOTSTRAP_DIR = previousRoot;
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
