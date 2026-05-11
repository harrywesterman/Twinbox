# manager-web

Twinbox Web Installation Wizard for the Management VM.

## Purpose

- Guide first-run cluster bootstrap step by step.
- Keep the current installer step dominant and visible.
- Show live output, logs, and technical details without hiding the operator from the process.
- Export and import the full answer set for repeat installs.

## Local Development

```bash
npm ci
npm run dev
```

## Local Build

```bash
npm ci
npm run build
```

## Scripts

| Script             | Purpose                                    |
| ------------------ | ------------------------------------------ |
| `dev`              | Start Vite development server              |
| `build:step-icons` | Generate step icon assets from source      |
| `prebuild`         | Sync step icons to `public/` before build  |
| `build`            | Production Vite build                      |
| `preview`          | Preview production build on `0.0.0.0:4173` |

## Testing

Playwright is included for end-to-end testing:

```bash
npx playwright test
```
