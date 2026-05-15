import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const portalContentPath = path.join(repoRoot, "config", "portal", "content.json");

test("portal documentation tile points at the MkDocs site", () => {
  const content = JSON.parse(fs.readFileSync(portalContentPath, "utf8"));
  const docsTile = content.links.find((link) => link.icon === "support-docs");

  assert.ok(docsTile, "expected a support-docs portal tile");
  assert.equal(docsTile.title, "Documentation");
  assert.equal(docsTile.url, "https://harrywesterman.github.io/Twinbox/");
});
