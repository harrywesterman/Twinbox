import crypto from "crypto";
import fs from "fs";
import path from "path";
import express from "express";
import { createRemoteJWKSet, jwtVerify } from "jose";
import {
  buildDirectory,
  createAuthentikAdminClient,
  createTemporaryPassword,
  DEFAULT_AUTHENTIK_API_BASE,
  ensureRequestedGroupsAreManageable,
  isServiceAccountUser,
  normalizeManageableGroupsConfig,
  normalizeRequestedGroupNames,
} from "./authentik-admin.mjs";
import {
  createRandomMailboxPassword,
  isMailuInstalled,
  mailuCreateMailbox,
} from "./mailu-client.mjs";

const app = express();
const port = Number(process.env.PORT || 8080);
const dataDir = process.env.PORTAL_DATA_DIR || "/data";
const configPath = process.env.PORTAL_CONFIG_PATH || "/config/portal-config.json";
const sessionSecret = process.env.PORTAL_SESSION_SECRET || "twinbox-portal-dev-secret";
const sessionCookieName = process.env.PORTAL_SESSION_COOKIE || "twinbox_portal_session";
const oauthCookieName = process.env.PORTAL_OAUTH_COOKIE || "twinbox_portal_oauth";
const oauthStateDir = path.join(dataDir, "oauth-state");
const oauthStateTtlMs = 10 * 60 * 1000;
const managerBaseUrl = String(process.env.PORTAL_MANAGER_BASE_URL || "http://manager-api:8080")
  .trim()
  .replace(/\/+$/, "");
const publicBaseUrl = normalizeBaseUrl(process.env.PORTAL_BASE_URL || "");
const issuer = String(process.env.PORTAL_OIDC_ISSUER || process.env.AUTHENTIK_ISSUER || "").trim();
const clientId = String(process.env.PORTAL_OIDC_CLIENT_ID || "").trim();
const authentikApiBase = String(
  process.env.AUTHENTIK_API_BASE || DEFAULT_AUTHENTIK_API_BASE
).trim();
const authentikApiToken = String(process.env.AUTHENTIK_API_TOKEN || "").trim();
const APP_INSTALLATION_GROUP_NAME = "Twinbox app installations";
const USER_MANAGEMENT_GROUP_NAME = "Twinbox user management";
const APP_JOB_TYPES = new Set(["run_step", "uninstall_step"]);

fs.mkdirSync(dataDir, { recursive: true });

app.disable("x-powered-by");
app.set("trust proxy", 1);
app.use(express.json({ limit: "1mb" }));

const distDir = path.join(process.cwd(), "dist");
const indexHtmlPath = path.join(distDir, "index.html");
const preferencesPath = path.join(dataDir, "preferences.json");
const defaultPortalConfig = {
  portal: {
    brand: "Twinbox",
    hero: {
      eyebrow: "User portal",
      title: "Twinbox",
      description: "Log in to open your cluster apps.",
    },
  },
  settings: {},
  userAdmin: {
    eyebrow: "Admin",
    title: "Gebruikers en groepen",
    description: "Beheer gebruikers en zakelijke groepen vanuit het portal.",
    emptyStateTitle: "Nog geen beheerbare groepen ingesteld",
    emptyStateDescription: "Voeg eerst beheerbare groepen toe aan de portal-config.",
    manageableGroups: [],
  },
  observability: {
    eyebrow: "Admin",
    title: "Observability control",
    description: "Choose how much monitoring the cluster should carry.",
    footnote: "Metrics-server stays enabled in every mode so kubectl top keeps working.",
    profiles: {
      minimal: {},
      full: {},
      off: {},
    },
  },
  apps: [],
  adminApps: [],
  intranetLinks: [],
  statusChecks: [],
};

let cachedDiscovery = null;
let cachedJwks = null;

function base64UrlEncode(input) {
  return Buffer.from(input).toString("base64url");
}

function base64UrlDecode(input) {
  return Buffer.from(String(input || ""), "base64url").toString("utf8");
}

function hmacSign(value) {
  return crypto.createHmac("sha256", sessionSecret).update(value).digest("base64url");
}

function encodeSignedJson(payload) {
  const body = base64UrlEncode(JSON.stringify(payload));
  return `${body}.${hmacSign(body)}`;
}

function decodeSignedJson(value) {
  const [body, signature] = String(value || "").split(".");
  if (!body || !signature) {
    return null;
  }
  if (hmacSign(body) !== signature) {
    return null;
  }
  try {
    return JSON.parse(base64UrlDecode(body));
  } catch {
    return null;
  }
}

function readCookies(req) {
  const cookieHeader = String(req.headers.cookie || "");
  if (!cookieHeader) {
    return {};
  }

  return cookieHeader.split(";").reduce((acc, segment) => {
    const index = segment.indexOf("=");
    if (index < 0) {
      return acc;
    }
    const key = decodeURIComponent(segment.slice(0, index).trim());
    const value = decodeURIComponent(segment.slice(index + 1).trim());
    if (key) {
      acc[key] = value;
    }
    return acc;
  }, {});
}

function normalizeBaseUrl(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }

  const url = new URL(raw);
  if (!["http:", "https:"].includes(url.protocol) || !url.host) {
    throw new Error("PORTAL_BASE_URL must be an absolute http(s) URL");
  }

  return `${url.protocol}//${url.host}${url.pathname.replace(/\/+$/, "")}`;
}

function isSecureRequest(req) {
  return (
    publicBaseUrl.startsWith("https://") ||
    String(req.headers["x-forwarded-proto"] || "").includes("https")
  );
}

function cookieOptions(req, { maxAge = null } = {}) {
  const secure = isSecureRequest(req);
  return [
    "Path=/",
    "HttpOnly",
    "SameSite=Lax",
    secure ? "Secure" : null,
    maxAge ? `Max-Age=${Math.floor(maxAge / 1000)}` : null,
  ]
    .filter(Boolean)
    .join("; ");
}

function setCookie(res, req, name, value, options = {}) {
  res.setHeader("Set-Cookie", [
    ...(Array.isArray(res.getHeader("Set-Cookie"))
      ? res.getHeader("Set-Cookie")
      : res.getHeader("Set-Cookie")
        ? [res.getHeader("Set-Cookie")]
        : []),
    `${name}=${encodeURIComponent(value)}; ${cookieOptions(req, options)}`,
  ]);
}

function clearCookie(res, req, name) {
  res.setHeader("Set-Cookie", [
    ...(Array.isArray(res.getHeader("Set-Cookie"))
      ? res.getHeader("Set-Cookie")
      : res.getHeader("Set-Cookie")
        ? [res.getHeader("Set-Cookie")]
        : []),
    `${name}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${isSecureRequest(req) ? "; Secure" : ""}`,
  ]);
}

function oauthStateFilePath(state) {
  return path.join(oauthStateDir, `${state}.json`);
}

async function cleanupExpiredOAuthStates() {
  try {
    const entries = await fs.promises.readdir(oauthStateDir, { withFileTypes: true });
    await Promise.all(
      entries.map(async (entry) => {
        if (!entry.isFile() || !entry.name.endsWith(".json")) {
          return;
        }
        const filePath = path.join(oauthStateDir, entry.name);
        try {
          const payload = await readJsonFile(filePath, null);
          const createdAt = Number(payload?.createdAt || 0);
          if (!createdAt || Date.now() - createdAt > oauthStateTtlMs) {
            await fs.promises.rm(filePath, { force: true });
          }
        } catch {
          await fs.promises.rm(filePath, { force: true });
        }
      })
    );
  } catch (error) {
    if (error?.code !== "ENOENT") {
      throw error;
    }
  }
}

async function saveOAuthState(statePayload) {
  if (!statePayload?.state) {
    throw new Error("missing oauth state");
  }

  await fs.promises.mkdir(oauthStateDir, { recursive: true });
  await cleanupExpiredOAuthStates();
  const createdAt = Number(statePayload.createdAt || Date.now());
  await writeJsonFile(oauthStateFilePath(statePayload.state), {
    ...statePayload,
    createdAt,
  });
  return {
    ...statePayload,
    createdAt,
  };
}

async function loadOAuthState(state) {
  const stateValue = String(state || "").trim();
  if (!stateValue) {
    return null;
  }

  const filePath = oauthStateFilePath(stateValue);
  try {
    const payload = await readJsonFile(filePath, null);
    if (!payload) {
      return null;
    }

    const createdAt = Number(payload.createdAt || 0);
    if (!createdAt || Date.now() - createdAt > oauthStateTtlMs) {
      await fs.promises.rm(filePath, { force: true });
      return null;
    }

    return payload;
  } catch {
    await fs.promises.rm(filePath, { force: true });
    return null;
  }
}

async function clearOAuthState(state) {
  const stateValue = String(state || "").trim();
  if (!stateValue) {
    return;
  }

  await fs.promises.rm(oauthStateFilePath(stateValue), { force: true });
}

function sanitizeReturnTo(rawValue) {
  const value = String(rawValue || "").trim();
  if (!value) {
    return "/";
  }
  if (!value.startsWith("/")) {
    return "/";
  }
  if (value.startsWith("//")) {
    return "/";
  }
  return value;
}

async function readJsonFile(filePath, fallback = {}) {
  try {
    const text = await fs.promises.readFile(filePath, "utf8");
    return text ? JSON.parse(text) : fallback;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return fallback;
    }
    throw error;
  }
}

async function writeJsonFile(filePath, value) {
  const tempPath = `${filePath}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  await fs.promises.writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await fs.promises.rename(tempPath, filePath);
}

async function loadPortalConfig() {
  const config = await readJsonFile(configPath, defaultPortalConfig);
  return {
    ...defaultPortalConfig,
    ...config,
    portal: {
      ...defaultPortalConfig.portal,
      ...(config?.portal || {}),
    },
    settings: {
      ...defaultPortalConfig.settings,
      ...(config?.settings || {}),
    },
    userAdmin: {
      ...defaultPortalConfig.userAdmin,
      ...(config?.userAdmin || {}),
      manageableGroups: normalizeManageableGroupsConfig(config?.userAdmin?.manageableGroups),
    },
    observability: {
      ...defaultPortalConfig.observability,
      ...(config?.observability || {}),
      profiles: {
        ...defaultPortalConfig.observability.profiles,
        ...(config?.observability?.profiles || {}),
      },
    },
  };
}

async function loadPreferences() {
  return readJsonFile(preferencesPath, {});
}

async function savePreferences(nextPreferences) {
  await fs.promises.mkdir(path.dirname(preferencesPath), { recursive: true });
  await writeJsonFile(preferencesPath, nextPreferences);
}

function managerUrl(pathname) {
  const normalizedPath = String(pathname || "").startsWith("/")
    ? String(pathname || "")
    : `/${String(pathname || "")}`;
  return new URL(normalizedPath, `${managerBaseUrl}/`).toString();
}

async function requestManagerJson(
  pathname,
  { method = "GET", body = undefined, headers = {} } = {}
) {
  const init = {
    method,
    headers: {
      ...headers,
    },
  };

  if (body !== undefined) {
    init.body = typeof body === "string" ? body : JSON.stringify(body);
    if (!init.headers["Content-Type"]) {
      init.headers["Content-Type"] = "application/json";
    }
  }

  const response = await fetch(managerUrl(pathname), init);
  const text = await response.text();
  let parsed = null;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
  }

  if (!response.ok) {
    const error = new Error(
      parsed?.error || parsed?.message || text || `Manager request failed with ${response.status}`
    );
    error.status = response.status;
    throw error;
  }

  return parsed;
}

async function loadActiveClusterState() {
  const catalog = await requestManagerJson("/api/apps/catalog");
  const activeCluster = catalog?.active_cluster;
  if (!activeCluster?.id) {
    const error = new Error("cluster not found");
    error.status = 404;
    throw error;
  }

  const cluster = await requestManagerJson(`/api/clusters/${encodeURIComponent(activeCluster.id)}`);
  return {
    catalog,
    activeCluster,
    cluster,
  };
}

function collectAppStepIds(catalog = {}) {
  const appCategory = (Array.isArray(catalog?.categories) ? catalog.categories : []).find(
    (category) => category?.id === "apps"
  );
  return new Set(
    (Array.isArray(appCategory?.steps) ? appCategory.steps : [])
      .map((step) => String(step?.id || "").trim())
      .filter(Boolean)
  );
}

async function loadScopedAppJob(jobId) {
  const normalizedJobId = String(jobId || "").trim();
  const job = await requestManagerJson(`/api/jobs/${encodeURIComponent(normalizedJobId)}`);
  const jobType = String(job?.type || "").trim();
  const stepId = String(job?.payload?.step_id || job?.step_id || "").trim();

  if (!APP_JOB_TYPES.has(jobType) || !stepId) {
    const error = new Error("app job access required");
    error.status = 403;
    throw error;
  }

  const catalog = await requestManagerJson("/api/apps/catalog");
  if (!collectAppStepIds(catalog).has(stepId)) {
    const error = new Error("app job access required");
    error.status = 403;
    throw error;
  }

  return job;
}

function getOrigin(req) {
  if (publicBaseUrl) {
    return publicBaseUrl;
  }

  const proto =
    String(req.headers["x-forwarded-proto"] || "http")
      .split(",")[0]
      .trim() || "http";
  const host = String(req.headers["x-forwarded-host"] || req.headers.host || "")
    .split(",")[0]
    .trim();
  return `${proto}://${host}`;
}

function getCurrentSession(req) {
  const cookies = readCookies(req);
  const session = decodeSignedJson(cookies[sessionCookieName]);
  if (!session?.sub) {
    return null;
  }
  return session;
}

function requireSession(req, res) {
  const session = getCurrentSession(req);
  if (!session) {
    res.status(401).json({ error: "not authenticated" });
    return null;
  }
  return session;
}

function requireAdminSession(req, res) {
  const session = requireSession(req, res);
  if (!session) {
    return null;
  }

  const capabilities = buildPortalCapabilities(session.groups);
  if (!capabilities.isAdmin) {
    res.status(403).json({ error: "admin access required" });
    return null;
  }

  return {
    ...session,
    ...capabilities,
  };
}

function buildPortalCapabilities(groups = []) {
  const groupSet = new Set(
    (Array.isArray(groups) ? groups : []).map((value) => String(value || "").trim())
  );
  const isAdmin = groupSet.has("admins");

  return {
    isAdmin,
    canManageApps: isAdmin || groupSet.has(APP_INSTALLATION_GROUP_NAME),
    canManageUsers: isAdmin || groupSet.has(USER_MANAGEMENT_GROUP_NAME),
  };
}

function requirePortalCapability(req, res, capability, message) {
  const session = requireSession(req, res);
  if (!session) {
    return null;
  }

  const capabilities = buildPortalCapabilities(session.groups);
  if (!capabilities[capability]) {
    res.status(403).json({ error: message || "admin access required" });
    return null;
  }

  return {
    ...session,
    ...capabilities,
  };
}

function resolveRecordId(record) {
  return String(record?.pk || record?.id || record?.uuid || "").trim();
}

function readListPayload(payload) {
  if (Array.isArray(payload)) {
    return payload;
  }

  if (Array.isArray(payload?.results)) {
    return payload.results;
  }

  if (Array.isArray(payload?.items)) {
    return payload.items;
  }

  if (Array.isArray(payload?.data)) {
    return payload.data;
  }

  return [];
}

function getAuthentikAdminClient() {
  return createAuthentikAdminClient({
    baseUrl: authentikApiBase,
    token: authentikApiToken,
  });
}

async function ensureConfiguredManageableGroups(client, config) {
  const configuredGroups = normalizeManageableGroupsConfig(config?.userAdmin?.manageableGroups);
  if (configuredGroups.length === 0) {
    return;
  }

  const groups = readListPayload(await client.listGroups());
  const groupsByName = new Map(
    groups
      .map((group) => [String(group?.name || "").trim(), group])
      .filter(([name]) => Boolean(name))
  );

  for (const groupConfig of configuredGroups) {
    const isAdminsGroup = groupConfig.name === "admins";
    const existing = groupsByName.get(groupConfig.name);
    const payload = {
      name: groupConfig.name,
      is_superuser: isAdminsGroup,
    };

    if (!existing) {
      await client.createGroup(payload);
      continue;
    }

    const groupId = resolveRecordId(existing);
    if (!groupId || existing?.is_superuser === isAdminsGroup) {
      continue;
    }

    await client.updateGroup(groupId, payload);
  }
}

async function listAuthentikGroupsWithMembers(client) {
  const groups = readListPayload(await client.listGroups());

  return Promise.all(
    groups.map(async (group) => {
      const groupId = resolveRecordId(group);
      if (!groupId) {
        return group;
      }

      try {
        return await client.getGroup(groupId);
      } catch {
        return group;
      }
    })
  );
}

async function loadUserAdminDirectory(config) {
  const client = getAuthentikAdminClient();
  await ensureConfiguredManageableGroups(client, config);
  const [usersPayload, groupsWithMembers] = await Promise.all([
    client.listUsers(),
    listAuthentikGroupsWithMembers(client),
  ]);

  return buildDirectory({
    users: readListPayload(usersPayload),
    groups: groupsWithMembers,
    manageableGroupsConfig: config?.userAdmin?.manageableGroups,
  });
}

async function getEligibleUserOrThrow(client, userId) {
  const user = await client.getUser(userId);
  if (!resolveRecordId(user)) {
    const error = new Error("user not found");
    error.status = 404;
    throw error;
  }

  if (isServiceAccountUser(user)) {
    const error = new Error("service accounts cannot be managed from the portal");
    error.status = 400;
    throw error;
  }

  return user;
}

function isHiddenPortalUser(user = {}) {
  const username = String(user?.username || "")
    .trim()
    .toLowerCase();
  const name = String(user?.name || "")
    .trim()
    .toLowerCase();

  return (
    username === "akadmin" ||
    username.startsWith("outpost-") ||
    username.startsWith("ak-outpost-") ||
    name.includes("default admin") ||
    name.includes("embedded outpost service-account")
  );
}

function isCurrentSessionUser(session = {}, user = {}) {
  const userId = resolveRecordId(user);
  const username = String(user?.username || "").trim();
  const email = String(user?.email || "").trim();

  return (
    (userId && userId === String(session.sub || "").trim()) ||
    (username && username === String(session.preferredUsername || "").trim()) ||
    (email && email === String(session.email || "").trim())
  );
}

function buildUserResponse(directory, userId) {
  const user = (directory?.users || []).find((entry) => entry.id === String(userId).trim());
  if (!user) {
    const error = new Error("user not found");
    error.status = 404;
    throw error;
  }
  return user;
}

function normalizeUserDraft(body = {}) {
  const username = String(body.username || "").trim();
  const name = String(body.name || body.fullName || "").trim();
  const email = String(body.email || "").trim();
  const groupNames = normalizeRequestedGroupNames(body.groupNames);

  if (!username) {
    const error = new Error("username is required");
    error.status = 400;
    throw error;
  }

  if (!name) {
    const error = new Error("name is required");
    error.status = 400;
    throw error;
  }

  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    const error = new Error("email address is invalid");
    error.status = 400;
    throw error;
  }

  return {
    username,
    name,
    email,
    groupNames,
  };
}

async function discoverIssuer() {
  if (cachedDiscovery) {
    return cachedDiscovery;
  }
  if (!issuer) {
    throw new Error("PORTAL_OIDC_ISSUER is not configured");
  }

  const response = await fetch(
    new URL(".well-known/openid-configuration", issuer.endsWith("/") ? issuer : `${issuer}/`)
  );
  if (!response.ok) {
    throw new Error(`failed to discover OIDC metadata (${response.status})`);
  }
  cachedDiscovery = await response.json();
  return cachedDiscovery;
}

async function verifyIdToken(idToken, expectedNonce) {
  const discovery = await discoverIssuer();
  if (!cachedJwks) {
    cachedJwks = createRemoteJWKSet(new URL(discovery.jwks_uri));
  }

  const { payload } = await jwtVerify(idToken, cachedJwks, {
    issuer: discovery.issuer || issuer,
    audience: clientId,
  });

  if (expectedNonce && payload.nonce !== expectedNonce) {
    throw new Error("OIDC nonce mismatch");
  }

  return payload;
}

function randomBase64Url(bytes = 32) {
  return crypto.randomBytes(bytes).toString("base64url");
}

function sha256Base64Url(value) {
  return crypto.createHash("sha256").update(value).digest("base64url");
}

async function exchangeAuthorizationCode({ code, codeVerifier, redirectUri }) {
  if (!clientId) {
    throw new Error("PORTAL_OIDC_CLIENT_ID is not configured");
  }
  const discovery = await discoverIssuer();
  const response = await fetch(discovery.token_endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: clientId,
      code,
      code_verifier: codeVerifier,
      redirect_uri: redirectUri,
    }),
  });

  if (!response.ok) {
    throw new Error(`token exchange failed (${response.status})`);
  }

  return response.json();
}

async function fetchUserInfo(accessToken) {
  const discovery = await discoverIssuer();
  if (!discovery.userinfo_endpoint) {
    return {};
  }

  const response = await fetch(discovery.userinfo_endpoint, {
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
  });

  if (!response.ok) {
    return {};
  }

  return response.json();
}

function buildSessionFromClaims(claims) {
  const groups = Array.isArray(claims?.groups)
    ? claims.groups.map((value) => String(value || "").trim()).filter(Boolean)
    : [];
  const capabilities = buildPortalCapabilities(groups);

  return {
    sub: String(claims?.sub || "").trim(),
    name: String(
      claims?.name || claims?.preferred_username || claims?.email || "Twinbox user"
    ).trim(),
    email: String(claims?.email || "").trim(),
    preferredUsername: String(claims?.preferred_username || "").trim(),
    groups,
    ...capabilities,
  };
}

async function renderAppShell(_req, res) {
  const file = await fs.promises.readFile(indexHtmlPath, "utf8");
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.send(file);
}

app.get("/auth/login", async (req, res) => {
  try {
    const session = getCurrentSession(req);
    if (session) {
      res.redirect(sanitizeReturnTo(req.query.returnTo));
      return;
    }

    const discovery = await discoverIssuer();
    const origin = getOrigin(req);
    const redirectUri = `${origin}/auth/callback`;
    const state = randomBase64Url(24);
    const codeVerifier = randomBase64Url(48);
    const codeChallenge = sha256Base64Url(codeVerifier);
    const nonce = randomBase64Url(24);
    const returnTo = sanitizeReturnTo(req.query.returnTo);
    const oauthState = await saveOAuthState({
      state,
      codeVerifier,
      nonce,
      returnTo,
      createdAt: Date.now(),
    });

    setCookie(res, req, oauthCookieName, encodeSignedJson(oauthState), { maxAge: oauthStateTtlMs });

    const authorizationUrl = new URL(discovery.authorization_endpoint);
    authorizationUrl.searchParams.set("response_type", "code");
    authorizationUrl.searchParams.set("client_id", clientId);
    authorizationUrl.searchParams.set("redirect_uri", redirectUri);
    authorizationUrl.searchParams.set("scope", "openid profile email groups");
    authorizationUrl.searchParams.set("state", state);
    authorizationUrl.searchParams.set("nonce", nonce);
    authorizationUrl.searchParams.set("code_challenge", codeChallenge);
    authorizationUrl.searchParams.set("code_challenge_method", "S256");

    res.redirect(authorizationUrl.toString());
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : "login failed" });
  }
});

app.get("/auth/callback", async (req, res) => {
  const stateValue = String(req.query.state || "");
  let oauthState = null;
  try {
    const cookies = readCookies(req);
    oauthState = (await loadOAuthState(stateValue)) || decodeSignedJson(cookies[oauthCookieName]);
    if (!oauthState?.state || oauthState.state !== stateValue) {
      throw new Error("invalid login state");
    }

    const origin = getOrigin(req);
    const redirectUri = `${origin}/auth/callback`;
    const tokenResponse = await exchangeAuthorizationCode({
      code: String(req.query.code || ""),
      codeVerifier: oauthState.codeVerifier,
      redirectUri,
    });

    const idTokenClaims = await verifyIdToken(tokenResponse.id_token, oauthState.nonce);

    const userInfo = await fetchUserInfo(tokenResponse.access_token);
    const mergedClaims = {
      ...idTokenClaims,
      ...userInfo,
    };
    const session = buildSessionFromClaims(mergedClaims);
    if (!session.sub) {
      throw new Error("missing subject claim");
    }

    setCookie(
      res,
      req,
      sessionCookieName,
      encodeSignedJson({
        ...session,
        tokenType: tokenResponse.token_type || "Bearer",
        createdAt: Date.now(),
      }),
      { maxAge: 7 * 24 * 60 * 60 * 1000 }
    );
    clearCookie(res, req, oauthCookieName);
    await clearOAuthState(oauthState.state);
    res.redirect(oauthState.returnTo || "/");
  } catch (error) {
    if (oauthState?.state) {
      await clearOAuthState(oauthState.state);
    }
    res.status(400).send(`
      <!doctype html>
      <html>
        <head><meta charset="utf-8"><title>Twinbox login failed</title></head>
        <body style="font-family: sans-serif; padding: 2rem;">
          <h1>Login failed</h1>
          <p>${String(error instanceof Error ? error.message : error)}</p>
          <p><a href="/auth/login">Try again</a></p>
        </body>
      </html>
    `);
  }
});

app.get("/auth/logout", (req, res) => {
  clearCookie(res, req, sessionCookieName);
  clearCookie(res, req, oauthCookieName);
  res.redirect("/");
});

app.get("/api/health", (_, res) => {
  res.json({ ok: true, time: new Date().toISOString() });
});

app.get("/api/session", (req, res) => {
  const session = getCurrentSession(req);
  if (!session) {
    return res.status(401).json({ error: "not authenticated" });
  }
  return res.json({
    ok: true,
    session: { ...session, ...buildPortalCapabilities(session.groups) },
  });
});

app.get("/api/portal-config", async (req, res) => {
  const session = requireSession(req, res);
  if (!session) {
    return;
  }

  try {
    const config = await loadPortalConfig();
    res.json({
      ...config,
      session: {
        name: session.name,
        email: session.email,
        groups: session.groups,
        ...buildPortalCapabilities(session.groups),
      },
    });
  } catch (error) {
    res
      .status(500)
      .json({ error: error instanceof Error ? error.message : "failed to load portal config" });
  }
});

app.get("/api/preferences", async (req, res) => {
  const session = requireSession(req, res);
  if (!session) {
    return;
  }

  try {
    const allPreferences = await loadPreferences();
    const existing = allPreferences[session.sub] || {};
    res.json({
      theme: existing.theme || "dark",
      language: existing.language || "nl",
      timezone: existing.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,
    });
  } catch (error) {
    res
      .status(500)
      .json({ error: error instanceof Error ? error.message : "failed to load preferences" });
  }
});

function normalizePreferenceInput(body = {}) {
  const theme = String(body.theme || "").trim();
  const language = String(body.language || "").trim();
  const timezone = String(body.timezone || "").trim();

  const next = {};
  if (theme === "light" || theme === "dark") {
    next.theme = theme;
  }
  if (language) {
    next.language = language.slice(0, 32);
  }
  if (timezone) {
    next.timezone = timezone.slice(0, 64);
  }
  return next;
}

app.put("/api/preferences", async (req, res) => {
  const session = requireSession(req, res);
  if (!session) {
    return;
  }

  try {
    const current = await loadPreferences();
    const nextForUser = {
      ...(current[session.sub] || {}),
      ...normalizePreferenceInput(req.body || {}),
      updatedAt: new Date().toISOString(),
    };
    current[session.sub] = nextForUser;
    await savePreferences(current);
    res.json(nextForUser);
  } catch (error) {
    res
      .status(500)
      .json({ error: error instanceof Error ? error.message : "failed to save preferences" });
  }
});

app.get("/api/admin/groups", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    res.json({
      groups: directory.groups,
      generatedAt: new Date().toISOString(),
    });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to load groups" });
  }
});

app.get("/api/admin/apps/catalog", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageApps",
    "app installation access required"
  );
  if (!session) {
    return;
  }

  try {
    const catalog = await requestManagerJson("/api/apps/catalog");
    res.json(catalog);
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to load apps" });
  }
});

app.get("/api/admin/observability", async (req, res) => {
  const session = requireAdminSession(req, res);
  if (!session) {
    return;
  }

  try {
    const { cluster } = await loadActiveClusterState();
    res.json({
      cluster,
      generatedAt: new Date().toISOString(),
    });
  } catch (error) {
    res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to load observability state",
    });
  }
});

app.put("/api/admin/observability", async (req, res) => {
  const session = requireAdminSession(req, res);
  if (!session) {
    return;
  }

  try {
    const { activeCluster } = await loadActiveClusterState();
    const result = await requestManagerJson(
      `/api/clusters/${encodeURIComponent(activeCluster.id)}/observability`,
      {
        method: "PUT",
        body: {
          profile: req.body?.profile,
        },
      }
    );

    res.status(202).json(result);
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to update observability" });
  }
});

app.get("/api/admin/updates", async (req, res) => {
  const session = requireAdminSession(req, res);
  if (!session) return;

  try {
    const { activeCluster } = await loadActiveClusterState();
    res.json(
      await requestManagerJson(`/api/clusters/${encodeURIComponent(activeCluster.id)}/upgrades`)
    );
  } catch (error) {
    res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to load cluster updates",
    });
  }
});

app.post("/api/admin/updates/:action", async (req, res) => {
  const session = requireAdminSession(req, res);
  if (!session) return;

  const action = String(req.params.action || "").trim();
  if (!["refresh", "talos", "kubernetes", "resume", "pause"].includes(action)) {
    return res.status(404).json({ error: "unknown cluster update action" });
  }

  try {
    const { activeCluster } = await loadActiveClusterState();
    const result = await requestManagerJson(
      `/api/clusters/${encodeURIComponent(activeCluster.id)}/upgrades/${action}`,
      { method: "POST", body: req.body || {} }
    );
    res.status(action === "pause" ? 200 : 202).json(result);
  } catch (error) {
    res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to update cluster",
    });
  }
});

app.get("/api/admin/updates/jobs/:jobId", async (req, res) => {
  const session = requireAdminSession(req, res);
  if (!session) return;

  try {
    res.json(await requestManagerJson(`/api/jobs/${encodeURIComponent(req.params.jobId)}`));
  } catch (error) {
    res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to load update job",
    });
  }
});

app.get("/api/admin/updates/jobs/:jobId/logs", async (req, res) => {
  const session = requireAdminSession(req, res);
  if (!session) return;

  try {
    res.json(await requestManagerJson(`/api/jobs/${encodeURIComponent(req.params.jobId)}/logs`));
  } catch (error) {
    res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to load update logs",
    });
  }
});

app.post("/api/admin/apps/:stepId/install", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageApps",
    "app installation access required"
  );
  if (!session) {
    return;
  }

  try {
    const catalog = await requestManagerJson("/api/apps/catalog");
    const activeCluster = catalog?.active_cluster;
    if (!activeCluster?.id) {
      return res.status(404).json({ error: "cluster not found" });
    }

    const result = await requestManagerJson(
      `/api/apps/${encodeURIComponent(req.params.stepId)}/install`,
      {
        method: "POST",
        body: {
          ...(req.body || {}),
          cluster_id: activeCluster.id,
          cluster_instance_id:
            activeCluster.cluster_instance_id || activeCluster.instance_id || null,
        },
      }
    );
    res.status(202).json(result);
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to install app" });
  }
});

app.post("/api/admin/apps/:stepId/uninstall", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageApps",
    "app installation access required"
  );
  if (!session) {
    return;
  }

  try {
    const catalog = await requestManagerJson("/api/apps/catalog");
    const activeCluster = catalog?.active_cluster;
    if (!activeCluster?.id) {
      return res.status(404).json({ error: "cluster not found" });
    }

    const result = await requestManagerJson(
      `/api/apps/${encodeURIComponent(req.params.stepId)}/uninstall`,
      {
        method: "POST",
        body: {
          ...(req.body || {}),
          cluster_id: activeCluster.id,
          cluster_instance_id:
            activeCluster.cluster_instance_id || activeCluster.instance_id || null,
        },
      }
    );
    res.status(202).json(result);
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to uninstall app" });
  }
});

app.get("/api/admin/apps/jobs/:jobId", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageApps",
    "app installation access required"
  );
  if (!session) {
    return;
  }

  try {
    const job = await loadScopedAppJob(req.params.jobId);
    res.json(job);
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to load job" });
  }
});

app.get("/api/admin/apps/jobs/:jobId/logs", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageApps",
    "app installation access required"
  );
  if (!session) {
    return;
  }

  try {
    await loadScopedAppJob(req.params.jobId);
    const logs = await requestManagerJson(`/api/jobs/${encodeURIComponent(req.params.jobId)}/logs`);
    res.json(logs);
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to load job logs" });
  }
});

app.post("/api/admin/apps/jobs/:jobId/cancel", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageApps",
    "app installation access required"
  );
  if (!session) {
    return;
  }

  try {
    await loadScopedAppJob(req.params.jobId);
    const result = await requestManagerJson(
      `/api/jobs/${encodeURIComponent(req.params.jobId)}/cancel`,
      {
        method: "POST",
        body: {},
      }
    );
    res.json(result);
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to cancel job" });
  }
});

async function enrichUsersWithPasskeyStatus(users, client) {
  const enriched = [];
  for (const user of users) {
    try {
      const devices = await client.listWebAuthnDevices(user.id);
      const hasPasskey = Array.isArray(devices?.results) && devices.results.length > 0;
      enriched.push({ ...user, hasPasskey });
    } catch {
      enriched.push({ ...user, hasPasskey: false });
    }
  }
  return enriched;
}

app.get("/api/admin/users", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    const client = getAuthentikAdminClient();
    const users = await enrichUsersWithPasskeyStatus(directory.users, client);
    res.json({
      users,
      groups: directory.groups,
      generatedAt: new Date().toISOString(),
    });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to load users" });
  }
});

app.post("/api/admin/users", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const config = await loadPortalConfig();
    const directoryBefore = await loadUserAdminDirectory(config);
    const draft = normalizeUserDraft(req.body || {});

    ensureRequestedGroupsAreManageable(draft.groupNames, directoryBefore.groups);

    const client = getAuthentikAdminClient();
    const createdUser = await client.createUser({
      username: draft.username,
      name: draft.name,
      ...(draft.email ? { email: draft.email } : {}),
      is_active: true,
      attributes: {
        "twinbox.io/passwordless-onboarding": true,
      },
    });

    const createdUserId = resolveRecordId(createdUser);
    if (!createdUserId) {
      throw new Error("Authentik did not return a user ID");
    }

    const temporaryPassword = createTemporaryPassword();
    await client.setPassword(createdUserId, temporaryPassword);

    for (const group of directoryBefore.groups) {
      if (draft.groupNames.includes(group.name)) {
        await client.addUserToGroup(group.id, createdUserId);
      }
    }

    if (draft.email && isMailuInstalled()) {
      const mailboxPassword = createRandomMailboxPassword();
      mailuCreateMailbox({
        email: draft.email,
        rawPassword: mailboxPassword,
        displayedName: draft.name || draft.username,
      })
        .then((result) => {
          if (result.ok) {
            console.log(`Mailu mailbox created for ${draft.email}`);
          } else {
            console.warn(`Mailu mailbox not created for ${draft.email}: ${result.reason}`);
          }
        })
        .catch((err) =>
          console.warn(`Mailu mailbox creation error for ${draft.email}:`, err.message)
        );
    }

    const directoryAfter = await loadUserAdminDirectory(config);
    res.status(201).json({
      user: buildUserResponse(directoryAfter, createdUserId),
      temporaryPassword,
    });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to create user" });
  }
});

app.post("/api/admin/users/:userId/create-mailbox", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) return;

  try {
    if (!isMailuInstalled()) {
      return res.status(400).json({ error: "Mailu is not installed" });
    }

    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    const user = directory.users.find(
      (u) => u.id === req.params.userId || u.pk === req.params.userId
    );
    if (!user) {
      return res.status(404).json({ error: "User not found" });
    }
    if (!user.email) {
      return res.status(400).json({ error: "User has no email address" });
    }

    const mailboxPassword = createRandomMailboxPassword();
    const result = await mailuCreateMailbox({
      email: user.email,
      rawPassword: mailboxPassword,
      displayedName: user.name || user.username,
    });

    if (result.ok) {
      res.json({ ok: true, email: user.email });
    } else if (result.reason === "already-exists") {
      res.json({ ok: true, email: user.email, note: "Mailbox already exists" });
    } else {
      res.status(500).json({ error: `Failed to create mailbox: ${result.reason}` });
    }
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : "Unknown error" });
  }
});

app.post("/api/admin/users/:userId/restart-passwordless-onboarding", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const client = getAuthentikAdminClient();
    const userId = String(req.params.userId || "").trim();
    const user = await getEligibleUserOrThrow(client, userId);
    const devicesPayload = await client.listWebAuthnDevices(userId);

    for (const device of readListPayload(devicesPayload)) {
      const deviceId = resolveRecordId(device);
      if (deviceId) {
        await client.deleteWebAuthnDevice(deviceId);
      }
    }

    const temporaryPassword = createTemporaryPassword();
    await client.setPassword(userId, temporaryPassword);
    await client.updateUser(userId, {
      attributes: {
        ...(user.attributes || {}),
        "twinbox.io/passwordless-onboarding": true,
      },
    });

    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    res.json({
      user: buildUserResponse(directory, userId),
      temporaryPassword,
    });
  } catch (error) {
    res.status(error?.status || 500).json({
      error: error instanceof Error ? error.message : "failed to restart passwordless onboarding",
    });
  }
});

app.post("/api/admin/users/:userId/disable", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const client = getAuthentikAdminClient();
    const userId = String(req.params.userId || "").trim();
    await getEligibleUserOrThrow(client, userId);
    await client.updateUser(userId, { is_active: false });

    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    res.json({ user: buildUserResponse(directory, userId) });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to disable user" });
  }
});

app.post("/api/admin/users/:userId/enable", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const client = getAuthentikAdminClient();
    const userId = String(req.params.userId || "").trim();
    await getEligibleUserOrThrow(client, userId);
    await client.updateUser(userId, { is_active: true });

    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    res.json({ user: buildUserResponse(directory, userId) });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to reactivate user" });
  }
});

app.put("/api/admin/users/:userId/groups", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const config = await loadPortalConfig();
    const directoryBefore = await loadUserAdminDirectory(config);
    const client = getAuthentikAdminClient();
    const userId = String(req.params.userId || "").trim();
    await getEligibleUserOrThrow(client, userId);

    const requestedGroupNames = normalizeRequestedGroupNames(req.body?.groupNames);
    ensureRequestedGroupsAreManageable(requestedGroupNames, directoryBefore.groups);

    const currentUser = buildUserResponse(directoryBefore, userId);
    const currentGroupNames = new Set(currentUser.groupNames);
    const requestedGroupSet = new Set(requestedGroupNames);

    for (const group of directoryBefore.groups) {
      const shouldHaveGroup = requestedGroupSet.has(group.name);
      const alreadyHasGroup = currentGroupNames.has(group.name);

      if (shouldHaveGroup && !alreadyHasGroup) {
        await client.addUserToGroup(group.id, userId);
      }

      if (!shouldHaveGroup && alreadyHasGroup) {
        await client.removeUserFromGroup(group.id, userId);
      }
    }

    const directoryAfter = await loadUserAdminDirectory(config);
    res.json({ user: buildUserResponse(directoryAfter, userId) });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to update groups" });
  }
});

app.delete("/api/admin/users/:userId", async (req, res) => {
  const session = requirePortalCapability(
    req,
    res,
    "canManageUsers",
    "user management access required"
  );
  if (!session) {
    return;
  }

  try {
    const client = getAuthentikAdminClient();
    const userId = String(req.params.userId || "").trim();
    const user = await getEligibleUserOrThrow(client, userId);

    if (isHiddenPortalUser(user)) {
      const error = new Error("system users cannot be deleted from the portal");
      error.status = 400;
      throw error;
    }

    if (isCurrentSessionUser(session, user)) {
      const error = new Error("you cannot delete your own account");
      error.status = 400;
      throw error;
    }

    await client.deleteUser(userId);
    res.json({ ok: true });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to delete user" });
  }
});

function normalizeUrlForProbe(rawUrl, origin) {
  const value = String(rawUrl || "").trim();
  if (!value) {
    return "";
  }
  if (value.startsWith("/")) {
    return new URL(value, origin).toString();
  }
  return value;
}

async function probeUrl(rawUrl) {
  const targetUrl = rawUrl;
  if (!targetUrl) {
    return { ok: false, status: 0, note: "missing url" };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(new Error("timeout")), 3500);
  try {
    const response = await fetch(targetUrl, {
      method: "GET",
      redirect: "manual",
      signal: controller.signal,
    });
    return {
      ok: response.status < 500,
      status: response.status,
      note: response.status >= 500 ? "server error" : "reachable",
    };
  } catch (error) {
    return {
      ok: false,
      status: 0,
      note: error instanceof Error ? error.message : "unreachable",
    };
  } finally {
    clearTimeout(timeout);
  }
}

function buildStatusSummary(results) {
  const total = results.length;
  const healthy = results.filter((entry) => entry.ok).length;
  const unhealthy = total - healthy;
  let label = "All systems appear healthy";
  if (unhealthy === total && total > 0) {
    label = "Everything needs attention";
  } else if (unhealthy > 0) {
    label = `${healthy}/${total} checks are healthy`;
  }
  return { total, healthy, unhealthy, label };
}

app.get("/api/status", async (req, res) => {
  const session = requireSession(req, res);
  if (!session) {
    return;
  }

  try {
    const config = await loadPortalConfig();
    const origin = getOrigin(req);
    const checks = Array.isArray(config.statusChecks) ? config.statusChecks : [];
    const results = await Promise.all(
      checks.map(async (check) => {
        const probeTarget = normalizeUrlForProbe(check.url, origin);
        const result = await probeUrl(probeTarget);
        return {
          title: check.title,
          description: check.description,
          url: probeTarget,
          accent: check.accent,
          ...result,
        };
      })
    );

    res.json({
      summary: buildStatusSummary(results),
      checks: results,
      generatedAt: new Date().toISOString(),
    });
  } catch (error) {
    res
      .status(500)
      .json({ error: error instanceof Error ? error.message : "failed to build status report" });
  }
});

app.get("/admin", (req, res) => {
  res.redirect(`/auth/login?returnTo=${encodeURIComponent("/admin")}`);
});

app.get("/admin/", (req, res) => {
  res.redirect(`/auth/login?returnTo=${encodeURIComponent("/admin")}`);
});

app.use(express.static(distDir, { extensions: ["html"] }));

app.get(/.*/, async (req, res, next) => {
  if (req.path.startsWith("/api/") || req.path.startsWith("/auth/")) {
    next();
    return;
  }
  const session = getCurrentSession(req);
  if (!session) {
    const returnTo = sanitizeReturnTo(req.originalUrl || req.path || "/");
    res.redirect(`/auth/login?returnTo=${encodeURIComponent(returnTo)}`);
    return;
  }
  try {
    await renderAppShell(req, res);
  } catch (error) {
    next(error);
  }
});

app.use((error, req, res, _next) => {
  res
    .status(500)
    .json({ error: error instanceof Error ? error.message : "unexpected server error" });
});

if (process.env.NODE_ENV !== "test") {
  app.listen(port, () => {
    console.log(`Twinbox portal listening on ${port}`);
  });
}

export { app };
