import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { isIP } from "node:net";
import YAML from "yaml";
import { loadCatalogDefinitions } from "../../lib/catalog-definitions.mjs";
import { twinboxPublicZoneName } from "../../lib/cluster-public-zone.mjs";
import { isClusterScopedStep } from "../../lib/step-scope.mjs";
import {
  bootstrapRoot,
  globalSecretPath,
  readItemRecord,
  writeItemRecord,
  writeJsonFile,
} from "../../lib/secrets/filesystem-store.mjs";
import {
  buildGatusConfig,
  buildGatusEndpoints,
  gatusAlerting,
  gatusEndpoint,
} from "../../lib/gatus-config.mjs";

const read = (file, fallback = null) =>
  fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : fallback;
const quote = (text) => `'${text.replaceAll("'", "'\\''")}'`;

export function discoverManagementHealthUrl(cluster, secret, env = process.env, run = spawnSync) {
  const configured = secret.MANAGEMENT_HEALTH_URL || env.GATUS_MANAGEMENT_HEALTH_URL;
  if (configured) return configured;
  const status = run("docker", ["exec", "twinbox-netbird", "netbird", "status"], {
    encoding: "utf8",
    timeout: 10000,
  });
  const overlayIp = status.stdout?.match(/^NetBird IP:\s*([^/\s]+)/m)?.[1];
  const address =
    overlayIp || env.MANAGEMENT_VM_IP || cluster.management_ip || cluster.metadata?.management_ip;
  if (!isIP(address || "")) return "";
  return `http://${isIP(address) === 6 ? `[${address}]` : address}:8080/api/health`;
}

export function stateMap(dataRoot, steps, cluster) {
  const scope = cluster.cluster_instance_id || cluster.instance_id || cluster.id;
  return new Map(
    steps.map((step) => [
      step.id,
      read(
        path.join(
          dataRoot,
          "step-state",
          isClusterScopedStep(step) ? `clusters/${scope}` : "global",
          `${step.id}.json`
        )
      ),
    ])
  );
}

export function invokeBastion(secret, payload, workspace) {
  const host = secret.BASTION_SSH_HOST || secret.NETBIRD_IP;
  const user = secret.BASTION_SSH_USER || "root";
  const port = String(secret.BASTION_SSH_PORT || 22);
  if (
    !host ||
    !/^[a-zA-Z0-9.:[\]-]+$/.test(host) ||
    host.startsWith("-") ||
    !/^[a-zA-Z0-9_-]+$/.test(user) ||
    !/^\d+$/.test(port) ||
    !secret.SSH_PRIVATE_KEY
  )
    throw new Error("Incomplete bastion SSH credentials");
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gatus-ssh-"));
  try {
    const key = path.join(directory, "key");
    fs.writeFileSync(key, `${secret.SSH_PRIVATE_KEY.trimEnd()}\n`, { mode: 0o600 });
    const source = fs.readFileSync(
      path.join(workspace, "scripts/manager/gatus-bastion.py"),
      "utf8"
    );
    const result = spawnSync(
      "ssh",
      [
        "-i",
        key,
        "-p",
        port,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=10",
        `${user}@${host}`,
        `${user === "root" ? "" : "sudo -n "}python3 -c ${quote(source)}`,
      ],
      { input: JSON.stringify(payload), encoding: "utf8", timeout: 600000, maxBuffer: 1024 * 1024 }
    );
    if (result.status !== 0 || result.error)
      throw new Error(
        "Gatus bastion synchronisation failed (check SSH, Docker, DNS and configuration)"
      );
    return JSON.parse(result.stdout);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

export function reconcileGatus({
  workspace = process.env.WORKSPACE_ROOT || "/opt/twinbox",
  dataRoot = process.env.MANAGER_DATA_DIR || "/data",
  mode = "sync",
  targetId = "",
  inputs = {},
  remote = invokeBastion,
} = {}) {
  const { steps } = loadCatalogDefinitions({
    workspaceRoot: workspace,
    includeApps: true,
    loadYamlFn: (file) => YAML.parse(fs.readFileSync(file, "utf8")),
  });
  const clustersDir = path.join(dataRoot, "clusters");
  const clusters = fs.existsSync(clustersDir)
    ? fs
        .readdirSync(clustersDir)
        .filter((name) => name.endsWith(".json"))
        .map((name) => read(path.join(clustersDir, name)))
        .filter((cluster) => cluster?.id)
    : [];
  if (targetId && !clusters.some((cluster) => cluster.id === targetId))
    throw new Error("Gatus cluster not found");
  const cacheDir = path.join(dataRoot, "gatus");
  const groups = new Map();
  const version = fs
    .readFileSync(path.join(workspace, "config/pinned-defaults.sh"), "utf8")
    .match(/^PINNED_GATUS_VERSION=(\S+)$/m)?.[1];
  if (!version) throw new Error("Missing pinned Gatus version");
  for (const cluster of clusters) {
    const scope = cluster.cluster_instance_id || cluster.instance_id || cluster.id;
    const states = stateMap(dataRoot, steps, cluster);
    const cache = read(path.join(cacheDir, `${scope}.json`), {});
    const installing = mode === "install" && cluster.id === targetId;
    if (!installing && !cache.installed && states.get("install-gatus")?.status !== "succeeded")
      continue;
    const secret = read(globalSecretPath(process.env, `netbird-bastion-${cluster.id}`));
    if (!secret) throw new Error("Gatus requires an existing Twinbox bastion");
    const bastionId = secret.BASTION_PUBLIC_IPV4 || secret.BASTION_SSH_HOST || secret.NETBIRD_IP;
    if (!bastionId) throw new Error("Cannot identify Gatus bastion");
    const credentials =
      readItemRecord(
        process.env,
        { scope: "cluster", item: "gatus-notifications" },
        { clusterId: cluster.id }
      ) || {};
    const configuring = mode === "configure" && cluster.id === targetId && !inputs.test_only;
    const flags = configuring ? inputs : credentials.settings || {};
    const providers = gatusAlerting(flags, credentials);
    const zone = twinboxPublicZoneName(cluster.slug || cluster.id, cluster.dns_domain);
    const endpoints = buildGatusEndpoints({
      steps,
      states,
      cluster,
      previous: cache.endpoints || [],
      providers: Object.keys(providers),
    });
    // The public HTTPS ingress is also the baseline NetBird availability check.
    const netbirdUrl =
      states.get("provision-netbird-bastion")?.outputs?.netbird_url ||
      secret.NETBIRD_URL ||
      (secret.NETBIRD_FQDN ? `https://${secret.NETBIRD_FQDN}` : `https://netbird.${zone}`);
    endpoints.push(
      gatusEndpoint({
        identity: `${scope}/netbird`,
        title: "NetBird",
        group: `${cluster.id} / Basisdiensten`,
        url: netbirdUrl,
        providers: Object.keys(providers),
      })
    );
    // Discovery/explicit runtime configuration only; do not expose a new management port.
    const managementUrl = discoverManagementHealthUrl(cluster, secret);
    const warnings = managementUrl
      ? []
      : ["Management VM health URL not discovered; management coverage is incomplete"];
    if (managementUrl)
      endpoints.push(
        gatusEndpoint({
          identity: `${scope}/management`,
          title: "Management VM",
          group: `${cluster.id} / Basisdiensten`,
          url: managementUrl,
          monitoring: { status_codes: [200] },
          providers: Object.keys(providers),
        })
      );
    if (flags.ntfy_enabled && new URL(credentials.ntfy_url).hostname === `ntfy.${zone}`)
      warnings.push("ntfy runs in this cluster: notifications may fail during cluster outages");
    const member = {
      cluster,
      scope,
      endpoints,
      providers,
      warnings,
      credentials,
      configuring,
      flags,
    };
    if (!groups.has(bastionId)) groups.set(bastionId, { secret, members: [] });
    groups.get(bastionId).members.push(member);
  }
  if (
    targetId &&
    ![...groups.values()].some((group) =>
      group.members.some((member) => member.cluster.id === targetId)
    )
  )
    throw new Error("Install Gatus before configuring notifications");
  const results = [];
  for (const { secret, members } of groups.values()) {
    if (targetId && !members.some((member) => member.cluster.id === targetId)) continue;
    const alerting = {};
    for (const member of members)
      for (const [provider, config] of Object.entries(member.providers)) {
        if (!alerting[provider]) alerting[provider] = { ...config, overrides: [] };
        for (const group of new Set(member.endpoints.map((endpoint) => endpoint.group)))
          alerting[provider].overrides.push({ group, ...config });
      }
    const endpoints = members.flatMap((member) => member.endpoints);
    const target = members.find((member) => member.cluster.id === targetId);
    const testing = mode === "configure" && inputs.test_only;
    const payload = {
      public_address: secret.BASTION_PUBLIC_IPV4 || "",
      image: `ghcr.io/twin/gatus:${version}`,
      hosts: members.map(
        (member) =>
          `status.${twinboxPublicZoneName(member.cluster.slug || member.cluster.id, member.cluster.dns_domain)}`
      ),
      config: buildGatusConfig(endpoints, alerting),
      ...(testing ? { test_provider: inputs.test_provider, test_alerting: target.providers } : {}),
    };
    try {
      const result = remote(secret, payload, workspace);
      if (testing) {
        const safe =
          read(path.join(dataRoot, "step-state/clusters", target.scope, "install-gatus.json"))
            ?.outputs || {};
        results.push({ ...safe, test: result });
        continue;
      }
      for (const member of members) {
        if (
          member.endpoints.some((endpoint) => result.coverage_warnings?.includes(endpoint.group))
        ) {
          member.warnings.push(
            "Management VM health endpoint is not reachable from the bastion; check existing network access"
          );
        }
        const status = {
          installed: true,
          endpoints: member.endpoints,
          last_success_at: new Date().toISOString(),
          warnings: member.warnings,
          error: null,
        };
        writeJsonFile(path.join(cacheDir, `${member.scope}.json`), status);
        if (member.configuring)
          writeItemRecord(
            process.env,
            { scope: "cluster", item: "gatus-notifications" },
            {
              ...member.credentials,
              settings: Object.fromEntries(
                ["telegram_enabled", "ntfy_enabled", "pushover_enabled"].map((key) => [
                  key,
                  !!member.flags[key],
                ])
              ),
            },
            { clusterId: member.cluster.id }
          );
        const safe = {
          status_url: `https://status.${twinboxPublicZoneName(member.cluster.slug || member.cluster.id, member.cluster.dns_domain)}`,
          monitor_count: member.endpoints.length,
          last_success_at: status.last_success_at,
          warnings: member.warnings,
          configured_channels: Object.keys(member.providers),
          credentials_set: Object.keys(member.credentials).filter(
            (key) => key !== "settings" && !!member.credentials[key]
          ),
        };
        const stateFile = path.join(
          dataRoot,
          "step-state/clusters",
          member.scope,
          "install-gatus.json"
        );
        const state = read(stateFile);
        if (state) writeJsonFile(stateFile, { ...state, outputs: safe });
        results.push(safe);
      }
    } catch (error) {
      // A failed channel test says nothing about monitor synchronisation.
      if (testing) throw error;
      for (const member of members) {
        const file = path.join(cacheDir, `${member.scope}.json`);
        writeJsonFile(file, {
          ...read(file, {}),
          error: "Bastion synchronisation failed",
          last_attempt_at: new Date().toISOString(),
        });
        const stateFile = path.join(
          dataRoot,
          "step-state/clusters",
          member.scope,
          "install-gatus.json"
        );
        const state = read(stateFile);
        if (state)
          writeJsonFile(stateFile, {
            ...state,
            outputs: {
              ...state.outputs,
              sync_warning: "Bastion synchronisation failed; retry within five minutes",
            },
          });
      }
      throw error;
    }
  }
  return results;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const mode = process.argv[2] || "sync";
    const context = JSON.parse(process.env.STEP_CONTEXT_JSON || "{}");
    const inputs = JSON.parse(process.env.STEP_INPUTS_JSON || "{}");
    const results = reconcileGatus({
      mode,
      targetId: context.cluster?.id || process.env.TWINBOX_CLUSTER_ID || "",
      inputs,
    });
    if (process.env.STEP_RESULT_FILE)
      writeJsonFile(
        process.env.STEP_RESULT_FILE,
        results.find((result) => result.test) ||
          results.find(
            (result) =>
              result.status_url ===
              `https://status.${twinboxPublicZoneName(context.cluster?.slug || context.cluster?.id, context.cluster?.dns_domain)}`
          ) ||
          {}
      );
    console.log("Gatus synchronisation completed");
  } catch {
    console.error(
      `Gatus operation failed; verify bastion prerequisites and notification settings under ${bootstrapRoot()}`
    );
    process.exitCode = 1;
  }
}
