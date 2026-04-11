import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { STEP_ICON_MANIFEST } from '../src/assets/step-icons/manifest.js';

const iconsDir = new URL('../src/assets/step-icons/', import.meta.url);

function readPngDimensions(buffer) {
  assert.equal(buffer.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', 'expected a PNG signature');
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20),
  };
}

test('step icon manifest keeps the wizard icon set complete and paired', async () => {
  assert.ok(STEP_ICON_MANIFEST.length >= 30, 'expected the manifest to cover the wizard step icons');

  const seen = new Set();

  for (const entry of STEP_ICON_MANIFEST) {
    assert.ok(entry.stepId, 'expected each manifest item to declare a step id');
    assert.ok(entry.fileBase, `expected a file base for ${entry.stepId}`);
    assert.ok(entry.sourceKind, `expected a source kind for ${entry.stepId}`);
    assert.ok(!seen.has(entry.stepId), `expected unique step ids, got ${entry.stepId} twice`);
    seen.add(entry.stepId);

    const svgUrl = new URL(`${entry.fileBase}.svg`, iconsDir);
    const pngUrl = new URL(`${entry.fileBase}.png`, iconsDir);

    const [svgText, pngBytes] = await Promise.all([
      readFile(svgUrl, 'utf8'),
      readFile(pngUrl),
    ]);

    assert.match(svgText, /<svg/i, `expected ${entry.fileBase}.svg to be an SVG`);

    const { width, height } = readPngDimensions(pngBytes);
    assert.ok(width >= 128, `expected ${entry.fileBase}.png to be a high-resolution render`);
    assert.ok(height >= 128, `expected ${entry.fileBase}.png to be a high-resolution render`);
  }

  assert.ok(seen.has('install-prometheus'), 'expected a branded Prometheus icon');
  assert.ok(seen.has('install-loki'), 'expected a branded Loki icon');
  assert.ok(seen.has('install-zulip'), 'expected a Zulip SVG replacement');
});

