# Disable Dependabot version updates

## Goal

Use Renovate as Twinbox's only dependency update bot, without losing GitHub's
vulnerability detection.

## Design

Remove `.github/dependabot.yml` so Dependabot no longer creates scheduled npm,
Docker, or GitHub Actions version-update pull requests. Keep GitHub Dependabot
alerts enabled as a read-only vulnerability source, while leaving Dependabot
security updates disabled. Renovate reads those alerts and creates the security
pull requests governed by `renovate.json` and the repository's `main` ruleset.

Close the existing Dependabot version-update pull requests without merging them.
Renovate remains responsible for proposing eligible replacements according to
its schedules, minimum release ages, and manual-versus-automerge allowlist.

## Verification

A policy test requires the Dependabot version-update configuration to remain
absent. Repository settings are checked separately to confirm that alerts are
enabled and Dependabot security updates are disabled.
