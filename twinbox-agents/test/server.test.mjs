import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-agents-test-"));
const token = "test-internal-token-abc123";

process.env.TWINBOX_AGENT_INTERNAL_TOKEN = token;
process.env.AGENT_DATA_DIR = dataDir;
process.env.PORT = "0";

let baseUrl;
let server;

test.before(async () => {
  const mod = await import("../src/server.mjs");
  const app = mod.app;
  await new Promise((resolve) => {
    server = app.listen(0, () => {
      baseUrl = `http://127.0.0.1:${server.address().port}`;
      resolve();
    });
  });
});

test.after(() => {
  server?.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
});

function request(pathname, options = {}) {
  return new Promise((resolve, reject) => {
    const url = `${baseUrl}${pathname}`;
    const headers = { ...options.headers };

    if (options.token) {
      headers["Authorization"] = `Bearer ${options.token}`;
    }

    if (options.body) {
      headers["Content-Type"] = "application/json";
    }

    const req = http.request(
      url,
      {
        method: options.method || "GET",
        headers,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let body;
          try {
            body = text ? JSON.parse(text) : null;
          } catch {
            body = text;
          }
          resolve({ status: res.statusCode, body, headers: res.headers });
        });
      }
    );

    req.on("error", reject);

    if (options.body) {
      req.write(JSON.stringify(options.body));
    }

    req.end();
  });
}

test("GET /api/health returns ok without token", async () => {
  const res = await request("/api/health");
  assert.equal(res.status, 200);
  assert.equal(res.body.status, "ok");
  assert.equal(res.body.version, "1.0.0");
});

test("protected endpoint without token returns 401", async () => {
  const res = await request("/api/agents");
  assert.equal(res.status, 401);
});

test("protected endpoint with wrong token returns 401", async () => {
  const res = await request("/api/agents", { token: "wrong-token" });
  assert.equal(res.status, 403);
});

test("GET /api/agents returns all agents", async () => {
  const res = await request("/api/agents", { token });
  assert.equal(res.status, 200);
  assert.ok(Array.isArray(res.body));
  assert.equal(res.body.length, 7);
});

test("GET /api/providers returns config without api key", async () => {
  const res = await request("/api/providers", { token });
  assert.equal(res.status, 200);
  assert.equal(res.body.hasApiKey, false);
  assert.equal(res.body.apiKey, undefined);
});

test("GET /api/events returns empty array initially", async () => {
  const res = await request("/api/events", { token });
  assert.equal(res.status, 200);
  assert.ok(Array.isArray(res.body));
});

test("POST /api/work-orders creates work order", async () => {
  const res = await request("/api/work-orders", {
    method: "POST",
    token,
    body: {
      type: "cluster_health_check",
      title: "Test cluster check",
    },
  });
  assert.equal(res.status, 201);
  assert.ok(res.body.id);
  assert.equal(res.body.type, "cluster_health_check");
});

test("POST /api/work-orders with unknown type returns 400", async () => {
  const res = await request("/api/work-orders", {
    method: "POST",
    token,
    body: {
      type: "unknown_type",
      title: "Test",
    },
  });
  assert.equal(res.status, 400);
});

test("GET /api/work-orders returns list", async () => {
  const res = await request("/api/work-orders", { token });
  assert.equal(res.status, 200);
  assert.ok(Array.isArray(res.body));
});

test("POST /api/providers/test returns result", async () => {
  const res = await request("/api/providers/test", {
    method: "POST",
    token,
    body: {
      baseUrl: "http://127.0.0.1:9999/v1",
      model: "test",
      timeoutMs: 1000,
    },
  });
  assert.equal(res.status, 200);
  assert.ok(res.body.status);
});
