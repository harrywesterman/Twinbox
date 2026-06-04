import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { STEP_ICON_MANIFEST } from "../src/assets/step-icons/manifest.js";

const iconsDir = new URL("../src/assets/step-icons/", import.meta.url);
const webPublicIconsDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../public/assets/step-icons"
);
const portalPublicIconsDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../portal/public/assets/step-icons"
);

function readPngDimensions(buffer) {
  assert.equal(
    buffer.subarray(0, 8).toString("hex"),
    "89504e470d0a1a0a",
    "expected a PNG signature"
  );
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20),
  };
}

test("step icon manifest keeps the wizard icon set complete and paired", async () => {
  assert.ok(
    STEP_ICON_MANIFEST.length >= 30,
    "expected the manifest to cover the wizard step icons"
  );

  const seen = new Set();

  for (const entry of STEP_ICON_MANIFEST) {
    assert.ok(entry.stepId, "expected each manifest item to declare a step id");
    assert.ok(entry.fileBase, `expected a file base for ${entry.stepId}`);
    assert.ok(entry.sourceKind, `expected a source kind for ${entry.stepId}`);
    assert.equal(
      entry.sourceKind,
      "local-svg",
      `expected ${entry.stepId} to be pinned as local svg`
    );
    assert.ok(!seen.has(entry.stepId), `expected unique step ids, got ${entry.stepId} twice`);
    seen.add(entry.stepId);
    assert.equal(
      entry.sourceFile,
      `./${entry.fileBase}.svg`,
      `expected ${entry.stepId} to resolve to local svg path`
    );

    if (entry.isAppOrPlatform) {
      assert.ok(
        entry.officialSourceType,
        `expected ${entry.stepId} app/platform icon to define officialSourceType`
      );
      assert.ok(
        entry.officialSourceUrl,
        `expected ${entry.stepId} app/platform icon to define officialSourceUrl`
      );
      assert.match(
        entry.officialSourceUrl,
        /^https?:\/\//,
        `expected ${entry.stepId} officialSourceUrl to be absolute`
      );
    }

    const svgUrl = new URL(`${entry.fileBase}.svg`, iconsDir);
    const pngUrl = new URL(`${entry.fileBase}.png`, iconsDir);
    const webPublicSvgPath = path.join(webPublicIconsDir, `${entry.fileBase}.svg`);
    const portalPublicSvgPath = path.join(portalPublicIconsDir, `${entry.fileBase}.svg`);

    const [svgText, pngBytes] = await Promise.all([readFile(svgUrl, "utf8"), readFile(pngUrl)]);
    const [webPublicSvgText, portalPublicSvgText] = await Promise.all([
      readFile(webPublicSvgPath, "utf8"),
      readFile(portalPublicSvgPath, "utf8"),
    ]);

    assert.match(svgText, /<svg/i, `expected ${entry.fileBase}.svg to be an SVG`);
    const svgRootMatch = svgText.match(/<svg\b[^>]*>/i);
    assert.ok(svgRootMatch, `expected ${entry.fileBase}.svg to include an svg root tag`);
    assert.doesNotMatch(
      svgRootMatch[0],
      /\swidth\s*=/i,
      `expected ${entry.fileBase}.svg root to omit width attr`
    );
    assert.doesNotMatch(
      svgRootMatch[0],
      /\sheight\s*=/i,
      `expected ${entry.fileBase}.svg root to omit height attr`
    );
    assert.equal(
      webPublicSvgText,
      svgText,
      `expected manager-web public ${entry.fileBase}.svg to match the source asset`
    );
    assert.equal(
      portalPublicSvgText,
      svgText,
      `expected portal public ${entry.fileBase}.svg to match the source asset`
    );

    const { width, height } = readPngDimensions(pngBytes);
    assert.ok(width >= 128, `expected ${entry.fileBase}.png to be a high-resolution render`);
    assert.ok(height >= 128, `expected ${entry.fileBase}.png to be a high-resolution render`);
  }

  assert.ok(seen.has("install-prometheus"), "expected a branded Prometheus icon");
  assert.ok(seen.has("install-loki"), "expected a branded Loki icon");
  assert.ok(seen.has("install-beszel"), "expected a branded Beszel icon");
  assert.ok(seen.has("install-zulip"), "expected a Zulip SVG replacement");
});
