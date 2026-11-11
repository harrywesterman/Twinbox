import fs from "node:fs";
import path from "node:path";
import { secretRoot } from "../../lib/secrets/filesystem-store.mjs";

// User auto-groups cover future enrollments; propagation also updates existing devices.
// Setup-key infrastructure peers have no human owner and are deliberately excluded.
export async function syncNetbirdClientGroups(network, bastion, fetchImpl = fetch) {
  const groups = [network.ADGUARD_DNS_GROUP_ID, network.EXIT_NODE_USERS_GROUP_ID];
  const token = bastion.NETBIRD_ADMIN_TOKEN || bastion.NETBIRD_API_TOKEN;
  if (!network.NETBIRD_MANAGEMENT_URL || !token || groups.some((group) => !group)) return;
  const base = network.NETBIRD_MANAGEMENT_URL.replace(/\/+$/, "").replace(/\/api$/, "");
  async function request(endpoint, body) {
    const response = await fetchImpl(`${base}/api/${endpoint}`, {
      method: body ? "PUT" : "GET",
      headers: { Authorization: `Token ${token}`, "Content-Type": "application/json" },
      signal: AbortSignal.timeout(15000),
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    // Do not log response bodies: upstream errors may contain credentials.
    if (!response.ok) throw new Error(`NetBird client sync ${endpoint}: HTTP ${response.status}`);
    return response.json();
  }
  const accounts = await request("accounts");
  for (const account of accounts) {
    if (!account.settings.groups_propagation_enabled) {
      await request(`accounts/${encodeURIComponent(account.id)}`, {
        settings: { ...account.settings, groups_propagation_enabled: true },
      });
    }
  }
  const users = await request("users");
  for (const user of users) {
    if (user.is_service_user || user.is_blocked || user.pending_approval) continue;
    const existing = user.auto_groups || [];
    if (groups.every((group) => existing.includes(group))) continue;
    await request(`users/${encodeURIComponent(user.id)}`, {
      role: user.role,
      is_blocked: user.is_blocked ?? false,
      auto_groups: [...new Set([...existing, ...groups])],
    });
  }
}

export function startNetbirdClientSync({ runtimeEnv = process.env, onError = console.error } = {}) {
  const directory = path.join(secretRoot(runtimeEnv), "global");
  async function tick() {
    try {
      const files = fs.existsSync(directory) ? fs.readdirSync(directory) : [];
      for (const file of files.filter((name) => /^netbird-network-.+\.json$/.test(name))) {
        try {
          const cluster = file.slice("netbird-network-".length, -".json".length);
          const bastionFile = path.join(directory, `netbird-bastion-${cluster}.json`);
          if (!fs.existsSync(bastionFile)) continue;
          await syncNetbirdClientGroups(
            JSON.parse(fs.readFileSync(path.join(directory, file), "utf8")),
            JSON.parse(fs.readFileSync(bastionFile, "utf8"))
          );
        } catch {
          onError(`NetBird client sync failed for ${file}; retrying in 30 seconds`);
        }
      }
    } catch {
      onError("NetBird client sync could not read configuration; retrying in 30 seconds");
    } finally {
      setTimeout(tick, 30000).unref();
    }
  }
  void tick();
}
