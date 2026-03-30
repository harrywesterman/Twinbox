# Skip Steps Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "Skip" option to every wizard step so users can bypass steps they don't need, while still unlocking dependent steps.

**Architecture:** Store skip as `status: "skipped"` in the existing step state JSON files. Extend `isDone()` to treat skipped as completed for dependency resolution. Add skip/unskip API endpoints and skip/unskip UI controls.

**Tech Stack:** Node.js (Express), React (JSX), existing step state file model

---

### Task 1: API — Extend isDone and deriveStepStatus in catalog.js

**Files:**
- Modify: `manager-api/src/lib/catalog.js:205-313`

**Step 1: Extend `isDone()` to recognize skipped**

At `catalog.js:205`, add `skipped` as a done condition:

```javascript
function isDone(step, state) {
  if (state?.status === "skipped") return true;
  return step.type === "config"
    ? state?.status === "configured" || state?.status === "succeeded"
    : state?.status === "succeeded";
}
```

**Step 2: Extend `deriveStepStatus()` to return "skipped"**

At `catalog.js:294`, add an early return before the existing `isDone` check:

```javascript
function deriveStepStatus(step, state, latestJob, completedDependencies) {
  const dependenciesMet = step.depends_on.every((dependency) => completedDependencies.has(dependency));
  if (!dependenciesMet) {
    return "locked";
  }

  if (state?.status === "skipped") {
    return "skipped";
  }

  if (latestJob && (latestJob.status === "pending" || latestJob.status === "running")) {
    return "running";
  }

  if (state?.status === "failed") {
    return "failed";
  }

  if (isDone(step, state)) {
    return "done";
  }

  return "ready";
}
```

**Step 3: Verify with node --check**

Run: `node --check manager-api/src/lib/catalog.js`
Expected: No output (no errors)

**Step 4: Commit**

```bash
git add manager-api/src/lib/catalog.js
git commit -m "feat(api): extend isDone and deriveStepStatus for skipped steps"
```

---

### Task 2: API — Add skip endpoint

**Files:**
- Modify: `manager-api/src/server.js` (after the execute endpoint, ~line 1215)

**Step 1: Add POST /api/steps/:stepId/skip endpoint**

Insert after line 1215 (after the execute endpoint):

```javascript
app.post("/api/steps/:stepId/skip", (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId = typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const catalog = buildCatalogResponse({ workspaceRoot, dirs, clusterId: requestedClusterId || null });
  const step = catalog.stepsById.get(stepId);

  if (!step) {
    return res.status(404).json({ error: "step not found" });
  }

  const visibleStep = catalog.categories.flatMap((category) => category.steps).find((candidate) => candidate.id === stepId);
  if (!visibleStep) {
    return res.status(404).json({ error: "step not found" });
  }

  if (visibleStep.status === "running") {
    return res.status(409).json({ error: "cannot skip a running step" });
  }

  if (visibleStep.status === "done") {
    return res.status(409).json({ error: "cannot skip a completed step" });
  }

  const clusterScopeId = visibleStep.category_id === "talos-cluster"
    ? (requestedClusterId || catalog.activeClusterScopeId || null)
    : null;

  writeStepState(stepId, {
    status: "skipped",
    inputs: {},
    outputs: null,
    error: null,
    last_job_id: null,
  }, clusterScopeId);

  return res.status(200).json({
    step_id: stepId,
    status: "skipped",
  });
});
```

**Step 2: Verify with node --check**

Run: `node --check manager-api/src/server.js`
Expected: No output

**Step 3: Commit**

```bash
git add manager-api/src/server.js
git commit -m "feat(api): add POST /api/steps/:stepId/skip endpoint"
```

---

### Task 3: API — Add unskip endpoint

**Files:**
- Modify: `manager-api/src/server.js` (after the skip endpoint)

**Step 1: Add POST /api/steps/:stepId/unskip endpoint**

Insert after the skip endpoint:

```javascript
app.post("/api/steps/:stepId/unskip", (req, res) => {
  const stepId = req.params.stepId;
  const requestedClusterId = typeof req.body?.cluster_id === "string" ? req.body.cluster_id.trim() : "";
  const catalog = buildCatalogResponse({ workspaceRoot, dirs, clusterId: requestedClusterId || null });
  const step = catalog.stepsById.get(stepId);

  if (!step) {
    return res.status(404).json({ error: "step not found" });
  }

  const visibleStep = catalog.categories.flatMap((category) => category.steps).find((candidate) => candidate.id === stepId);
  if (!visibleStep) {
    return res.status(404).json({ error: "step not found" });
  }

  if (visibleStep.status !== "skipped") {
    return res.status(409).json({ error: "step is not skipped" });
  }

  const clusterScopeId = visibleStep.category_id === "talos-cluster"
    ? (requestedClusterId || catalog.activeClusterScopeId || null)
    : null;

  const file = stepStatePath(stepId, clusterScopeId);
  if (fs.existsSync(file)) {
    fs.unlinkSync(file);
  }

  return res.status(200).json({
    step_id: stepId,
    status: "not_started",
  });
});
```

**Step 2: Verify with node --check**

Run: `node --check manager-api/src/server.js`
Expected: No output

**Step 3: Commit**

```bash
git add manager-api/src/server.js
git commit -m "feat(api): add POST /api/steps/:stepId/unskip endpoint"
```

---

### Task 4: UI — Add skipped status to journey.js

**Files:**
- Modify: `manager-web/src/journey.js`

**Step 1: Update `isComplete()` to include skipped**

At `journey.js:26`, change:

```javascript
function isComplete(step) {
  return step?.status === 'done' || step?.status === 'skipped';
}
```

**Step 2: Add `isSkipped` to `buildStepRail()`**

At `journey.js:57`, add `isSkipped` to the rail item:

```javascript
function buildStepRail(steps, activeStep) {
  return steps.map((step, index) => ({
    id: step.id,
    title: step.title,
    icon: step.icon,
    index: index + 1,
    status: step.status,
    isCurrent: step.id === activeStep?.id,
    isComplete: isComplete(step),
    isSkipped: step.status === 'skipped',
    isLocked: step.status === 'locked',
    project_url: step.project_url,
    github_url: step.github_url,
    positive_summary: step.positive_summary,
  }));
}
```

**Step 3: Add `skippedSteps` to `buildProgress()`**

At `journey.js:39`, add skipped counter:

```javascript
function buildProgress(steps, activeStep) {
  const totalSteps = steps.length;
  const completedSteps = steps.filter(isComplete).length;
  const skippedSteps = steps.filter((step) => step.status === 'skipped').length;
  const activeIndex = activeStep ? steps.findIndex((step) => step.id === activeStep.id) : -1;

  return {
    totalSteps,
    completedSteps,
    skippedSteps,
    remainingSteps: Math.max(0, totalSteps - completedSteps),
    stepIndex: activeIndex >= 0 ? activeIndex + 1 : 0,
    percent: totalSteps ? Math.round((completedSteps / totalSteps) * 100) : 0,
  };
}
```

**Step 4: Update `toneForStatus()` for skipped**

At `journey.js:537`, add skipped case:

```javascript
export function toneForStatus(value) {
  if (value === 'done' || value === 'success') return 'success';
  if (value === 'skipped') return 'warning';
  if (value === 'running' || value === 'ready' || value === 'active') return 'active';
  if (value === 'failed' || value === 'danger') return 'danger';
  if (value === 'locked' || value === 'warning') return 'warning';
  return 'neutral';
}
```

**Step 5: Update `buildPrimaryAction()` for skipped**

At `journey.js:458`, add handling for skipped status. Insert after the `locked` check and before the `done` checks:

```javascript
  if (activeStep.status === 'skipped') {
    return {
      type: 'unskip',
      label: 'Run this step',
      disabled: false,
      helperText: 'This step was skipped. Click to run it now.',
    };
  }
```

**Step 6: Verify**

Run: `node --check manager-web/src/journey.js`
Expected: No output

**Step 7: Commit**

```bash
git add manager-web/src/journey.js
git commit -m "feat(ui): add skipped status support to journey model"
```

---

### Task 5: UI — Skip/Unskip controls in App.jsx

**Files:**
- Modify: `manager-web/src/App.jsx`

**Step 1: Add skip handler function**

Find a good place to add it near the other handlers (after `handleReinstallStep` at ~line 914):

```javascript
  async function handleSkipStep(step) {
    if (!step || busy || step.status === 'running' || step.status === 'done') {
      return;
    }

    const confirmed = window.confirm(`Are you sure you want to skip "${step.title}"? You can run this step later.`);
    if (!confirmed) {
      return;
    }

    setBusy(true);
    setError('');
    try {
      const response = await fetch(`/api/steps/${step.id}/skip`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cluster_id: clusterIdRef.current }),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || `Failed to skip ${step.title}`);
      }
      setNotice(`Skipped "${step.title}".`);
      await refreshWizardSnapshot();
    } catch (skipError) {
      const message = skipError instanceof Error ? skipError.message : `Failed to skip ${step.title}`;
      setError(message);
    } finally {
      setBusy(false);
    }
  }

  async function handleUnskipStep(step) {
    if (!step || busy || step.status !== 'skipped') {
      return;
    }

    setBusy(true);
    setError('');
    try {
      const response = await fetch(`/api/steps/${step.id}/unskip`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cluster_id: clusterIdRef.current }),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || `Failed to unskip ${step.title}`);
      }
      setNotice(`Unskipped "${step.title}". You can now run this step.`);
      await refreshWizardSnapshot();
    } catch (unskipError) {
      const message = unskipError instanceof Error ? unskipError.message : `Failed to unskip ${step.title}`;
      setError(message);
    } finally {
      setBusy(false);
    }
  }
```

**Step 2: Add unskip+execute handler**

```javascript
  async function handleUnskipAndExecute(step) {
    if (!step || busy || step.status !== 'skipped') {
      return;
    }

    setBusy(true);
    setError('');
    try {
      const response = await fetch(`/api/steps/${step.id}/unskip`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cluster_id: clusterIdRef.current }),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || `Failed to unskip ${step.title}`);
      }
      await refreshWizardSnapshot();
      const refreshedStep = { ...step, status: 'ready' };
      await executeStep(refreshedStep);
    } catch (err) {
      const message = err instanceof Error ? err.message : `Failed to run ${step.title}`;
      setError(message);
    } finally {
      setBusy(false);
    }
  }
```

**Step 3: Update handlePrimaryAction for unskip type**

In `handlePrimaryAction()` (~line 883), add handling for `unskip` type:

```javascript
    if (model.primaryAction.type === 'unskip') {
      await handleUnskipAndExecute(model.activeStep);
      return;
    }
```

**Step 4: Update handleInstallAllSteps to skip skipped steps**

At line 921, change the filter:

```javascript
    const pendingSteps = getWizardSteps(catalog).filter(
      (step) => step.status !== 'done' && step.status !== 'skipped'
    );
```

**Step 5: Render skip button in step workspace**

Find where the primary action button is rendered in the JSX (look for the primary action / "Start step" button rendering). Add a secondary skip button next to it when status is `ready` or `failed`.

Search for the primary action button rendering area — it will be in the JSX return of App.jsx. Add a skip link near the primary button:

```jsx
{(model.activeStep.status === 'ready' || model.activeStep.status === 'failed') && (
  <button
    type="button"
    onClick={() => handleSkipStep(model.activeStep)}
    disabled={busy}
    className="skip-step-button"
  >
    Skip this step
  </button>
)}
```

**Step 6: Render skipped state in step workspace**

When `model.activeStep.status === 'skipped'`, show a banner with unskip options instead of the normal step form. Find where the step workspace content is rendered and add:

```jsx
{model.activeStep.status === 'skipped' && (
  <div className="skipped-banner">
    <p>This step was skipped.</p>
    <button type="button" onClick={() => handleUnskipAndExecute(model.activeStep)} disabled={busy}>
      Run this step
    </button>
    <button type="button" onClick={() => handleUnskipStep(model.activeStep)} disabled={busy}>
      Keep skipped
    </button>
  </div>
)}
```

**Step 7: Verify**

Run: `node --check manager-web/src/App.jsx`
Expected: No output

**Step 8: Commit**

```bash
git add manager-web/src/App.jsx
git commit -m "feat(ui): add skip/unskip controls to wizard step workspace"
```

---

### Task 6: UI — Styling for skipped state

**Files:**
- Modify: `manager-web/src/App.css` (or relevant CSS file)

**Step 1: Add styles for skip button and skipped banner**

Find the CSS file and add:

```css
.skip-step-button {
  background: none;
  border: 1px solid var(--color-border, #ccc);
  border-radius: 4px;
  padding: 6px 12px;
  cursor: pointer;
  color: var(--color-text-muted, #888);
  font-size: 0.875rem;
}

.skip-step-button:hover {
  color: var(--color-warning, #e67e22);
  border-color: var(--color-warning, #e67e22);
}

.skipped-banner {
  background: var(--color-warning-bg, #fef9e7);
  border: 1px solid var(--color-warning, #e67e22);
  border-radius: 8px;
  padding: 16px;
  text-align: center;
}

.skipped-banner p {
  margin: 0 0 12px;
  font-weight: 500;
}

.skipped-banner button {
  margin: 0 6px;
}
```

**Step 2: Commit**

```bash
git add manager-web/src/App.css
git commit -m "feat(ui): add styling for skip button and skipped banner"
```

---

### Task 7: Verification

**Step 1: Run compose config check**

Run: `docker compose config`
Expected: Valid config output

**Step 2: Run any existing tests**

Run: `ls tests/` to find test files, then run them
Expected: Tests pass

**Step 3: Final commit of design doc**

```bash
git add docs/plans/2026-03-30-skip-steps-design.md docs/plans/2026-03-30-skip-steps.md
git commit -m "docs: add skip steps design and implementation plan"
```
