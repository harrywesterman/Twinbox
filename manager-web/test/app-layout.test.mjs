import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);

test('app source defines a hero, dashboard grid, and detached log panel', async () => {
  const source = await readFile(appSourcePath, 'utf8');

  assert.match(source, /className="hero"/, 'expected a hero section for control-plane context');
  assert.match(source, /className="dashboard-grid"/, 'expected a dedicated dashboard grid for the main cards');
  assert.match(source, /className="card log-panel"/, 'expected logs to render in a dedicated full-width panel');

  const dashboardIndex = source.indexOf('className="dashboard-grid"');
  const logPanelIndex = source.indexOf('className="card log-panel"');

  assert.ok(dashboardIndex >= 0, 'expected dashboard grid markup');
  assert.ok(logPanelIndex > dashboardIndex, 'expected log panel to render after the dashboard grid');
});

test('styles define a split dashboard layout and a taller console treatment', async () => {
  const css = await readFile(appStylesPath, 'utf8');

  assert.match(css, /\.dashboard-grid\s*\{[\s\S]*grid-template-columns:/, 'expected dashboard grid columns in CSS');
  assert.match(css, /\.log-panel pre\s*\{[\s\S]*min-height:\s*320px;/, 'expected taller log console styling');
  assert.match(css, /@media\s*\(max-width:\s*960px\)/, 'expected a responsive breakpoint for stacked layout');
});
