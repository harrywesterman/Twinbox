import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);

test('app source defines a guided setup shell with compact progress and visible technical details', async () => {
  const source = await readFile(appSourcePath, 'utf8');
  const setupStart = source.indexOf('function SetupShell');
  const manageStart = source.indexOf('function ManageShell');
  const setupSource = setupStart >= 0 && manageStart >= 0 ? source.slice(setupStart, manageStart) : source;
  const manageSource = manageStart >= 0 ? source.slice(manageStart) : source;

  assert.match(source, /mission\.mode === 'setup'/, 'expected a setup branch in the app source');
  assert.match(source, /Let's deploy a Twinbox cluster/, 'expected setup-oriented loading copy');
  assert.match(source, /Follow the steps below to set up the cluster\./, 'expected setup-oriented loading guidance');
  assert.match(source, /className="setup-progress-rail"/, 'expected a compact setup progress rail');
  assert.match(source, /className="setup-workspace"/, 'expected a dominant setup workspace');
  assert.match(source, /Technical details/, 'expected technical details to remain visible');
  assert.match(source, /<details className="technical-panel" open>/, 'expected technical details to be open by default');
  assert.match(manageSource, /className="[^"]*workspace-panel[^"]*manage-workspace[^"]*"/, 'expected manage fallback to keep the workspace-panel contract alive');
  assert.match(manageSource, /manage-workspace/, 'expected a manage-mode fallback marker');
  assert.match(manageSource, /className="activity-panel"/, 'expected the manage fallback to keep the legacy sidebar surface');
  assert.doesNotMatch(setupSource, /Previous/, 'setup mode should not show a Previous button');
  assert.match(source, /journey-rail-toggle/, 'expected a mobile rail toggle control');
  assert.match(source, /fetch\('\/api\/catalog'\)/, 'expected catalog discovery from the backend');
  assert.match(source, /executeStep/, 'expected a catalog-driven step execution handler');
});

test('styles define a setup-first shell and preserve the manage fallback styles', async () => {
  const css = await readFile(appStylesPath, 'utf8');

  assert.match(css, /\.setup-shell\s*\{/, 'expected a dedicated setup shell container');
  assert.match(css, /\.setup-grid\s*\{/, 'expected setup layout columns');
  assert.match(css, /\.setup-progress-rail\s*\{/, 'expected a compact setup progress rail');
  assert.match(css, /\.setup-workspace\s*\{/, 'expected a dominant setup workspace');
  assert.match(css, /\.technical-panel\[open\]\s*\{/, 'expected open technical details styling');
  assert.match(css, /\.manage-workspace\s*\{/, 'expected the manage fallback workspace to remain styled');
  assert.match(css, /\.workspace-panel\s*\{/, 'expected the legacy workspace-panel contract to remain styled');
  assert.match(css, /\.mission-grid\s*\{[\s\S]*grid-template-columns:/, 'expected mission control columns in CSS');
  assert.match(css, /\.runtime-strip\s*\{/, 'expected styling for the live runtime strip');
  assert.match(css, /\.runtime-pulse\s*\{/, 'expected a pulse indicator for live execution');
  assert.match(css, /\.timeline-list\s*\{/, 'expected styling for the visible timeline');
  assert.match(css, /\.journey-rail-toggle\s*\{/, 'expected a mobile toggle style for the journey rail');
  assert.match(css, /\.activity-panel\s*\{/, 'expected styling for the activity panel');
  assert.match(css, /@media\s*\(max-width:\s*1100px\)/, 'expected a tablet breakpoint for rail and activity rearrangement');
});
