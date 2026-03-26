# manager-web

Static Twinbox landing page for GitHub Pages.

## Purpose

- Explain Twinbox in plain language for non-technical visitors.
- Highlight sovereign, on-prem, low-maintenance deployment.
- Provide a public page with a calm, invitation-style tone.

## Local Development

```bash
npm ci
npm run dev
```

## GitHub Pages

The site builds with Vite and is configured for relative asset paths, so it can be hosted as a GitHub Pages site
without extra routing setup.

Deployment is handled by `.github/workflows/deploy-pages.yml`.

Build locally:

```bash
npm run build
```
