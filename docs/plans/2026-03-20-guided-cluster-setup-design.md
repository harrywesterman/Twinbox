# Guided Cluster Setup Design

## Summary

Refocus the current `manager-web` experience from a broad mission-control dashboard into a guided first-run installer for Twinbox cluster deployment. During initial setup, the UI should make the next click obvious, keep the active step dominant, and still show live technical output so the operator feels informed and in control.

## Problem

The current web interface is visually organized like an operations dashboard:

- a large hero area
- multiple status cards
- category progress summaries
- a separate activity sidebar
- technical details pushed to the edge

That creates too much simultaneous information during cluster setup. A first-time operator should not need to interpret a dashboard to figure out what to do next. The interface should instead behave like a step-by-step installer that guides the operator through provisioning and bootstrap, then later transition into the broader management surface.

## Goals

- Make the next action unambiguous during setup.
- Show where the operator is in the overall flow.
- Dedicate most of the screen to the current step.
- Keep technical details visible by default during execution.
- Require explicit operator confirmation for each next step.
- Preserve the manifest-driven backend contract where possible.
- Switch to a management-oriented surface only after setup is complete.

## Non-Goals

- No `Do everything` automation in this version.
- No backend transport rewrite such as WebSockets or SSE.
- No attempt to hide raw logs from operators.
- No full redesign of the day-2 management surface in this change.

## Recommended Approach

Introduce two explicit UI modes:

- `setup mode`: a guided installer for cluster deployment
- `manage mode`: the broader operations interface after setup completes

The backend catalog remains the source of truth for categories, steps, dependencies, status, and outputs. The frontend stops presenting that data as a dashboard during setup and instead renders it as a guided wizard shell with a compact progress rail and a dominant active-step workspace.

## Setup Mode Vs Manage Mode

### Setup Mode

Setup mode is the default experience while the cluster is being created and configured. It should emphasize only the information needed to complete the next step:

- compact progress rail with all steps in order
- one active step workspace
- one primary action
- visible live feedback
- technical details open by default

The UI should not spend valuable space on summary cards, health strips, duplicate progress cards, or a separate observability sidebar during this phase.

### Manage Mode

Once setup is complete, the interface can switch to the broader management surface. That mode can reuse or evolve from the current mission-control style layout and should prioritize day-2 operations such as health, artifacts, status summaries, and launching management applications.

### Mode Transition

The transition should be explicit, not a blended hybrid. During setup the product behaves as an installer. After setup it behaves as a management console.

For v1, the frontend can conservatively treat the currently exposed catalog flow as the setup flow and switch out of setup mode when all visible setup steps are complete. A future refinement can add explicit backend metadata to distinguish setup steps from day-2 tasks.

## Screen Layout During Setup

### Compact Progress Rail

The top or side rail should show:

- all steps in order
- current step index and total count
- completed steps
- locked steps
- the next available step

The rail is there to maintain orientation, not to compete with the active workspace.

### Dominant Active-Step Workspace

Roughly 90% of the visual attention should stay on the active step. That workspace contains:

- current step title
- short explanation in plain language
- required input fields, if any
- one primary action button
- live status text
- technical output and logs

### Information That Moves Out Of The Way

During setup, the current layout elements should be removed or heavily reduced:

- large hero metrics
- category status cards
- health strip
- separate right-hand activity panel
- duplicated progress summaries

Relevant information should instead appear inline within the active-step workspace.

## Step Interaction Model

Each step should behave like a small state machine with four operator-facing states.

### 1. Before Start

Show:

- step title
- one-sentence reason for the step
- any required inputs
- one clear primary action such as `Start step 1`

### 2. Running

After the operator starts the step, keep the operator on the same screen and show:

- a short human-readable status line
- technical details open by default
- live logs
- optional recent event/timeline highlights
- a disabled or waiting primary action

### 3. Success

After a successful run, show:

- what just completed
- important outputs or artifacts
- which step comes next
- a single primary action such as `Continue to step 2`

Twinbox should not auto-advance. The operator chooses when to continue.

### 4. Failed Or Blocked

If the step fails or cannot start, show:

- a plain-language summary of the issue
- the technical error details immediately below it
- missing dependencies or missing input context when relevant
- one recovery action such as `Retry step` or `Review inputs`

## Data Flow And UI State

The current frontend already polls:

- `/api/catalog`
- `/api/health`
- `/api/jobs/:jobId/logs`
- `/api/clusters/:clusterId`

That should stay intact for v1.

What changes is the presentation model in `manager-web/src/journey.js`. Instead of only exposing a mission-control dashboard model, it should derive:

- `mode`: `setup` or `manage`
- compact step rail state
- active-step presentation state
- operator guidance text
- step action labels such as `Start step 1` or `Continue to step 2`

The catalog still defines steps and dependencies. The UI simply translates that truth into a more guided experience.

## Implementation Impact

### Frontend Model

`manager-web/src/journey.js` should become responsible for setup-oriented derived state:

- mode selection
- ordered rail items
- explicit current-step positioning
- guided action labels and helper text
- success and failure summaries suitable for the active-step workspace

### Frontend Rendering

`manager-web/src/App.jsx` should render two branches:

- a setup shell with compact progress rail and dominant workspace
- a manage-mode shell for the post-install surface

The current right-hand activity information and technical log panel should be collapsed into the setup workspace rather than rendered as a separate third column.

### Styling

`manager-web/src/App.css` should shift the visual system during setup from a three-column dashboard to a focused installer layout with:

- a compact rail
- a larger central workspace
- more obvious primary actions
- open technical details that are visually integrated into the step view

## Risks

- The current catalog may eventually mix setup and day-2 steps, so a naive “all steps done means manage mode” rule may become too blunt.
- Removing summary cards can unintentionally hide useful context unless the active step carries the important state inline.
- Existing source-based layout tests will need to be rewritten because they currently assert the dashboard structure.

## Mitigations

- Keep the mode switch logic isolated in `journey.js` so backend metadata can refine it later.
- Preserve critical outputs and runtime state within the active-step workspace.
- Update tests first so the refactor is driven by explicit expectations.

## Success Criteria

- A first-time operator can tell within a few seconds what to click next.
- The current step is visually dominant over all other information.
- Technical details stay visible during execution without requiring an extra click.
- After a step completes, the next step is obvious but still operator-controlled.
- The interface clearly changes personality after setup from installer to management surface.
