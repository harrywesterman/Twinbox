# Twinbox Development Coder template

This Coder template creates a browser-based Twinbox development workspace inside
the Twinbox Kubernetes cluster.

It provides:

- VS Code through code-server.
- OpenCode Web.
- Codex CLI and OpenCode CLI inside the terminal.
- Playwright Chromium and Playwright UI.
- `kubectl`, `helm`, `k9s`, `talosctl`, `tofu`, `terraform`, and `opkssh`.
- Rootless NetBird sidecar connectivity to the Management VM and bastion.
- A checkout of `https://github.com/harrywesterman/Twinbox` in
  `/home/coder/code/Twinbox`.
- A `tb` helper for common Twinbox operations.
- Shared `.agents/skills` for Codex and OpenCode, populated with the Twinbox
  cluster, infrastructure, system, networking, UI, browser testing, GitHub, and
  Superpowers process skills.

The install step for the Coder app pushes this template when a Coder session
token is available on the Management VM. If the token is not available, the step
prints the exact `coder templates push` command so the template can be activated
manually.
