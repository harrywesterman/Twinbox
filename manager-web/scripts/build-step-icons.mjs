import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { STEP_ICON_MANIFEST } from '../src/assets/step-icons/manifest.js';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(scriptDir, '..');
const iconsDir = path.join(webRoot, 'src/assets/step-icons');
const pngSize = 256;

function asHexChannel(value) {
  return Math.max(0, Math.min(255, Number(value))).toString(16).padStart(2, '0');
}

function rgbToHex([red, green, blue]) {
  return `#${asHexChannel(red)}${asHexChannel(green)}${asHexChannel(blue)}`;
}

function isNeutral([red, green, blue]) {
  const max = Math.max(red, green, blue);
  const min = Math.min(red, green, blue);
  return max < 48 || min > 220 || (max - min) < 18;
}

function tintSvg(svg, color) {
  return svg
    .replace(/currentColor/g, color)
    .replace(/fill="none"/g, 'fill="none"');
}

function toDataUrl(text, mimeType) {
  return `data:${mimeType};base64,${Buffer.from(text).toString('base64')}`;
}

async function loadTextSource(entry) {
  if (entry.sourceKind === 'simple-icons') {
    const color = entry.sourceColor || '000000';
    const url = `https://cdn.simpleicons.org/${entry.sourceSlug}/${color.replace(/^#/, '')}`;
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Failed to fetch ${entry.stepId} from ${url}: ${response.status}`);
    }
    return await response.text();
  }

  if (entry.sourceKind === 'remote-svg') {
    const response = await fetch(entry.sourceUrl);
    if (!response.ok) {
      throw new Error(`Failed to fetch ${entry.stepId} from ${entry.sourceUrl}: ${response.status}`);
    }
    return await response.text();
  }

  if (entry.sourceKind === 'local-svg') {
    const filePath = path.join(iconsDir, entry.sourceFile);
    return await fs.readFile(filePath, 'utf8');
  }

  throw new Error(`Unsupported source kind for ${entry.stepId}: ${entry.sourceKind}`);
}

async function samplePngColor(page, pngPath) {
  const bytes = await fs.readFile(pngPath);
  const dataUrl = toDataUrl(bytes, 'image/png');
  await page.setContent(`
    <!doctype html>
    <html>
      <body style="margin:0;background:transparent">
        <canvas id="canvas" width="256" height="256"></canvas>
        <img id="image" src="${dataUrl}" style="display:none" />
      </body>
    </html>
  `);

  const result = await page.evaluate(async () => {
    const image = document.getElementById('image');
    await image.decode();
    const canvas = document.getElementById('canvas');
    const context = canvas.getContext('2d');
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
    const counts = new Map();

    for (let index = 0; index < pixels.length; index += 4) {
      const alpha = pixels[index + 3];
      if (alpha < 12) {
        continue;
      }

      const red = pixels[index];
      const green = pixels[index + 1];
      const blue = pixels[index + 2];
      const neutral = Math.max(red, green, blue) < 48 || Math.min(red, green, blue) > 220 || (Math.max(red, green, blue) - Math.min(red, green, blue)) < 18;
      const key = `${Math.round(red / 16) * 16},${Math.round(green / 16) * 16},${Math.round(blue / 16) * 16}`;
      const current = counts.get(key) || { count: 0, neutral: 0 };
      counts.set(key, {
        count: current.count + 1,
        neutral: current.neutral + (neutral ? 1 : 0),
      });
    }

    const sorted = [...counts.entries()]
      .sort((left, right) => {
        const leftValue = left[1];
        const rightValue = right[1];
        if (leftValue.neutral !== rightValue.neutral) {
          return leftValue.neutral > rightValue.neutral ? 1 : -1;
        }
        return rightValue.count - leftValue.count;
      });

    return sorted.map(([key]) => key).slice(0, 10);
  });

  const bestColor = result
    .map((value) => value.split(',').map((part) => Number(part)))
    .find((rgb) => !isNeutral(rgb))
    || (result[0] ? result[0].split(',').map((part) => Number(part)) : [15, 23, 42]);

  return rgbToHex(bestColor);
}

async function renderPng(page, svgText, outputPath) {
  const svgDataUrl = toDataUrl(svgText, 'image/svg+xml');
  await page.setContent(`
    <!doctype html>
    <html>
      <head>
        <style>
          html, body {
            width: 256px;
            height: 256px;
            margin: 0;
            background: transparent;
          }

          body {
            display: grid;
            place-items: center;
          }

          img {
            width: 78%;
            height: 78%;
            object-fit: contain;
            display: block;
          }
        </style>
      </head>
      <body>
        <img src="${svgDataUrl}" alt="" />
      </body>
    </html>
  `);

  await page.screenshot({
    path: outputPath,
    omitBackground: true,
  });
}

async function main() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 256, height: 256 },
    deviceScaleFactor: 2,
  });

  const generated = [];

  for (const entry of STEP_ICON_MANIFEST) {
    const svgPath = path.join(iconsDir, `${entry.fileBase}.svg`);
    const pngPath = path.join(iconsDir, `${entry.fileBase}.png`);
    const sourceText = await loadTextSource(entry);
    let finalSvg = sourceText;

    if (entry.sourceKind === 'local-svg') {
      const currentColor = sourceText.includes('currentColor');
      const tintSource = entry.tintFromPng ? path.join(iconsDir, entry.tintFromPng) : null;
      let tintColor = entry.tintColor || '';

      if (!tintColor && currentColor && tintSource) {
        tintColor = await samplePngColor(page, tintSource);
      }

      if (!tintColor && currentColor) {
        tintColor = '#0f172a';
      }

      if (tintColor && currentColor) {
        finalSvg = tintSvg(sourceText, tintColor);
      }
    }

    await fs.writeFile(svgPath, finalSvg);
    await renderPng(page, finalSvg, pngPath);
    generated.push(entry.fileBase);
  }

  await browser.close();
  return generated;
}

main().then((generated) => {
  console.log(`Generated ${generated.length} icon pairs.`);
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
