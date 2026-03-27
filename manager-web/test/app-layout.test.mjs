import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);
const viteConfigPath = new URL('../vite.config.js', import.meta.url);
const indexHtmlPath = new URL('../index.html', import.meta.url);

test('app source defines a wizard shell with export, import, and technical output controls', async () => {
  const source = await readFile(appSourcePath, 'utf8');

  assert.match(source, /className="wizard-shell"/, 'expected the wizard shell');
  assert.match(source, /className="wizard-rail"/, 'expected the installation step rail');
  assert.match(source, /className="wizard-flow"/, 'expected the stacked setup flow');
  assert.match(source, /Export all answers/, 'expected export support');
  assert.match(source, /Import all answers/, 'expected import support');
  assert.match(source, /Install all steps/, 'expected bulk install action');
  assert.match(source, /type="range"/, 'expected the scale slider');
  assert.match(source, /wizard-scale-panel/, 'expected the cluster scale summary');
  assert.match(source, /1\. VM sizing/, 'expected sizing to come first');
  assert.match(source, /VM landing/, 'expected the VM placement block to be explicit');
  assert.match(source, /wizard-placement-board/, 'expected the host placement board');
  assert.match(source, /Retry balanced suggestion/, 'expected a rebalance retry action');
  assert.match(source, /live running VMs/, 'expected live VM-aware placement wording');
  assert.match(source, /3\. Network and addressing/, 'expected networking to come after placement');
  assert.match(source, /wizard-network-summary/, 'expected a compact network summary');
  assert.match(source, /className="technical-panel" open/, 'expected technical details to be visible by default');
  assert.match(source, /LIVE OUTPUT/, 'expected a visible output panel');
  assert.match(source, /Deploy Talos Cluster/, 'expected the Talos bootstrap step label');
  assert.match(source, /CURRENT STEP/, 'expected the current step to be shown first');
  assert.doesNotMatch(source, /Explore Twinbox/, 'should no longer read like a landing page');
});

test('styles define a wizard-first, responsive installer layout', async () => {
  const css = await readFile(appStylesPath, 'utf8');

  assert.match(css, /\.wizard-shell\s*\{/, 'expected wizard shell styling');
  assert.match(css, /\.wizard-layout\s*\{/, 'expected wizard layout grid');
  assert.match(css, /\.wizard-rail\s*\{/, 'expected the setup rail');
  assert.match(css, /\.wizard-workspace\s*\{/, 'expected the workspace');
  assert.match(css, /\.wizard-flow\s*\{/, 'expected the stacked active-step/output surface');
  assert.match(css, /\.wizard-output-panel\.is-live\s*\{/, 'expected live output emphasis');
  assert.match(css, /\.technical-panel\[open\]\s*\{/, 'expected technical details to stay open');
  assert.match(css, /\.technical-panel-grid\s*\{[\s\S]*grid-template-columns:\s*minmax\(0,\s*1fr\);/, 'expected technical output to span the full width');
  assert.match(css, /\.wizard-log-output\s*\{[\s\S]*min-height:\s*420px;/, 'expected a wide script output panel');
  assert.match(css, /\.wizard-scale-panel\s*\{/, 'expected the cluster scale summary');
  assert.match(css, /\.wizard-field input\[type='range'\]\s*\{/, 'expected the range slider styling');
  assert.doesNotMatch(css, /\.wizard-risk-list\s*\{/, 'expected current risks to be removed');
  assert.match(css, /@media \(max-width:\s*1200px\)/, 'expected large-tablet responsiveness');
  assert.match(css, /@media \(max-width:\s*720px\)/, 'expected mobile responsiveness');
});

test('vite and document metadata still support relative hosting', async () => {
  const viteConfig = await readFile(viteConfigPath, 'utf8');
  const indexHtml = await readFile(indexHtmlPath, 'utf8');

  assert.match(viteConfig, /base:\s*'\.\/'/, 'expected relative asset paths');
  assert.match(indexHtml, /lang="en"/, 'expected English language metadata');
  assert.match(indexHtml, /Twinbox Web Installation Wizard/, 'expected the wizard title');
});
