import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);

test('app source defines a guided setup shell with compact progress and visible technical details', async () => {
  const source = await readFile(appSourcePath, 'utf8');

  assert.match(source, /mission\.mode === 'setup'/, 'expected a setup branch in the app source');
  assert.match(source, /className="setup-progress-rail"/, 'expected a compact setup progress rail');
  assert.match(source, /className="setup-workspace"/, 'expected a dominant setup workspace');
  assert.match(source, /Technical details/, 'expected technical details to remain visible');
  assert.match(source, /<details className="technical-panel" open>/, 'expected technical details to be open by default');
  assert.match(source, /className="manage-workspace"/, 'expected a manage-mode fallback branch');
  assert.match(source, /journey-rail-toggle/, 'expected a mobile rail toggle control');
  assert.match(source, /fetch\('\/api\/catalog'\)/, 'expected catalog discovery from the backend');
  assert.match(source, /executeStep/, 'expected a catalog-driven step execution handler');
});

test('styles define a three-column mission control grid, runtime strip, and responsive rail behavior', async () => {
  const css = await readFile(appStylesPath, 'utf8');

  assert.match(css, /\.mission-grid\s*\{[\s\S]*grid-template-columns:/, 'expected mission control columns in CSS');
  assert.match(css, /\.runtime-strip\s*\{/, 'expected styling for the live runtime strip');
  assert.match(css, /\.runtime-pulse\s*\{/, 'expected a pulse indicator for live execution');
  assert.match(css, /\.timeline-list\s*\{/, 'expected styling for the visible timeline');
  assert.match(css, /\.journey-rail-toggle\s*\{/, 'expected a mobile toggle style for the journey rail');
  assert.match(css, /\.activity-panel\s*\{/, 'expected styling for the activity panel');
  assert.match(css, /@media\s*\(max-width:\s*1100px\)/, 'expected a tablet breakpoint for rail and activity rearrangement');
});
