# Live Operation Timeline Design

## Summary

Add a primary runtime view to the management UI that makes long-running step execution feel alive and understandable. Instead of making the operator infer progress from occasional raw log lines, Twinbox should show a current stage, heartbeat-style freshness, and a human-readable event timeline for the active step.

## Problem

The current manifest-driven UI polls the catalog, logs, and cluster state, but the operator mostly sees snapshots. When `Provision nodes` or `Bootstrap cluster` take time, the interface can feel stalled even if the backend is still working normally. Raw logs are present, but they are secondary and too low-level to create a strong sense of control.

## Goals

- Show a clear live execution state for the active step.
- Translate existing job/log data into a readable runtime timeline.
- Surface “last updated” freshness so the operator knows polling is still active.
- Keep raw logs available for debugging, but demote them from the primary experience.
- Avoid requiring a backend transport rewrite for the first version.

## Non-Goals

- No WebSocket or Server-Sent Events in v1.
- No full event-sourcing redesign of job execution.
- No attempt to solve every possible script log format immediately.

## Recommended Approach

Build a frontend-first `Live Operation Timeline` powered by the data Twinbox already has:

- `latest_job.status`
- `latest_job.error`
- active step status
- cluster status
- job log lines from `/api/jobs/:jobId/logs`

The frontend should derive:

- a primary current stage label
- a freshness indicator
- a timeline of human-readable events
- a fallback raw log panel in technical details

In a later refinement, the worker/scripts can emit explicit stage markers to improve the fidelity of the derived timeline.

## UX Design

### Primary Runtime Strip

Add a prominent section near the top of the active step view:

- current stage, for example `Creating VMs`, `Waiting for Talos`, `Bootstrapping cluster`
- current run state chip, for example `Queued`, `Running`, `Done`, `Failed`
- “last updated Xs ago”
- subtle pulse while the job is still active
- total event count for the current run

This section should be visible without opening `Technical details`.

### Event Timeline

Add a timeline section directly under the primary runtime strip:

- one row per derived event
- timestamp from the existing log line prefix when available
- label in plain language
- optional subtext with the original raw message when useful
- newest event visually emphasized

### Technical Details

Keep `Technical details`, but narrow its purpose:

- raw log output
- identifiers
- full error text
- any low-level artifacts not useful in the primary experience

## Data Interpretation Strategy

### Stage Derivation

Use a deterministic frontend mapper over current job/log data.

Examples:

- `queued run_step` -> `Queued`
- `running job type=run_step` -> `Starting step`
- `Created controlplane VM` or `Created worker VM` -> `Creating VMs`
- `Generating Talos config` -> `Preparing Talos`
- `Applying controlplane config` or `Applying worker config` -> `Applying configuration`
- `Bootstrapping cluster` -> `Bootstrapping cluster`
- `Generating kubeconfig` -> `Fetching kubeconfig`
- `Detaching Talos ISO` -> `Cleaning up`
- `job completed` -> `Done`
- `job failed:` -> `Failed`

If no log-derived stage matches:

- `latest_job.status=pending` -> `Queued`
- `latest_job.status=running` -> `Running`
- `latest_job.status=succeeded` -> `Done`
- `latest_job.status=failed` -> `Failed`

### Freshness

Compute freshness from:

- newest log timestamp when present
- otherwise `latest_job.updated_at`
- otherwise catalog refresh time

Expose this as:

- `Updated just now`
- `Updated 3s ago`
- `Updated 12s ago`

If freshness exceeds a threshold while job status is still running, show a warning style like `No new activity for 45s`.

## Architecture Impact

### Frontend

Most of the first implementation lives in:

- `manager-web/src/journey.js`
- `manager-web/src/App.jsx`
- `manager-web/src/App.css`

`journey.js` should become responsible for:

- stage derivation
- event normalization
- freshness metadata
- runtime presentation model for the active step

`App.jsx` should render:

- primary live runtime strip
- timeline component
- secondary raw logs section

### Backend

No required API contract changes for v1.

Possible later refinement:

- emit explicit `stage:` markers from scripts or the worker
- optionally expose a compact derived runtime summary from the API

## Risks

- Log parsing can be brittle if scripts change wording.
- Different step types may need different mapping rules.
- Polling can still feel slightly delayed versus real push, but the heartbeat and freshness indicators should reduce that perception significantly.

## Mitigations

- Centralize mappings in one frontend helper.
- Keep graceful fallbacks to generic `Running`.
- Add focused tests for known Talos/Proxmox log phrases.
- Treat explicit stage markers as a follow-up enhancement, not a prerequisite.

## Testing Strategy

- Unit tests for log line to stage/event mapping.
- UI tests for active-step runtime states:
  - queued
  - running with fresh events
  - failed with derived human-readable error
  - succeeded with finished timeline
- Manual VM validation during:
  - `Provision nodes`
  - `Bootstrap cluster`

## Success Criteria

- Operators can tell within a few seconds whether a step is actively progressing.
- The current stage is visible without opening technical details.
- Long-running steps no longer feel frozen when polling is still healthy.
- A failure shows both the human-readable stage and the concrete failure reason.
