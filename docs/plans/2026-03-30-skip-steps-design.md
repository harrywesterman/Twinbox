# Design: Skip Steps in Web Wizard

## Summary

Add a "Skip" option to every step in the web wizard, allowing users to bypass steps they don't want to execute. Skipped steps still unlock dependent steps. Users can unskip a skipped step later and execute it.

## Approach

Store skip state as `status: "skipped"` in the existing step state JSON files — the same mechanism used for `succeeded`/`configured`. Extend `isDone()` so `skipped` counts as completed for dependency resolution.

## API Changes

### New endpoints (manager-api/src/server.js)

**`POST /api/steps/:stepId/skip`**
- Validates step exists and is not `running` or `done`
- Writes step state: `{ status: "skipped", inputs: {}, outputs: null, error: null, last_job_id: null, ... }`
- No job is created — direct state write
- Returns 200 with step state summary

**`POST /api/steps/:stepId/unskip`**
- Validates step exists and current state is `skipped`
- Deletes the step state file (or resets to `not_started`)
- Returns 200 with empty state summary

### Catalog changes (manager-api/src/lib/catalog.js)

**`isDone()` — line 205:** Add `state?.status === "skipped"` as a done condition.

**`deriveStepStatus()` — line 294:** Add early return for `state?.status === "skipped"` → `"skipped"`.

**`deriveCategoryStatus()` — line 315:** Treat `skipped` as non-blocking (already handled by `isDone` returning true).

**`completedDependencies` set — line 365:** Automatically includes skipped steps because `isDone` returns true for them.

## UI Changes

### Skip/Unskip buttons (manager-web/src/App.jsx)

**Skip button:** Appears alongside "Start step" when `status === 'ready'` or `status === 'failed'`. Secondary style (outline/link). Shows confirmation dialog before executing.

**Unskip UI:** When `status === 'skipped'`, the step workspace shows a banner "This step was skipped" with buttons:
- "Run this step" — calls unskip then execute
- "Keep skipped" — no action

### Step rail (manager-web/src/journey.js)

**`buildStepRail()`:** Add `isSkipped: step.status === 'skipped'` to rail items.

**`toneForStatus()`:** Add `if (value === 'skipped') return 'warning'` for amber/orange color.

**`buildProgress()`:** Skipped steps count as completed for progress percentage. Add `skippedSteps` counter for display.

### Install All Steps (manager-web/src/App.jsx)

**`handleInstallAllSteps()` — line 921:** Filter out skipped steps:
```javascript
const pendingSteps = getWizardSteps(catalog).filter(
  (step) => step.status !== 'done' && step.status !== 'skipped'
);
```

## Edge Cases

- **Skip while running:** Not allowed, return 409
- **Skip already done:** Not allowed, use reinstall instead
- **Skip locked step:** Allowed? No — only `ready` and `failed` steps can be skipped
- **Unskip a step with failed dependents:** Dependents revert to `locked` or `ready` based on their other dependencies
- **Install All Steps:** Skipped steps are passed over, not executed

## Files to Modify

| File | Changes |
|------|---------|
| `manager-api/src/server.js` | Add skip/unskip endpoints |
| `manager-api/src/lib/catalog.js` | Extend isDone, deriveStepStatus, deriveCategoryStatus |
| `manager-web/src/journey.js` | Add skipped to rail, progress, tone |
| `manager-web/src/App.jsx` | Skip/unskip buttons, confirmation dialog, install-all filter |
