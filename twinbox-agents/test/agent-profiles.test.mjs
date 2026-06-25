import test from "node:test";
import assert from "node:assert/strict";
import { AGENT_PROFILES, getAgentProfile, listAgentProfiles } from "../src/agent-profiles.mjs";
import { VALID_TYPES } from "../src/work-orders.mjs";

test("agent-profiles exports AGENT_PROFILES array", () => {
  assert.ok(Array.isArray(AGENT_PROFILES));
  assert.equal(AGENT_PROFILES.length, 7);
});

test("agent-profiles contains exactly 7 expected IDs", () => {
  const ids = AGENT_PROFILES.map((a) => a.id).sort();
  assert.deepEqual(ids, [
    "betty-backup",
    "gina-gitops",
    "karel-kubernetes",
    "olivia-ops",
    "peter-proxmox",
    "sofia-sql",
    "tara-talos",
  ]);
});

test("getAgentProfile returns correct profile", () => {
  const olivia = getAgentProfile("olivia-ops");
  assert.ok(olivia);
  assert.equal(olivia.displayName, "Olivia Ops");
  assert.equal(olivia.public, true);
});

test("getAgentProfile returns null for unknown id", () => {
  assert.equal(getAgentProfile("unknown"), null);
});

test("listAgentProfiles returns all profiles", () => {
  const all = listAgentProfiles();
  assert.equal(all.length, 7);
});

test("each profile has required fields", () => {
  for (const profile of AGENT_PROFILES) {
    assert.ok(profile.id, `missing id in ${profile.id}`);
    assert.ok(profile.displayName, `missing displayName in ${profile.id}`);
    assert.ok(profile.role, `missing role in ${profile.id}`);
    assert.equal(typeof profile.public, "boolean", `public should be boolean in ${profile.id}`);
    assert.ok(profile.summary, `missing summary in ${profile.id}`);
    assert.ok(profile.avatar, `missing avatar in ${profile.id}`);
    assert.equal(profile.avatar.kind, "pixel");
    assert.ok(profile.avatar.palette);
    assert.ok(profile.avatar.initials);
    assert.ok(profile.systemPrompt, `missing systemPrompt in ${profile.id}`);
    assert.ok(Array.isArray(profile.allowedWorkOrderTypes));
  }
});

test("only olivia-ops is public", () => {
  const publicProfiles = AGENT_PROFILES.filter((a) => a.public);
  assert.equal(publicProfiles.length, 1);
  assert.equal(publicProfiles[0].id, "olivia-ops");
});

test("olivia-ops has all work order types", () => {
  const olivia = getAgentProfile("olivia-ops");
  assert.ok(olivia.allowedWorkOrderTypes.includes("cluster_health_check"));
  assert.ok(olivia.allowedWorkOrderTypes.includes("backup_health_check"));
  assert.ok(olivia.allowedWorkOrderTypes.includes("proxmox_health_check"));
  assert.ok(olivia.allowedWorkOrderTypes.includes("database_health_check"));
  assert.ok(olivia.allowedWorkOrderTypes.includes("gitops_health_check"));
});

test("profiles only advertise executable work order types", () => {
  for (const profile of AGENT_PROFILES) {
    for (const type of profile.allowedWorkOrderTypes) {
      assert.ok(VALID_TYPES.includes(type), `${profile.id} advertises unsupported ${type}`);
    }
  }
});

test("system prompts follow rules", () => {
  for (const profile of AGENT_PROFILES) {
    const prompt = profile.systemPrompt;
    assert.ok(prompt.length > 50, `${profile.id} prompt should be substantial`);
  }
});
