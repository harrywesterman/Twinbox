# Guided Cluster Setup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current mission-control-first setup experience with a guided cluster deployment shell that keeps the current step dominant, makes the next action obvious, and preserves visible technical output.

**Architecture:** Keep the existing polling and manifest-driven backend contracts, but refactor the frontend presentation model so `journey.js` derives explicit setup/manage modes and guided step actions. Render a dedicated setup shell in `App.jsx` and preserve the broader dashboard layout as the initial manage-mode fallback after setup completes.

**Tech Stack:** React 18, Vite, plain CSS, Node `node:test`, manifest-driven catalog data from `manager-api`.

---

## Preconditions

- Create a dedicated git worktree before implementation so the UI refactor stays isolated from other ongoing work.
- Keep the backend API contracts unchanged for v1 unless a blocker appears during implementation.
- Treat the current visible catalog flow as the setup flow until explicit backend step metadata exists.

### Task 1: Derive Guided Setup Mode In The Mission Model

**Files:**
- Modify: `manager-web/test/journey-state.test.mjs`
- Modify: `manager-web/src/journey.js`

**Step 1: Write the failing test**

Add assertions that the model exposes setup-specific state while not all steps are complete, including:

```js
test('mission model exposes guided setup mode and numbered actions', () => {
  const model = getMissionControlModel({
    catalog,
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.mode, 'setup');
  assert.equal(model.progress.stepIndex, 2);
  assert.equal(model.primaryAction.label, 'Start step 2');
  assert.equal(model.stepRail.length, 3);
  assert.equal(model.stepRail[1].isCurrent, true);
});

test('mission model switches to manage mode when setup flow is complete', () => {
  const completedCatalog = structuredClone(catalog);
  for (const category of completedCatalog.categories) {
    for (const step of category.steps) {
      step.status = 'done';
      step.state = { ...step.state, status: 'succeeded' };
    }
  }

  const model = getMissionControlModel({
    catalog: completedCatalog,
    logs: [],
    cluster: { id: 'cluster_demo', status: 'bootstrapped' },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'bootstrap-cluster',
  });

  assert.equal(model.mode, 'manage');
});
```

**Step 2: Run test to verify it fails**

Run: `node --test manager-web/test/journey-state.test.mjs`
Expected: FAIL because `mode` and `stepRail` do not exist and the action label is still `Run step`.

**Step 3: Write minimal implementation**

Extend `manager-web/src/journey.js` with small helpers such as:

```js
function buildMode(steps) {
  return steps.length > 0 && steps.every((step) => step.status === 'done') ? 'manage' : 'setup';
}

function buildStepRail(steps, activeStep) {
  return steps.map((step, index) => ({
    id: step.id,
    title: step.title,
    index: index + 1,
    status: step.status,
    isCurrent: step.id === activeStep?.id,
  }));
}
```

Update `buildPrimaryAction(...)` so setup mode uses numbered labels like `Start step 1`, `Continue to step 2`, and `Retry step 2`.

**Step 4: Run test to verify it passes**

Run: `node --test manager-web/test/journey-state.test.mjs`
Expected: PASS for the new setup/manage mode and guided-action assertions.

**Step 5: Commit**

```bash
git add manager-web/test/journey-state.test.mjs manager-web/src/journey.js
git commit -m "feat: derive guided setup mission state"
```

### Task 2: Render The Setup Shell In App.jsx

**Files:**
- Modify: `manager-web/test/app-layout.test.mjs`
- Modify: `manager-web/src/App.jsx`

**Step 1: Write the failing test**

Replace the current dashboard-oriented source assertions with setup-shell assertions, for example:

```js
test('app source defines a guided setup shell with compact progress and visible technical details', async () => {
  const source = await readFile(appSourcePath, 'utf8');

  assert.match(source, /mission\.mode === 'setup'/);
  assert.match(source, /className="setup-progress-rail"/);
  assert.match(source, /className="setup-workspace"/);
  assert.match(source, /Technical details/);
  assert.match(source, /<details className="technical-panel" open>/);
  assert.doesNotMatch(source, /className="activity-panel"/);
});
```

**Step 2: Run test to verify it fails**

Run: `node --test manager-web/test/app-layout.test.mjs`
Expected: FAIL because `App.jsx` still renders `global-header`, `mission-grid`, and `activity-panel` as the primary setup layout.

**Step 3: Write minimal implementation**

Refactor `manager-web/src/App.jsx` so it has two explicit render branches:

- `setup` branch:
  - compact progress rail with all steps
  - dominant active-step workspace
  - inline input fields, runtime summary, and results
  - `Technical details` rendered open inside the main workspace
  - one clear primary action plus optional refresh secondary action
- `manage` branch:
  - preserve the current broader mission-control structure as the initial post-setup fallback

Use small extracted render helpers if needed, but keep the source of truth for state in `mission`.

**Step 4: Run test to verify it passes**

Run: `node --test manager-web/test/app-layout.test.mjs`
Expected: PASS with the new setup-shell structure present in source.

**Step 5: Commit**

```bash
git add manager-web/test/app-layout.test.mjs manager-web/src/App.jsx
git commit -m "feat: add guided setup app shell"
```

### Task 3: Replace Dashboard Styling With Setup-First Styling

**Files:**
- Modify: `manager-web/test/app-layout.test.mjs`
- Modify: `manager-web/src/App.css`

**Step 1: Write the failing test**

Add or update CSS assertions so the test expects a focused setup layout instead of the current three-column dashboard:

```js
assert.match(css, /\.setup-progress-rail\s*\{/);
assert.match(css, /\.setup-shell\s*\{/);
assert.match(css, /\.setup-workspace\s*\{/);
assert.match(css, /\.technical-panel\[open\]\s*\{/);
assert.doesNotMatch(css, /\.mission-grid\s*\{[\s\S]*grid-template-columns:/);
```

**Step 2: Run test to verify it fails**

Run: `node --test manager-web/test/app-layout.test.mjs`
Expected: FAIL because `App.css` still defines `.mission-grid` as the primary three-column layout and has no setup-shell classes.

**Step 3: Write minimal implementation**

Refactor `manager-web/src/App.css` so setup mode uses:

- a compact progress rail container
- a dominant single workspace column
- larger step header and primary action emphasis
- inline runtime and results sections
- an always-open technical panel that visually belongs to the active step

Retain responsive behavior for smaller screens, but preserve the core rule that the active step remains the main focus.

**Step 4: Run test to verify it passes**

Run: `node --test manager-web/test/app-layout.test.mjs`
Expected: PASS with setup-first class names and responsive rules in place.

**Step 5: Commit**

```bash
git add manager-web/test/app-layout.test.mjs manager-web/src/App.css
git commit -m "feat: restyle manager web as guided setup"
```

### Task 4: Verify The End-To-End Frontend Contract

**Files:**
- Modify: `manager-web/test/journey-state.test.mjs` (only if a gap appears during verification)
- Modify: `manager-web/test/app-layout.test.mjs` (only if a gap appears during verification)

**Step 1: Run the focused frontend test suite**

Run: `node --test manager-web/test/journey-state.test.mjs manager-web/test/app-layout.test.mjs`
Expected: PASS with no failing assertions.

**Step 2: Run a production build**

Run: `npm --prefix manager-web run build`
Expected: PASS and Vite emits a production bundle without JSX or CSS errors.

**Step 3: Smoke-check the setup flow manually**

Run: `npm --prefix manager-web run dev`
Expected: The app serves locally and the setup shell shows a compact rail, one dominant active step, numbered action text, and open technical details.

**Step 4: Capture any last missing assertion**

If manual smoke testing reveals a missed contract, add the smallest missing test to the existing Node test files before changing code.

**Step 5: Commit**

```bash
git add manager-web/test/journey-state.test.mjs manager-web/test/app-layout.test.mjs
git commit -m "test: lock guided setup behavior"
```
