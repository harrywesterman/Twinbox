import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

let mailuApiBase;
let mailuServer;
let lastRequest;

function startMailuMock() {
  return new Promise((resolve) => {
    mailuServer = http.createServer((req, res) => {
      lastRequest = { method: req.method, url: req.url, headers: req.headers, body: "" };
      req.on("data", (chunk) => {
        lastRequest.body += chunk;
      });
      req.on("end", () => {
        if (req.url === "/api/v1/user" && req.method === "POST") {
          try {
            const payload = JSON.parse(lastRequest.body);
            if (payload.email === "existing@test.com") {
              res.writeHead(409, { "Content-Type": "application/json" });
              res.end(JSON.stringify({ code: 409, message: "Duplicate user" }));
            } else {
              res.writeHead(200, { "Content-Type": "application/json" });
              res.end(JSON.stringify({ code: 200, message: "ok" }));
            }
          } catch {
            res.writeHead(400, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ code: 400, message: "Bad request" }));
          }
        } else if (req.url === "/api/v1/user/admin%40test.com" && req.method === "GET") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ email: "admin@test.com" }));
        } else if (req.url.startsWith("/api/v1/user/") && req.method === "GET") {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ code: 404, message: "Not found" }));
        } else {
          res.writeHead(404);
          res.end("{}");
        }
      });
    });
    mailuServer.listen(0, "127.0.0.1", () => {
      const addr = mailuServer.address();
      mailuApiBase = `http://127.0.0.1:${addr.port}/api`;
      resolve();
    });
  });
}

async function importMailuClient() {
  const moduleUrl = `${pathToFileURL(path.join(repoRoot, "portal", "mailu-client.mjs")).href}?test=${Date.now()}`;
  return import(moduleUrl);
}

test.before(async () => {
  await startMailuMock();
});

test.after(() => {
  if (mailuServer) {
    mailuServer.close();
  }
});

test("createRandomMailboxPassword returns 48 hex chars", async () => {
  const { createRandomMailboxPassword } = await importMailuClient();
  const pwd = createRandomMailboxPassword();
  assert.equal(pwd.length, 48);
  assert.match(pwd, /^[0-9a-f]+$/);
  const pwd2 = createRandomMailboxPassword();
  assert.notEqual(pwd, pwd2);
});

test("resolveMailuApiConfig returns correct base URL and token with explicit env", async () => {
  process.env.MAILU_API_BASE_URL = "https://mail.test.example/api";
  process.env.MAILU_API_TOKEN = "test-token-abc";
  const { resolveMailuApiConfig } = await importMailuClient();
  const cfg = resolveMailuApiConfig();
  assert.equal(cfg.baseUrl, "https://mail.test.example/api/v1");
  assert.equal(cfg.token, "test-token-abc");
  delete process.env.MAILU_API_TOKEN;
  delete process.env.MAILU_API_BASE_URL;
});

test("resolveMailuApiConfig derives base URL from PORTAL_BASE_URL when MAILU_API_BASE_URL is unset", async () => {
  process.env.PORTAL_BASE_URL = "https://portal.bierineenweek.nl";
  process.env.MAILU_API_TOKEN = "test-token-abc";
  delete process.env.MAILU_API_BASE_URL;
  const { resolveMailuApiConfig } = await importMailuClient();
  const cfg = resolveMailuApiConfig();
  assert.equal(cfg.baseUrl, "https://mail.bierineenweek.nl/api/v1");
  assert.equal(cfg.token, "test-token-abc");
  delete process.env.MAILU_API_TOKEN;
  delete process.env.PORTAL_BASE_URL;
});

test("resolveMailuApiConfig returns empty baseUrl when nothing is set", async () => {
  delete process.env.MAILU_API_BASE_URL;
  delete process.env.PORTAL_BASE_URL;
  delete process.env.MAILU_API_TOKEN;
  const { resolveMailuApiConfig } = await importMailuClient();
  const cfg = resolveMailuApiConfig();
  assert.equal(cfg.baseUrl, "/v1");
  assert.equal(cfg.token, "");
});

test("isMailuInstalled returns true when token is set", async () => {
  process.env.MAILU_API_TOKEN = "some-token";
  const { isMailuInstalled } = await importMailuClient();
  assert.equal(isMailuInstalled(), true);
  delete process.env.MAILU_API_TOKEN;
});

test("isMailuInstalled returns false when token is empty", async () => {
  process.env.MAILU_API_TOKEN = "";
  const { isMailuInstalled } = await importMailuClient();
  assert.equal(isMailuInstalled(), false);
  delete process.env.MAILU_API_TOKEN;
});

test("isMailuInstalled returns false when token is unset", async () => {
  delete process.env.MAILU_API_TOKEN;
  const { isMailuInstalled } = await importMailuClient();
  assert.equal(isMailuInstalled(), false);
});

test("mailuCreateMailbox succeeds for new user", async () => {
  process.env.MAILU_API_BASE_URL = mailuApiBase;
  process.env.MAILU_API_TOKEN = "test-token";
  const { mailuCreateMailbox } = await importMailuClient();
  const result = await mailuCreateMailbox({
    email: "new@test.com",
    rawPassword: "abc123",
    displayedName: "Test User",
  });
  assert.equal(result.ok, true);
  assert.equal(lastRequest.method, "POST");
  assert.equal(lastRequest.url, "/api/v1/user");
});

test("mailuCreateMailbox returns exists for duplicate", async () => {
  const { mailuCreateMailbox } = await importMailuClient();
  const result = await mailuCreateMailbox({
    email: "existing@test.com",
    rawPassword: "abc123",
    displayedName: "Test User",
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "already-exists");
});

test("mailuCreateMailbox returns no-api-token when token is empty", async () => {
  process.env.MAILU_API_BASE_URL = mailuApiBase;
  process.env.MAILU_API_TOKEN = "";
  const { mailuCreateMailbox } = await importMailuClient();
  const result = await mailuCreateMailbox({
    email: "new@test.com",
    rawPassword: "abc123",
    displayedName: "Test User",
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "no-api-token");
  delete process.env.MAILU_API_TOKEN;
});

test("mailuCheckMailboxExists returns true for existing", async () => {
  process.env.MAILU_API_BASE_URL = mailuApiBase;
  process.env.MAILU_API_TOKEN = "test-token";
  const { mailuCheckMailboxExists } = await importMailuClient();
  const result = await mailuCheckMailboxExists("admin@test.com");
  assert.equal(result, true);
});

test("mailuCheckMailboxExists returns false for missing", async () => {
  const { mailuCheckMailboxExists } = await importMailuClient();
  const result = await mailuCheckMailboxExists("nobody@test.com");
  assert.equal(result, false);
});
