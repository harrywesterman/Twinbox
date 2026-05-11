import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import path from "node:path";

const file = fileURLToPath(import.meta.url);
const dir = path.dirname(file);
const configPath = path.resolve(dir, "..", "nginx.conf");

test("nginx proxies api requests through docker dns resolution", () => {
  const source = readFileSync(configPath, "utf8");
  assert.match(source, /resolver 127\.0\.0\.11 ipv6=off valid=10s;/);
  assert.match(source, /set \$manager_api manager-api:8080;/);
  assert.match(source, /proxy_pass http:\/\/\$manager_api;/);
});
