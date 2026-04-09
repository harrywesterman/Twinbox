import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const questionFlowPath = new URL('../src/question-flow.js', import.meta.url);
const helperSourcePath = new URL('../src/step-presentation.js', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);
const viteConfigPath = new URL('../vite.config.js', import.meta.url);
const indexHtmlPath = new URL('../index.html', import.meta.url);

test('app source defines a minimal wizard shell with guided input and step-by-step install controls', async () => {
  const source = await readFile(appSourcePath, 'utf8');
  const questionFlow = await readFile(questionFlowPath, 'utf8');

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
  assert.match(source, /type="range"/, 'expected the scale slider');
  assert.match(source, /1\. VM sizing/, 'expected sizing to come first');
  assert.match(source, /VM landing/, 'expected the VM placement block to be explicit');
  assert.match(source, /wizard-placement-board/, 'expected the host placement board');
  assert.match(source, /Automatic placement/, 'expected automatic placement controls');
  assert.match(source, /3\. Network and addressing/, 'expected networking to come after placement');
  assert.match(source, /wizard-network-summary/, 'expected a compact network summary');
  assert.match(source, /Per-VM IPs/, 'expected a per-VM IP list');
  assert.match(source, /wizard-network-vm-list/, 'expected the VM IP list container');
  assert.match(source, /wizard-status-badge/, 'expected status badges for each VM');
  assert.match(source, /Check for free IP addresses/, 'expected the IP check button under the VM list');
  assert.match(source, /wizard-field-dns/, 'expected a compact DNS field variant');
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
  assert.match(source, /readStoredWizardState/, 'expected startup state to hydrate from localStorage');
  assert.match(source, /setWizardPhase\('questions'\)/, 'expected a recreated cluster to restart in the question flow');
  assert.match(source, /getQuestionSteps\(answersRef\.current\)\[0\]\?\.id \|\| 'provision-nodes'/, 'expected a recreated cluster to restart at the first question');
  assert.match(source, /installLogSnapshotRef\.current = \{ stepId: '', output: '' \}/, 'expected recreation to clear stale install logs');
  assert.match(source, /Loading cluster data and IP suggestions/, 'expected a visible loading banner while refreshing');
  assert.match(source, /Check for free IP addresses/, 'expected an explicit IP availability check action');
  assert.match(source, /Management VM/, 'expected the placement board to show the management VM host');
  assert.match(source, /wizard-placement-management-card/, 'expected a fixed management VM placement card');
  assert.match(source, /wizard-placement-fixed-details/, 'expected management VM details inside the fixed card');
  assert.match(source, /is-neutral/, 'expected the management VM badge to use a neutral tone');
  assert.doesNotMatch(source, /Sizing comes first/, 'expected the old explanatory placement note to be removed');
  assert.doesNotMatch(source, /Retry balanced suggestion/, 'expected the old placement button label to be removed');
  assert.doesNotMatch(source, /Waiting for step 1 suggestions to load/, 'expected the old loading copy to be removed');
  assert.doesNotMatch(source, /Twinbox repeats the same check automatically when you click Next\./, 'expected the old IP check helper copy to be removed');
  assert.doesNotMatch(source, /Green means the suggested address was checked once\./, 'expected the old VM status legend copy to be removed');
  assert.doesNotMatch(source, /One address per VM, no fixed block/, 'expected the old per-VM heading copy to be removed');
  assert.doesNotMatch(source, /Base zone for platform hostnames/, 'expected the old DNS helper copy to be removed');
  assert.doesNotMatch(source, /No preset default/, 'expected the DNS field to hide the default copy');
  assert.match(source, /wizard-install-stage/, 'expected a centered install stage');
  assert.match(source, /wizard-install-output/, 'expected a dedicated output window for install mode');
  assert.match(source, /wizard-install-actions-row/, 'expected the install controls below the output window');
  assert.match(source, /installLogSnapshotRef/, 'expected the install view to retain the latest non-empty log snapshot');
  assert.match(source, /visibleInstallLogOutput/, 'expected the install pane to render a stable log fallback');
  assert.doesNotMatch(source, /CURRENT STEP/, 'expected the install phase to hide step context');
  assert.doesNotMatch(source, /wizard-step-context/, 'expected the install phase to stay blank apart from output');
  assert.match(source, /wizard-log-viewport/, 'expected the live output to be scrollable');
  assert.doesNotMatch(source, /Explore Twinbox/, 'should no longer read like a landing page');

  assert.match(questionFlow, /Enter the DNS domain for your cluster\./, 'expected the DNS helper sentence in the question flow');
  assert.doesNotMatch(questionFlow, /Base zone for platform hostnames/, 'expected the old DNS helper copy to be removed from the question flow');
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
  assert.match(css, /\.wizard-workspace-install\s*\{/, 'expected the centered install workspace');
  assert.match(css, /\.wizard-flow-minimal\s*\{/, 'expected the stacked active-step/output surface');
  assert.match(css, /\.wizard-start-screen\s*\{/, 'expected the start screen layout');
  assert.match(css, /\.wizard-guide-panel\s*\{/, 'expected the educational guide surface');
  assert.match(css, /\.wizard-choice-grid\s*\{/, 'expected numbered choice cards');
  assert.match(css, /\.wizard-log-viewport\s*\{/, 'expected a scrolling live-log viewport');
  assert.match(css, /\.wizard-output-panel\.is-live\s*\{/, 'expected live output emphasis');
  assert.doesNotMatch(css, /\.technical-panel\[open\]\s*\{/, 'expected technical details to be removed');
  assert.match(css, /\.wizard-output-panel-minimal\s*\{/, 'expected output to stay visible on the page');
  assert.match(css, /\.wizard-install-stage\s*\{/, 'expected a dedicated install stage wrapper');
  assert.match(css, /\.wizard-install-output\s*\{/, 'expected a large output window for install mode');
  assert.match(css, /\.wizard-install-actions-row\s*\{/, 'expected the install buttons to sit under the output window');
  assert.match(css, /\.wizard-log-output\s*\{[\s\S]*min-height:\s*360px;/, 'expected the default script output panel');
  assert.match(css, /\.wizard-step-icon-large\s*\{/, 'expected the active-step icon treatment');
  assert.match(css, /\.wizard-field input\[type='range'\]\s*\{/, 'expected the range slider styling');
  assert.match(css, /\.wizard-field-dns\s*\{/, 'expected a compact DNS field style');
  assert.match(css, /\.wizard-placement-management-card\s*\{/, 'expected the fixed management VM card styling');
  assert.match(css, /\.wizard-status-badge\.is-neutral\s*\{/, 'expected a neutral status badge tone');
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
  assert.match(indexHtml, /Loading Twinbox cluster setup/, 'expected a boot splash while React starts');
});
