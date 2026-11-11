import assert from "node:assert/strict";
import test from "node:test";
import { syncNetbirdClientGroups } from "../src/netbird-client-sync.mjs";

const network = {
  NETBIRD_MANAGEMENT_URL: "https://netbird.example.test/api/",
  ADGUARD_DNS_GROUP_ID: "dns",
  EXIT_NODE_USERS_GROUP_ID: "exits",
};

test("human devices inherit DNS and exits without changing roles or infrastructure", async () => {
  const writes = [];
  const users = [
    { id: "human|1", role: "user", auto_groups: ["custom"], is_blocked: false },
    { id: "service", role: "admin", is_service_user: true },
    { id: "blocked", role: "user", is_blocked: true },
    { id: "pending", role: "user", pending_approval: true },
    { id: "configured", role: "owner", auto_groups: ["dns", "exits"] },
  ];
  const fetchImpl = async (url, options) => {
    assert.ok(url.startsWith("https://netbird.example.test/api/"));
    if (options.method === "PUT") {
      writes.push([url.split("/api/")[1], JSON.parse(options.body)]);
      return { ok: true, json: async () => ({}) };
    }
    return {
      ok: true,
      json: async () =>
        url.endsWith("/accounts")
          ? [
              {
                id: "account",
                settings: {
                  groups_propagation_enabled: false,
                  extra: { peer_approval_enabled: true },
                },
              },
            ]
          : users,
    };
  };
  await syncNetbirdClientGroups(network, { NETBIRD_ADMIN_TOKEN: "test-token" }, fetchImpl);
  assert.deepEqual(writes, [
    [
      "accounts/account",
      { settings: { groups_propagation_enabled: true, extra: { peer_approval_enabled: true } } },
    ],
    [
      "users/human%7C1",
      { role: "user", is_blocked: false, auto_groups: ["custom", "dns", "exits"] },
    ],
  ]);
});

test("already configured users produce no writes, including a newly enrolled device owner", async () => {
  await syncNetbirdClientGroups(
    network,
    { NETBIRD_ADMIN_TOKEN: "test-token" },
    async (url, options) => {
      assert.equal(options.method, "GET");
      return {
        ok: true,
        json: async () =>
          url.endsWith("/accounts")
            ? [{ settings: { groups_propagation_enabled: true } }]
            : [{ auto_groups: ["dns", "exits"] }],
      };
    }
  );
});

test("incomplete installation makes no API calls and API failures do not expose tokens", async () => {
  await syncNetbirdClientGroups(network, {}, () => assert.fail("unexpected request"));
  await assert.rejects(
    syncNetbirdClientGroups(network, { NETBIRD_ADMIN_TOKEN: "private-token" }, async () => ({
      ok: false,
      status: 403,
    })),
    { message: "NetBird client sync accounts: HTTP 403" }
  );
});
