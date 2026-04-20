import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const repoRoot = "/Users/harrywesterman/Documents/Twinbox";
const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-portal-test-"));
const configPath = path.join(workspaceRoot, "portal-config.json");
const dataDir = path.join(workspaceRoot, "data");
const sessionSecret = "portal-test-secret";
const fakeState = {
  users: [],
  groups: [],
  nextUserId: 10,
};
const managerState = {
  jobs: new Map(),
  nextJobId: 1,
};

function writePortalConfig(config) {
  fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
}

function seedAuthentikState() {
  fakeState.users = [
    {
      pk: "1",
      username: "portal-admin",
      name: "Portal Admin",
      email: "admin@example.com",
      is_active: true,
      type: "internal",
    },
    {
      pk: "2",
      username: "alex",
      name: "Alex Example",
      email: "alex@example.com",
      is_active: true,
      type: "internal",
    },
    {
      pk: "3",
      username: "twinbox-automation",
      name: "Twinbox Automation",
      email: "",
      is_active: true,
      type: "service_account",
    },
  ];
  fakeState.groups = [
    {
      pk: "100",
      name: "employees",
      is_superuser: false,
      users: ["2"],
    },
    {
      pk: "101",
      name: "family",
      is_superuser: false,
      users: [],
    },
    {
      pk: "102",
      name: "admins",
      is_superuser: true,
      users: ["1"],
    },
    {
      pk: "103",
      name: "twinbox-automation-superusers",
      is_superuser: true,
      users: ["3"],
    },
  ];
  fakeState.nextUserId = 10;
}

function createSignedSessionCookie(session) {
  const body = Buffer.from(JSON.stringify(session)).toString("base64url");
  const signature = crypto.createHmac("sha256", sessionSecret).update(body).digest("base64url");
  return `twinbox_portal_session=${encodeURIComponent(`${body}.${signature}`)}`;
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      resolve(text ? JSON.parse(text) : {});
    });
    req.on("error", reject);
  });
}

function sendJson(res, status, payload) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(payload));
}

function sendNoContent(res) {
  res.statusCode = 204;
  res.end();
}

function findUser(userId) {
  return fakeState.users.find((user) => user.pk === String(userId));
}

function findGroup(groupId) {
  return fakeState.groups.find((group) => group.pk === String(groupId));
}

function cloneUser(user) {
  return JSON.parse(JSON.stringify(user));
}

function cloneGroup(group) {
  return JSON.parse(JSON.stringify(group));
}

function cloneJob(job) {
  return JSON.parse(JSON.stringify(job));
}

const authentikServer = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", "http://127.0.0.1");
  const pathname = url.pathname;

  if (req.method === "GET" && pathname === "/api/v3/.well-known/openid-configuration") {
    sendJson(res, 200, {
      authorization_endpoint: `${authentikServerOrigin}/authorize`,
      token_endpoint: `${authentikServerOrigin}/token`,
      userinfo_endpoint: `${authentikServerOrigin}/userinfo`,
      jwks_uri: `${authentikServerOrigin}/jwks`,
      issuer: `${authentikServerOrigin}/api/v3`,
    });
    return;
  }

  if (req.headers.authorization !== "Bearer portal-token") {
    sendJson(res, 401, { error: "missing token" });
    return;
  }

  if (req.method === "GET" && pathname === "/api/v3/core/users/") {
    sendJson(res, 200, { results: fakeState.users.map((user) => cloneUser(user)) });
    return;
  }

  if (req.method === "POST" && pathname === "/api/v3/core/users/") {
    const body = await readRequestBody(req);
    const newUser = {
      pk: String(fakeState.nextUserId),
      username: body.username,
      name: body.name,
      email: body.email || "",
      is_active: body.is_active !== false,
      type: "internal",
    };
    fakeState.nextUserId += 1;
    fakeState.users.push(newUser);
    sendJson(res, 201, cloneUser(newUser));
    return;
  }

  if (req.method === "GET" && /^\/api\/v3\/core\/users\/[^/]+\/$/.test(pathname)) {
    const userId = pathname.split("/").filter(Boolean).at(-1);
    const user = findUser(userId);
    if (!user) {
      sendJson(res, 404, { error: "user not found" });
      return;
    }
    sendJson(res, 200, cloneUser(user));
    return;
  }

  if (req.method === "PATCH" && /^\/api\/v3\/core\/users\/[^/]+\/$/.test(pathname)) {
    const userId = pathname.split("/").filter(Boolean).at(-1);
    const user = findUser(userId);
    if (!user) {
      sendJson(res, 404, { error: "user not found" });
      return;
    }
    const body = await readRequestBody(req);
    Object.assign(user, body);
    sendJson(res, 200, cloneUser(user));
    return;
  }

  if (req.method === "POST" && /^\/api\/v3\/core\/users\/[^/]+\/set_password\/$/.test(pathname)) {
    const userId = pathname.split("/").filter(Boolean).at(-2);
    const user = findUser(userId);
    if (!user) {
      sendJson(res, 404, { error: "user not found" });
      return;
    }
    const body = await readRequestBody(req);
    user.password = body.password;
    sendNoContent(res);
    return;
  }

  if (req.method === "GET" && pathname === "/api/v3/core/groups/") {
    sendJson(res, 200, { results: fakeState.groups.map((group) => cloneGroup(group)) });
    return;
  }

  if (req.method === "GET" && /^\/api\/v3\/core\/groups\/[^/]+\/$/.test(pathname)) {
    const groupId = pathname.split("/").filter(Boolean).at(-1);
    const group = findGroup(groupId);
    if (!group) {
      sendJson(res, 404, { error: "group not found" });
      return;
    }
    sendJson(res, 200, cloneGroup(group));
    return;
  }

  if (req.method === "POST" && /^\/api\/v3\/core\/groups\/[^/]+\/add_user\/$/.test(pathname)) {
    const groupId = pathname.split("/").filter(Boolean).at(-2);
    const group = findGroup(groupId);
    const body = await readRequestBody(req);
    if (!group) {
      sendJson(res, 404, { error: "group not found" });
      return;
    }
    if (!group.users.includes(String(body.pk))) {
      group.users.push(String(body.pk));
    }
    sendNoContent(res);
    return;
  }

  if (req.method === "POST" && /^\/api\/v3\/core\/groups\/[^/]+\/remove_user\/$/.test(pathname)) {
    const groupId = pathname.split("/").filter(Boolean).at(-2);
    const group = findGroup(groupId);
    const body = await readRequestBody(req);
    if (!group) {
      sendJson(res, 404, { error: "group not found" });
      return;
    }
    group.users = group.users.filter((userId) => userId !== String(body.pk));
    sendNoContent(res);
    return;
  }

  sendJson(res, 404, { error: `Unhandled fake Authentik route: ${req.method} ${pathname}` });
});

const managerServer = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", "http://127.0.0.1");
  const pathname = url.pathname;

  if (req.method === "GET" && pathname === "/api/apps/catalog") {
    sendJson(res, 200, {
      active_cluster: {
        id: "cluster-test",
        cluster_instance_id: "cluster-test-instance",
        slug: "tst",
        dns_domain: "example.com",
      },
      categories: [
        {
          id: "apps",
          title: "Apps",
          summary: "Install user-facing applications and collaboration tools.",
          order: 30,
          status: "ready",
          steps: [
            {
              id: "install-immich",
              title: "Install Immich",
              summary: "Photo and video library",
              description: "Immich is our first app test target.",
              app_state: "ready",
              placeholder: false,
              accent: "#ec4899",
              iconText: "I",
              latest_job: null,
              dependencies: [
                { id: "install-longhorn-storage", title: "Install Longhorn Storage", state: "done" },
              ],
            },
            {
              id: "install-paperless",
              title: "Install Paperless",
              summary: "Document archive",
              description: "Placeholder app.",
              app_state: "planned",
              placeholder: true,
              accent: "#84cc16",
              iconText: "IP",
              latest_job: null,
              dependencies: [],
            },
          ],
        },
      ],
      bundles: [
        {
          id: "media",
          title: "Media",
          summary: "Photo and video tools",
          order: 10,
          apps: ["install-immich"],
        },
      ],
      errors: [],
    });
    return;
  }

  if (req.method === "POST" && /^\/api\/apps\/[^/]+\/install$/.test(pathname)) {
    const stepId = pathname.split("/").filter(Boolean).at(-2);
    const body = await readRequestBody(req);
    const jobId = `job-${managerState.nextJobId}`;
    managerState.nextJobId += 1;
    const job = {
      id: jobId,
      type: "run_step",
      status: "running",
      step: "started",
      cluster_id: body.cluster_id || "cluster-test",
      cluster_instance_id: body.cluster_instance_id || "cluster-test-instance",
      payload: {
        step_id: stepId,
      },
    };
    managerState.jobs.set(jobId, job);
    sendJson(res, 202, {
      step_id: stepId,
      cluster_id: job.cluster_id,
      cluster_instance_id: job.cluster_instance_id,
      job_id: jobId,
      job_type: "run_step",
    });
    return;
  }

  if (req.method === "GET" && /^\/api\/jobs\/[^/]+$/.test(pathname)) {
    const jobId = pathname.split("/").filter(Boolean).at(-1);
    const job = managerState.jobs.get(jobId);
    if (!job) {
      sendJson(res, 404, { error: "job not found" });
      return;
    }
    sendJson(res, 200, cloneJob(job));
    return;
  }

  if (req.method === "GET" && /^\/api\/jobs\/[^/]+\/logs$/.test(pathname)) {
    const jobId = pathname.split("/").filter(Boolean).at(-2);
    const job = managerState.jobs.get(jobId);
    if (!job) {
      sendJson(res, 404, { error: "job not found" });
      return;
    }
    sendJson(res, 200, {
      lines: [
        { line: `[2026-04-18 12:00:00] queued run_step` },
        { line: `[2026-04-18 12:00:01] running job type=run_step` },
      ],
    });
    return;
  }

  if (req.method === "POST" && /^\/api\/jobs\/[^/]+\/cancel$/.test(pathname)) {
    const jobId = pathname.split("/").filter(Boolean).at(-2);
    const job = managerState.jobs.get(jobId);
    if (!job) {
      sendJson(res, 404, { error: "job not found" });
      return;
    }
    job.status = "canceled";
    job.step = "canceled";
    sendJson(res, 200, cloneJob(job));
    return;
  }

  sendJson(res, 404, { error: `Unhandled fake manager route: ${req.method} ${pathname}` });
});

let portalServer;
let portalOrigin = "";
let authentikServerOrigin = "";
let managerServerOrigin = "";

async function startServer(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

async function requestPortal(pathname, { method = "GET", body, cookie } = {}) {
  const response = await fetch(`${portalOrigin}${pathname}`, {
    method,
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(cookie ? { Cookie: cookie } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
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

  return {
    status: response.status,
    payload,
  };
}

test.before(async () => {
  seedAuthentikState();
  writePortalConfig({
    userAdmin: {
      manageableGroups: [
        { name: "employees", label: "Employees" },
        { name: "family", label: "Family" },
      ],
    },
    apps: [
      {
        id: "immich",
        slug: "immich",
        title: "Immich",
        label: "Immich",
        section: "Apps",
        url: "https://immich.example.com",
        route: "/apps/immich",
        accent: "#ec4899",
        summary: "Photo and video library",
        description: "Photo and video library",
        capabilities: [],
        adminOnly: false,
        status: "succeeded",
        sourceStepId: "install-immich",
        sourceStepTitle: "Install Immich",
        iconText: "I",
        iconUrl: "/assets/step-icons/install-immich.svg",
        iconAlt: "Immich icon",
        liveUrl: "https://immich.example.com",
      },
    ],
    appSections: [
      {
        name: "Apps",
        items: [
          {
            id: "immich",
            title: "Immich",
            iconUrl: "/assets/step-icons/install-immich.svg",
          },
        ],
      },
    ],
  });

  authentikServerOrigin = await startServer(authentikServer);
  managerServerOrigin = await startServer(managerServer);
  process.env.NODE_ENV = "test";
  process.env.PORTAL_CONFIG_PATH = configPath;
  process.env.PORTAL_DATA_DIR = dataDir;
  process.env.PORTAL_SESSION_SECRET = sessionSecret;
  process.env.PORTAL_OIDC_CLIENT_ID = "portal-client";
  process.env.PORTAL_OIDC_ISSUER = `${authentikServerOrigin}/api/v3`;
  process.env.AUTHENTIK_API_TOKEN = "portal-token";
  process.env.AUTHENTIK_API_BASE = `${authentikServerOrigin}/api/v3`;
  process.env.PORTAL_MANAGER_BASE_URL = managerServerOrigin;

  const moduleUrl = `${pathToFileURL(path.join(repoRoot, "portal", "server.mjs")).href}?test=${Date.now()}`;
  const { app } = await import(moduleUrl);
  portalServer = http.createServer(app);
  portalOrigin = await startServer(portalServer);
});

test.after(async () => {
  await new Promise((resolve) => portalServer.close(resolve));
  await new Promise((resolve) => authentikServer.close(resolve));
  await new Promise((resolve) => managerServer.close(resolve));
  fs.rmSync(workspaceRoot, { recursive: true, force: true });
});

test("admin endpoints require an authenticated admin session", async () => {
  seedAuthentikState();

  const unauthenticated = await requestPortal("/api/admin/users");
  assert.equal(unauthenticated.status, 401);

  const unauthenticatedApps = await requestPortal("/api/admin/apps/catalog");
  assert.equal(unauthenticatedApps.status, 401);

  const memberCookie = createSignedSessionCookie({
    sub: "member-1",
    name: "Regular Member",
    email: "member@example.com",
    preferredUsername: "member",
    groups: ["employees"],
    isAdmin: false,
  });

  const forbidden = await requestPortal("/api/admin/users", { cookie: memberCookie });
  assert.equal(forbidden.status, 403);

  const forbiddenApps = await requestPortal("/api/admin/apps/catalog", { cookie: memberCookie });
  assert.equal(forbiddenApps.status, 403);
});

test("admin can create a user with a temporary password and approved groups", async () => {
  seedAuthentikState();

  const adminCookie = createSignedSessionCookie({
    sub: "admin-1",
    name: "Portal Admin",
    email: "admin@example.com",
    preferredUsername: "portal-admin",
    groups: ["admins"],
    isAdmin: true,
  });

  const created = await requestPortal("/api/admin/users", {
    method: "POST",
    cookie: adminCookie,
    body: {
      username: "mia",
      name: "Mia Example",
      email: "mia@example.com",
      groupNames: ["employees"],
    },
  });

  assert.equal(created.status, 201);
  assert.match(created.payload.temporaryPassword, /^Tbx-/);
  assert.equal(created.payload.user.username, "mia");
  assert.deepEqual(created.payload.user.groupNames, ["employees"]);

  const listing = await requestPortal("/api/admin/users", { cookie: adminCookie });
  assert.equal(listing.status, 200);
  assert(listing.payload.users.some((user) => user.username === "mia"));
  assert(!listing.payload.users.some((user) => user.username === "twinbox-automation"));
});

test("admin can disable and reactivate a regular user", async () => {
  seedAuthentikState();

  const adminCookie = createSignedSessionCookie({
    sub: "admin-1",
    name: "Portal Admin",
    email: "admin@example.com",
    preferredUsername: "portal-admin",
    groups: ["admins"],
    isAdmin: true,
  });

  const disabled = await requestPortal("/api/admin/users/2/disable", {
    method: "POST",
    cookie: adminCookie,
  });
  assert.equal(disabled.status, 200);
  assert.equal(disabled.payload.user.isActive, false);

  const enabled = await requestPortal("/api/admin/users/2/enable", {
    method: "POST",
    cookie: adminCookie,
  });
  assert.equal(enabled.status, 200);
  assert.equal(enabled.payload.user.isActive, true);
});

test("group updates block privileged groups and allow approved memberships", async () => {
  seedAuthentikState();

  const adminCookie = createSignedSessionCookie({
    sub: "admin-1",
    name: "Portal Admin",
    email: "admin@example.com",
    preferredUsername: "portal-admin",
    groups: ["admins"],
    isAdmin: true,
  });

  const blocked = await requestPortal("/api/admin/users/2/groups", {
    method: "PUT",
    cookie: adminCookie,
    body: {
      groupNames: ["admins"],
    },
  });
  assert.equal(blocked.status, 400);

  const updated = await requestPortal("/api/admin/users/2/groups", {
    method: "PUT",
    cookie: adminCookie,
    body: {
      groupNames: ["family"],
    },
  });
  assert.equal(updated.status, 200);
  assert.deepEqual(updated.payload.user.groupNames, ["family"]);
});

test("admin can load the app catalog and queue an install job", async () => {
  seedAuthentikState();

  const adminCookie = createSignedSessionCookie({
    sub: "admin-1",
    name: "Portal Admin",
    email: "admin@example.com",
    preferredUsername: "portal-admin",
    groups: ["admins"],
    isAdmin: true,
  });

  const catalog = await requestPortal("/api/admin/apps/catalog", { cookie: adminCookie });
  assert.equal(catalog.status, 200);
  assert.equal(catalog.payload.categories[0].steps[0].title, "Install Immich");
  assert.equal(catalog.payload.bundles[0].title, "Media");

  const queued = await requestPortal("/api/admin/apps/install-immich/install", {
    method: "POST",
    cookie: adminCookie,
  });
  assert.equal(queued.status, 202);
  assert.match(queued.payload.job_id, /^job-/);

  const logs = await requestPortal(`/api/admin/apps/jobs/${queued.payload.job_id}/logs`, {
    cookie: adminCookie,
  });
  assert.equal(logs.status, 200);
  assert.ok(Array.isArray(logs.payload.lines));
  assert(logs.payload.lines.length > 0);
});

test("portal config exposes a single Apps section and image icons", async () => {
  seedAuthentikState();

  const adminCookie = createSignedSessionCookie({
    sub: "admin-1",
    name: "Portal Admin",
    email: "admin@example.com",
    preferredUsername: "portal-admin",
    groups: ["admins"],
    isAdmin: true,
  });

  const config = await requestPortal("/api/portal-config", { cookie: adminCookie });
  assert.equal(config.status, 200);
  assert.equal(config.payload.apps.length, 1);
  assert.equal(config.payload.appSections.length, 1);
  assert.equal(config.payload.appSections[0].name, "Apps");
  assert.equal(config.payload.apps[0].iconUrl, "/assets/step-icons/install-immich.svg");
  assert.equal(config.payload.apps[0].iconAlt, "Immich icon");
});

test("login requests the reduced Authentik scope set", async () => {
  const response = await fetch(`${portalOrigin}/auth/login`, {
    redirect: "manual",
  });

  assert.equal(response.status, 302);
  const location = new URL(response.headers.get("location"));
  assert.equal(location.searchParams.get("scope"), "openid profile email");
});

test("portal image copies the Authentik admin helper into the runtime image", async () => {
  const dockerfile = await fs.promises.readFile(path.join(repoRoot, "portal", "Dockerfile"), "utf8");
  assert.match(dockerfile, /COPY authentik-admin\.mjs \.\/[\s\S]*CMD \["node", "server\.mjs"\]/, 'expected the runtime image to include the portal helper module');
});

test("portal app launches open in a new tab", async () => {
  const source = await fs.promises.readFile(path.join(repoRoot, "portal", "src", "App.jsx"), "utf8");
  assert.match(source, /window\.open\(url,\s*'_blank',\s*'noopener,noreferrer'\)/);
});

test("portal menu popover sits above the page content", async () => {
  const css = await fs.promises.readFile(path.join(repoRoot, "portal", "src", "App.css"), "utf8");
  assert.match(css, /\.topbar\s*\{[\s\S]*z-index:\s*30;[\s\S]*\}/, 'expected the header to establish a stacking layer');
  assert.match(css, /\.topbar-actions\s*\{[\s\S]*z-index:\s*40;[\s\S]*\}/, 'expected the action cluster to sit above the page content');
  assert.match(css, /\.menu-popover\s*\{[\s\S]*z-index:\s*50;[\s\S]*\}/, 'expected the menu popover to render on top of cards');
});
