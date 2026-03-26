import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSourcePath = new URL('../src/App.jsx', import.meta.url);
const appStylesPath = new URL('../src/App.css', import.meta.url);
const viteConfigPath = new URL('../vite.config.js', import.meta.url);
const indexHtmlPath = new URL('../index.html', import.meta.url);

test('landing page source defines a calm English homepage with illustrations', async () => {
  const source = await readFile(appSourcePath, 'utf8');

  assert.match(source, /className="hero"/, 'expected a hero section');
  assert.match(source, /className="art-frame art-frame-hero"/, 'expected a hero illustration frame');
  assert.match(source, /className="art-frame art-frame-contact"/, 'expected a second illustration frame');
  assert.match(source, /hero-illustration\.svg/, 'expected a hero illustration asset');
  assert.match(source, /hardware-illustration\.svg/, 'expected a hardware illustration asset');
  assert.match(source, /Explore Twinbox/, 'expected inviting but not salesy CTA copy');
  assert.match(source, /See whether Twinbox fits your environment\./, 'expected calm closing copy');
  assert.match(source, /Even when political winds shift in the United States/, 'expected a subtle geopolitical reference');
  assert.doesNotMatch(source, /Request a demo/, 'landing page should not sound sales-led');
  assert.doesNotMatch(source, /fetch\(/, 'landing page should not depend on backend API calls');
});

test('styles define a calm, responsive editorial layout', async () => {
  const css = await readFile(appStylesPath, 'utf8');

  assert.match(css, /\.site-shell\s*\{/, 'expected a page shell');
  assert.match(css, /\.hero\s*\{/, 'expected a hero layout');
  assert.match(css, /\.art-frame\s*\{/, 'expected illustration framing');
  assert.match(css, /\.trust-band\s*\{/, 'expected a trust word band');
  assert.match(css, /\.step-grid\s*\{/, 'expected a step grid');
  assert.match(css, /\.benefit-grid\s*\{/, 'expected a benefit grid');
  assert.match(css, /\.contact-band\s*\{/, 'expected a closing CTA band');
  assert.match(css, /@keyframes riseIn/, 'expected subtle entrance motion');
  assert.match(css, /@media \(max-width:\s*1080px\)/, 'expected tablet responsiveness');
  assert.match(css, /@media \(max-width:\s*760px\)/, 'expected mobile responsiveness');
});

test('vite is configured for GitHub Pages hosting', async () => {
  const viteConfig = await readFile(viteConfigPath, 'utf8');
  const indexHtml = await readFile(indexHtmlPath, 'utf8');

  assert.match(viteConfig, /base:\s*'\.\/'/, 'expected relative asset paths for GitHub Pages');
  assert.match(indexHtml, /lang="en"/, 'expected English language metadata');
  assert.match(indexHtml, /Twinbox \| Your data, in control/, 'expected landing page title');
});
