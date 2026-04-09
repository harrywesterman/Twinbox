import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const helperSourcePath = new URL('../src/step-presentation.js', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);
const viteConfigPath = new URL('../vite.config.js', import.meta.url);
const indexHtmlPath = new URL('../index.html', import.meta.url);

test('app source defines a minimal wizard shell with guided input and step-by-step install controls', async () => {
  const source = await readFile(appSourcePath, 'utf8');

  assert.match(source, /className="wizard-shell"/, 'expected the wizard shell');
  assert.match(source, /wizard-layout-minimal/, 'expected a minimal wizard layout');
  assert.match(source, /wizard-flow-minimal/, 'expected the stacked setup flow');
  assert.match(source, /className="wizard-start-screen"/, 'expected a start screen');
  assert.match(source, /wizard-guide-panel/, 'expected an educational guide panel');
  assert.match(source, /wizard-choice-grid/, 'expected route choices to render as cards');
  assert.match(source, /Previous/, 'expected back navigation');
  assert.match(source, /{primaryActionLabel}/, 'expected the forward action label');
  assert.match(source, /Continue to installation/, 'expected the last question to lead into the install phase');
  assert.match(source, /Install all/, 'expected an install-all action in the install phase');
  assert.match(source, /Reinstall/, 'expected reinstall controls for install steps');
  assert.match(source, /type="range"/, 'expected the scale slider');
  assert.match(source, /1\. VM sizing/, 'expected sizing to come first');
  assert.match(source, /VM landing/, 'expected the VM placement block to be explicit');
  assert.match(source, /wizard-placement-board/, 'expected the host placement board');
  assert.match(source, /Retry balanced suggestion/, 'expected a rebalance retry action');
  assert.match(source, /live running VMs/, 'expected live VM-aware placement wording');
  assert.match(source, /3\. Network and addressing/, 'expected networking to come after placement');
  assert.match(source, /wizard-network-summary/, 'expected a compact network summary');
  assert.match(source, /Per-VM IPs/, 'expected a per-VM IP list');
  assert.match(source, /wizard-network-vm-list/, 'expected the VM IP list container');
  assert.match(source, /wizard-status-badge/, 'expected status badges for each VM');
  assert.match(source, /one-time free address suggestion/, 'expected the one-time IP allocation note');
  assert.doesNotMatch(source, /Start IP/, 'expected the fixed start IP field to be removed from the wizard');
  assert.doesNotMatch(source, /className="technical-panel"/, 'expected technical details to be removed');
  assert.match(source, /Output/, 'expected a visible output panel');
  assert.match(source, /wizard-step-icon/, 'expected step icons in the header');
  assert.match(source, /wizard-step-icon-large/, 'expected a larger icon in the active step header');
  assert.match(source, /wizard-step-icon-artwork/, 'expected the active step icon to render image artwork');
  assert.match(source, /iconArtworkUrl/, 'expected the active step artwork URL to be wired through');
  assert.match(source, /wizard-step-pitch/, 'expected a positive step description');
  assert.match(source, /Deploy Talos Cluster/, 'expected the Talos bootstrap step label');
  assert.match(source, /Load saved answers/, 'expected saved answers to live in the top bar');
  assert.match(source, /Check if IP addresses are free/, 'expected an explicit IP availability check action');
  assert.match(source, /Management VM/, 'expected the placement board to show the management VM host');
  assert.match(source, /CURRENT STEP/, 'expected the current step to be shown first');
  assert.match(source, /wizard-log-viewport/, 'expected the live output to be scrollable');
  assert.doesNotMatch(source, /Explore Twinbox/, 'should no longer read like a landing page');
});

test('web helper maps real icon artwork from local assets', async () => {
  const source = await readFile(helperSourcePath, 'utf8');

  assert.match(source, /STEP_ICON_ASSETS/, 'expected a step-to-asset map for the downloaded app icons');
  assert.match(source, /new URL\(\`\.\/assets\/step-icons\//, 'expected SVG artwork to be referenced through import.meta.url');
  assert.match(source, /assets\/step-icons/, 'expected the icons to live inside the web repo');
  assert.match(source, /icon_artwork_url/, 'expected the helper to expose artwork URLs to the UI');
});

test('styles define a wizard-first, responsive installer layout', async () => {
  const css = await readFile(appStylesPath, 'utf8');

  assert.match(css, /\.wizard-shell\s*\{/, 'expected wizard shell styling');
  assert.match(css, /\.wizard-layout\s*\{/, 'expected wizard layout grid');
  assert.match(css, /\.wizard-layout-minimal\s*\{/, 'expected the minimal wizard layout override');
  assert.match(css, /\.wizard-workspace-minimal\s*\{/, 'expected the simplified workspace');
  assert.match(css, /\.wizard-flow-minimal\s*\{/, 'expected the stacked active-step/output surface');
  assert.match(css, /\.wizard-start-screen\s*\{/, 'expected the start screen layout');
  assert.match(css, /\.wizard-guide-panel\s*\{/, 'expected the educational guide surface');
  assert.match(css, /\.wizard-choice-grid\s*\{/, 'expected numbered choice cards');
  assert.match(css, /\.wizard-log-viewport\s*\{/, 'expected a scrolling live-log viewport');
  assert.match(css, /\.wizard-output-panel\.is-live\s*\{/, 'expected live output emphasis');
  assert.doesNotMatch(css, /\.technical-panel\[open\]\s*\{/, 'expected technical details to be removed');
  assert.match(css, /\.wizard-output-panel-minimal\s*\{/, 'expected output to stay visible on the page');
  assert.match(css, /\.wizard-log-output\s*\{[\s\S]*min-height:\s*360px;/, 'expected a compact script output panel');
  assert.match(css, /\.wizard-step-icon-large\s*\{/, 'expected the active-step icon treatment');
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
