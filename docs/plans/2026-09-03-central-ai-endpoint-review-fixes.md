# Central AI Endpoint Review Fixes Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task.

**Goal:** Finish the central AI endpoint integration without losing OpenBao state and make it work inside the managed Twinbox Coder workspace.

**Architecture:** Keep `twinbox/global/twinbox-ai` as the shared OpenBao record. ExternalSecrets project app-specific values; the Coder workspace mounts a generated `opencode.json` and receives only the API key as an environment variable. Sync completion is established through a changed ExternalSecret status token before deployments restart.

**Tech Stack:** Bash, Kubernetes, External Secrets Operator, OpenBao, Terraform Coder template, Node.js, pytest.

---

### Task 1: Project AI configuration into Coder workspaces

**Files:**
- Modify: `infra/coder/templates/twinbox-development/main.tf`
- Modify: `gitops/workspace-namespaces/coder-workspaces/externalsecret.yaml`
- Modify: `scripts/manager/sync-twinbox-agents-config.sh`
- Test: `tests/scripts/test_coder_dev_workspace.py`
- Test: `tests/scripts/test_shared_ai_endpoint_manifests.py`

1. Add failing tests for the workspace ExternalSecret, mounted `opencode.json`, `OPENCODE_CONFIG`, API-key env reference, and workspace deployment restart.
2. Run the focused tests and confirm they fail for the missing projection.
3. Add the workspace ExternalSecret and Terraform secret mount/env plumbing; remove ineffective Coder-server AI envs.
4. Run the focused tests and confirm they pass.

### Task 2: Preserve existing OpenBao configuration on read failures

**Files:**
- Modify: `scripts/manager/ensure-shared-ai-secret.sh`
- Test: `tests/scripts/test_twinbox_agents_sync_contract.py`

1. Add executable tests that distinguish a confirmed missing secret from a generic read failure.
2. Confirm the generic-failure case currently attempts to seed and fails the test.
3. Seed only after a confirmed HTTP 404; propagate every other read error.
4. Confirm both missing-secret and read-failure tests pass.

### Task 3: Wait for a new ExternalSecret synchronization

**Files:**
- Modify: `scripts/manager/sync-twinbox-agents-config.sh`
- Test: `tests/scripts/test_twinbox_agents_sync_contract.py`

1. Add an executable fake-`kubectl` test where `Ready=True` is already present but `refreshTime` changes later.
2. Confirm the test catches an early deployment restart.
3. Capture the pre-annotation status token and poll until `refreshTime` or `syncedResourceVersion` changes while `Ready=True`.
4. Confirm missing resources remain successful and existing deployments restart only after refresh.

### Task 4: Make worker redaction directly testable

**Files:**
- Create: `manager-worker/src/ai-config-sync.mjs`
- Modify: `manager-worker/src/worker.js`
- Create: `manager-worker/test/ai-config-sync.test.mjs`

1. Add failing tests for shell-style and JSON-style API-key output.
2. Implement a focused redactor and use it from the sync handler.
3. Run worker tests and confirm legacy and new sync job compatibility remains intact.

### Task 5: Verify the complete change

1. Run Bash syntax checks for every changed installer/helper.
2. Run focused Python and Node tests.
3. Run `python3 -m pytest -q tests` with a supported Python runtime if system Python is too old.
4. Run `node --test manager-*/test/*.mjs`.
5. Run `make lint`, `make format-check`, and `git diff --check`.
6. Do not commit, push, or deploy without a separate explicit request.
