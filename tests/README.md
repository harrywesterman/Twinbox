# Tests (Legacy)

The test content in this directory targets an older architecture and is not the primary acceptance path for the current manager-first runtime.

## Current Verification Source

Use:

- `docs/verification.md`
- `TESTING.md`

These reflect the current flow:

- wizard creates only the Management VM,
- management stack runs from prebuilt GHCR images,
- provisioning/bootstrap is triggered from the web UI.
