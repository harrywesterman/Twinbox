import crypto from "crypto";
import fs from "fs";
import path from "path";
import express from "express";
import { createRemoteJWKSet, jwtVerify } from "jose";

const app = express();
const port = Number(process.env.PORT || 8080);
const dataDir = process.env.PORTAL_DATA_DIR || "/data";
const configPath = process.env.PORTAL_CONFIG_PATH || "/config/portal-config.json";
const sessionSecret = process.env.PORTAL_SESSION_SECRET || "twinbox-portal-dev-secret";
const sessionCookieName = process.env.PORTAL_SESSION_COOKIE || "twinbox_portal_session";
const oauthCookieName = process.env.PORTAL_OAUTH_COOKIE || "twinbox_portal_oauth";
const issuer = String(process.env.PORTAL_OIDC_ISSUER || process.env.AUTHENTIK_ISSUER || "").trim();
const clientId = String(process.env.PORTAL_OIDC_CLIENT_ID || "").trim();

fs.mkdirSync(dataDir, { recursive: true });

app.disable("x-powered-by");
app.set("trust proxy", 1);
app.use(express.json({ limit: "1mb" }));

const distDir = path.join(process.cwd(), "dist");
const indexHtmlPath = path.join(distDir, "index.html");
const preferencesPath = path.join(dataDir, "preferences.json");

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

function cookieOptions(req, { maxAge = null } = {}) {
  const secure = String(req.headers["x-forwarded-proto"] || "").includes("https");
  return [
    "Path=/",
    "HttpOnly",
    "SameSite=Lax",
    secure ? "Secure" : null,
    maxAge ? `Max-Age=${Math.floor(maxAge / 1000)}` : null,
  ].filter(Boolean).join("; ");
}

function setCookie(res, req, name, value, options = {}) {
  res.setHeader("Set-Cookie", [
    ...(Array.isArray(res.getHeader("Set-Cookie")) ? res.getHeader("Set-Cookie") : res.getHeader("Set-Cookie") ? [res.getHeader("Set-Cookie")] : []),
    `${name}=${encodeURIComponent(value)}; ${cookieOptions(req, options)}`,
  ]);
}

function clearCookie(res, req, name) {
  res.setHeader("Set-Cookie", [
    ...(Array.isArray(res.getHeader("Set-Cookie")) ? res.getHeader("Set-Cookie") : res.getHeader("Set-Cookie") ? [res.getHeader("Set-Cookie")] : []),
    `${name}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${String(req.headers["x-forwarded-proto"] || "").includes("https") ? "; Secure" : ""}`,
  ]);
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
  return readJsonFile(configPath, {
    portal: {
      brand: "Twinbox",
      hero: {
        eyebrow: "User portal",
        title: "Twinbox",
        description: "Log in to open your cluster apps.",
      },
    },
    settings: {},
    apps: [],
    adminApps: [],
    intranetLinks: [],
    statusChecks: [],
  });
}

async function loadPreferences() {
  return readJsonFile(preferencesPath, {});
}

async function savePreferences(nextPreferences) {
  await fs.promises.mkdir(path.dirname(preferencesPath), { recursive: true });
  await writeJsonFile(preferencesPath, nextPreferences);
}

function getOrigin(req) {
  const proto = String(req.headers["x-forwarded-proto"] || "http").split(",")[0].trim() || "http";
  const host = String(req.headers["x-forwarded-host"] || req.headers.host || "").split(",")[0].trim();
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

async function discoverIssuer() {
  if (cachedDiscovery) {
    return cachedDiscovery;
  }
  if (!issuer) {
    throw new Error("PORTAL_OIDC_ISSUER is not configured");
  }

  const response = await fetch(new URL(".well-known/openid-configuration", issuer.endsWith("/") ? issuer : `${issuer}/`));
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

  return {
    sub: String(claims?.sub || "").trim(),
    name: String(claims?.name || claims?.preferred_username || claims?.email || "Twinbox user").trim(),
    email: String(claims?.email || "").trim(),
    preferredUsername: String(claims?.preferred_username || "").trim(),
    groups,
    isAdmin: groups.includes("admins"),
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

    setCookie(res, req, oauthCookieName, encodeSignedJson({
      state,
      codeVerifier,
      nonce,
      returnTo,
      createdAt: Date.now(),
    }), { maxAge: 10 * 60 * 1000 });

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
  try {
    const cookies = readCookies(req);
    const oauthState = decodeSignedJson(cookies[oauthCookieName]);
    if (!oauthState?.state || oauthState.state !== String(req.query.state || "")) {
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

    setCookie(res, req, sessionCookieName, encodeSignedJson({
      ...session,
      tokenType: tokenResponse.token_type || "Bearer",
      createdAt: Date.now(),
    }), { maxAge: 7 * 24 * 60 * 60 * 1000 });
    clearCookie(res, req, oauthCookieName);
    res.redirect(oauthState.returnTo || "/");
  } catch (error) {
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
  return res.json({ ok: true, session });
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
        isAdmin: session.isAdmin,
      },
    });
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : "failed to load portal config" });
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
    res.status(500).json({ error: error instanceof Error ? error.message : "failed to load preferences" });
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
    res.status(500).json({ error: error instanceof Error ? error.message : "failed to save preferences" });
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
    const results = await Promise.all(checks.map(async (check) => {
      const probeTarget = normalizeUrlForProbe(check.url, origin);
      const result = await probeUrl(probeTarget);
      return {
        title: check.title,
        description: check.description,
        url: probeTarget,
        accent: check.accent,
        ...result,
      };
    }));

    res.json({
      summary: buildStatusSummary(results),
      checks: results,
      generatedAt: new Date().toISOString(),
    });
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : "failed to build status report" });
  }
});

app.use(express.static(distDir, { extensions: ["html"] }));

app.get(/.*/, async (req, res, next) => {
  if (req.path.startsWith("/api/") || req.path.startsWith("/auth/")) {
    next();
    return;
  }
  try {
    await renderAppShell(req, res);
  } catch (error) {
    next(error);
  }
});

app.use((error, req, res, _next) => {
  res.status(500).json({ error: error instanceof Error ? error.message : "unexpected server error" });
});

app.listen(port, () => {
  console.log(`Twinbox portal listening on ${port}`);
});
