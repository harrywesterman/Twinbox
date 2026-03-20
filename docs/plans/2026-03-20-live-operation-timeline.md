# Live Operation Timeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a primary live runtime timeline to the management UI so long-running steps show current stage, freshness, and human-readable progress without relying on technical details.

**Architecture:** Keep the first version frontend-first. Derive runtime stages and events from existing job status, cluster state, and polled log lines in `manager-web/src/journey.js`, then render them prominently in `manager-web/src/App.jsx`. Only use the backend data already available; no transport or API redesign in v1.

**Tech Stack:** React, Vite, existing manifest-driven manager web app, Python pytest tests, Node-based web tests

---

### Task 1: Add failing tests for runtime timeline derivation

**Files:**
- Modify: `tests` equivalent for manager web timeline behavior, likely `manager-web/test/journey-state.test.mjs`
- Reference: `manager-web/src/journey.js`

**Step 1: Write the failing tests**

Add focused tests that cover:

- queued step with no meaningful logs -> stage `Queued`
- running Talos provisioning logs -> stage `Creating VMs`
- running bootstrap logs -> stage `Bootstrapping cluster`
- failed run with explicit error -> timeline contains a failed event and the current stage is `Failed`
- freshness metadata is present when logs include timestamps

**Step 2: Run test to verify it fails**

Run: `node --test manager-web/test/journey-state.test.mjs`

Expected: FAIL because the runtime timeline model does not exist yet.

**Step 3: Commit**

```bash
git add manager-web/test/journey-state.test.mjs
git commit -m "test: cover live operation timeline states"
```

### Task 2: Implement runtime timeline model in `journey.js`

**Files:**
- Modify: `manager-web/src/journey.js`
- Test: `manager-web/test/journey-state.test.mjs`

**Step 1: Add minimal helpers**

Implement helpers for:

- parsing timestamped log lines
- mapping known phrases to stages
- building normalized events
- deriving freshness text and stale/running flags

Keep all mapping logic centralized in one place.

**Step 2: Extend mission control model**

Add a runtime model for the active step that includes:

- `currentStage`
- `runState`
- `lastUpdatedLabel`
- `isLive`
- `isStale`
- `eventCount`
- `timelineEvents`
- `rawLogOutput`

**Step 3: Run test to verify it passes**

Run: `node --test manager-web/test/journey-state.test.mjs`

Expected: PASS

**Step 4: Commit**

```bash
git add manager-web/src/journey.js manager-web/test/journey-state.test.mjs
git commit -m "feat: derive live operation timeline from manager logs"
```

### Task 3: Add failing UI tests for the primary live runtime strip

**Files:**
- Modify: `manager-web/test/app-layout.test.mjs`
- Reference: `manager-web/src/App.jsx`

**Step 1: Write the failing tests**

Add UI assertions that the active step page now shows:

- a live runtime section near the top
- current stage text
- last updated text
- event count
- timeline entries visible without opening technical details

**Step 2: Run test to verify it fails**

Run: `node --test manager-web/test/app-layout.test.mjs`

Expected: FAIL because the runtime strip is not rendered yet.

**Step 3: Commit**

```bash
git add manager-web/test/app-layout.test.mjs
git commit -m "test: cover live runtime strip layout"
```

### Task 4: Render the live runtime strip and timeline in `App.jsx`

**Files:**
- Modify: `manager-web/src/App.jsx`
- Modify: `manager-web/src/App.css`
- Test: `manager-web/test/app-layout.test.mjs`

**Step 1: Add a primary runtime section**

Render a section above the current checks/input/results stack that shows:

- current stage
- run state chip
- freshness label
- event count
- pulse/active indicator while running

**Step 2: Add timeline rendering**

Render the derived timeline entries in the main step view, not hidden in technical details.

Each entry should show:

- short label
- timestamp if available
- supporting detail when useful

**Step 3: Keep raw logs secondary**

Move or preserve raw logs under the technical details/debug area so the operator still has access to them.

**Step 4: Style for clarity**

Add CSS for:

- runtime strip
- timeline rows
- live pulse
- stale warning state
- mobile-safe layout

**Step 5: Run UI tests**

Run: `node --test manager-web/test/app-layout.test.mjs manager-web/test/journey-state.test.mjs`

Expected: PASS

**Step 6: Commit**

```bash
git add manager-web/src/App.jsx manager-web/src/App.css manager-web/test/app-layout.test.mjs manager-web/test/journey-state.test.mjs
git commit -m "feat: add live runtime timeline to manager web"
```

### Task 5: Verify broader behavior and regression safety

**Files:**
- Verify only

**Step 1: Run frontend build**

Run: `cd manager-web && npm run build`

Expected: successful production build

**Step 2: Run combined manager web tests**

Run: `node --test manager-web/test/*.mjs`

Expected: PASS

**Step 3: Run targeted backend/worker regression tests**

Run: `./.venv/bin/pytest tests/api/test_jobs_api.py tests/worker/test_worker_lifecycle.py -q`

Expected: PASS

**Step 4: Manual VM validation**

On the management VM:

- run `Provision nodes`
- confirm the active step shows a changing current stage and last-updated label while the job runs
- run `Bootstrap cluster`
- confirm the timeline advances as new events arrive
- confirm a failure still surfaces the concrete error text

**Step 5: Commit**

```bash
git add -A
git commit -m "test: verify live timeline integration"
```
