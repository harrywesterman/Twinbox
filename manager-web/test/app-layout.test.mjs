import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);

test('app source defines the mission control header, rail, workspace, and activity panels', async () => {
  const source = await readFile(appSourcePath, 'utf8');

  assert.match(source, /className="global-header"/, 'expected a global header for install progress and health');
  assert.match(source, /className="journey-rail"/, 'expected a dedicated phase rail');
  assert.match(source, /className="workspace-panel"/, 'expected a central active-step workspace');
  assert.match(source, /className="activity-panel"/, 'expected a dedicated activity panel');
  assert.match(source, /journey-rail-toggle/, 'expected a mobile rail toggle control');
  assert.match(source, /fetch\('\/api\/catalog'\)/, 'expected catalog discovery from the backend');
  assert.match(source, /executeStep/, 'expected a catalog-driven step execution handler');
});

test('styles define a three-column mission control grid and responsive rail behavior', async () => {
  const css = await readFile(appStylesPath, 'utf8');

  assert.match(css, /\.mission-grid\s*\{[\s\S]*grid-template-columns:/, 'expected mission control columns in CSS');
  assert.match(css, /\.journey-rail-toggle\s*\{/, 'expected a mobile toggle style for the journey rail');
  assert.match(css, /\.activity-panel\s*\{/, 'expected styling for the activity panel');
  assert.match(css, /@media\s*\(max-width:\s*1100px\)/, 'expected a tablet breakpoint for rail and activity rearrangement');
});
