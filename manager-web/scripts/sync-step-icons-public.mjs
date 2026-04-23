import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(scriptDir, '..');
const repoRoot = path.resolve(webRoot, '..');
const sourceDir = path.join(webRoot, 'src/assets/step-icons');
const webPublicDir = path.join(webRoot, 'public/assets/step-icons');
const portalPublicDir = path.join(repoRoot, 'portal/public/assets/step-icons');

async function main() {
  await fs.mkdir(webPublicDir, { recursive: true });
  await fs.mkdir(portalPublicDir, { recursive: true });

  const entries = await fs.readdir(sourceDir, { withFileTypes: true });
  const svgFiles = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.svg'))
    .map((entry) => entry.name);

  await Promise.all(
    svgFiles.map(async (fileName) => {
      const sourcePath = path.join(sourceDir, fileName);
      const contents = await fs.readFile(sourcePath);
      await Promise.all([
        fs.writeFile(path.join(webPublicDir, fileName), contents),
        fs.writeFile(path.join(portalPublicDir, fileName), contents),
      ]);
    }),
  );

  return svgFiles.length;
}

main()
  .then((count) => {
    console.log(`Synced ${count} public step icons.`);
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
