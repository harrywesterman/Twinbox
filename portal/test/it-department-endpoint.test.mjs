import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-it-department-test-"));
const configPath = path.join(workspaceRoot, "portal-config.json");
const dataDir = path.join(workspaceRoot, "data");
const sessionSecret = "it-department-test-secret";
const agentToken = "it-department-agent-token";
const agentRequests = [];

let portalServer;
let portalOrigin = "";
let agentServerOrigin = "";
let failAgentRequests = false;

function sendJson(res, status, payload) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(payload));
}

function createSignedSessionCookie(session) {
  const body = Buffer.from(JSON.stringify(session)).toString("base64url");
  const signature = crypto.createHmac("sha256", sessionSecret).update(body).digest("base64url");
  return `twinbox_portal_session=${encodeURIComponent(`${body}.${signature}`)}`;
}

async function startServer(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

async function requestPortal(pathname, { cookie } = {}) {
  const response = await fetch(`${portalOrigin}${pathname}`, {
    headers: cookie ? { cookie } : {},
  });
  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }
  return { status: response.status, payload };
}

const agentServer = http.createServer((req, res) => {
  const url = new URL(req.url || "/", "http://127.0.0.1");
  agentRequests.push({
    method: req.method,
    pathname: url.pathname,
    authorization: req.headers.authorization,
  });

  if (req.headers.authorization !== `Bearer ${agentToken}`) {
    sendJson(res, 403, { error: "invalid token" });
    return;
  }

  if (failAgentRequests) {
    sendJson(res, 503, { error: "agent service unavailable" });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/agents") {
    sendJson(res, 200, [
      {
        id: "karel-kubernetes",
        displayName: "Karel Kubernetes",
        role: "Kubernetes Specialist",
        avatar: { initials: "KK" },
        systemPrompt: "sensitive prompt",
      },
    ]);
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/events") {
    sendJson(res, 200, [
      {
        id: "event-1",
        agentId: "karel-kubernetes",
        workOrderId: "wo-1",
        severity: "info",
        title: "Sensitive event title",
        message: "Sensitive event message",
        metadata: { token: "secret" },
        timestamp: "2026-06-26T10:02:00.000Z",
      },
    ]);
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/work-orders") {
    sendJson(res, 200, [
      {
        id: "wo-1",
        type: "cluster_health_check",
        title: "Sensitive work-order title",
        status: "investigating",
        assignedAgents: ["karel-kubernetes"],
        scope: { cluster: "secret" },
        result: { llmSummary: "sensitive summary" },
        evidence: ["sensitive evidence"],
        updatedAt: "2026-06-26T10:01:00.000Z",
      },
    ]);
    return;
  }

  sendJson(res, 404, { error: "not found" });
});

test.before(async () => {
  fs.writeFileSync(configPath, JSON.stringify({ apps: [], adminApps: [] }), "utf8");
  agentServerOrigin = await startServer(agentServer);

  process.env.NODE_ENV = "test";
  process.env.PORTAL_CONFIG_PATH = configPath;
  process.env.PORTAL_DATA_DIR = dataDir;
  process.env.PORTAL_SESSION_SECRET = sessionSecret;
  process.env.PORTAL_AGENTS_BASE_URL = agentServerOrigin;
  process.env.TWINBOX_AGENT_INTERNAL_TOKEN = agentToken;

  const moduleUrl = `${pathToFileURL(path.join(repoRoot, "portal", "server.mjs")).href}?itDepartment=${Date.now()}`;
  const { app } = await import(moduleUrl);
  portalServer = http.createServer(app);
  portalOrigin = await startServer(portalServer);
});

test.after(async () => {
  await new Promise((resolve) => portalServer.close(resolve));
  await new Promise((resolve) => agentServer.close(resolve));
  fs.rmSync(workspaceRoot, { recursive: true, force: true });
});

test("GET /api/it-department requires an authenticated portal session", async () => {
  const res = await requestPortal("/api/it-department");

  assert.equal(res.status, 401);
});

test("GET /api/it-department returns sanitized live pixel agent state", async () => {
  const memberCookie = createSignedSessionCookie({
    sub: "member-1",
    name: "Regular Member",
    email: "member@example.com",
    preferredUsername: "member",
    groups: ["employees"],
    isAdmin: false,
  });

  const res = await requestPortal("/api/it-department", { cookie: memberCookie });
  const serialized = JSON.stringify(res.payload);
  const karel = res.payload.agents.find((agent) => agent.id === "karel-kubernetes");

  assert.equal(res.status, 200);
  assert.equal(res.payload.title, "IT department");
  assert.equal(res.payload.degraded, false);
  assert.equal(karel.motion, "walking");
  assert.equal(karel.activity, "cluster watch: investigating");
  assert.equal(karel.role, "Kubernetes Specialist");
  assert.equal(serialized.includes("Sensitive work-order title"), false);
  assert.equal(serialized.includes("Sensitive event message"), false);
  assert.equal(serialized.includes("sensitive prompt"), false);
  assert.equal(serialized.includes("sensitive summary"), false);
  assert.ok(agentRequests.every((entry) => entry.authorization === `Bearer ${agentToken}`));
});

test("GET /api/it-department degrades to a visual fallback when agents are unavailable", async () => {
  failAgentRequests = true;
  const memberCookie = createSignedSessionCookie({
    sub: "member-1",
    name: "Regular Member",
    email: "member@example.com",
    preferredUsername: "member",
    groups: ["employees"],
    isAdmin: false,
  });

  const res = await requestPortal("/api/it-department", { cookie: memberCookie });

  assert.equal(res.status, 200);
  assert.equal(res.payload.degraded, true);
  assert.equal(res.payload.liveLabel, "offline");
  assert.ok(res.payload.agents.every((agent) => agent.motion === "alert"));
});
