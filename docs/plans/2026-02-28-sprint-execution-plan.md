# Twinbox Sprint Execution Plan (March-August 2026)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a reliable one-command private cloud platform with strong security, maintainability, and day-2 operations for homelab and SMB first, while preparing enterprise controls.

**Architecture:** Keep the management VM control plane as the execution hub, evolve orchestration to declarative/idempotent flows, and ship domain capabilities in strict monthly phases with quality gates before feature expansion.

**Tech Stack:** Proxmox, Talos, Kubernetes, Docker Compose (management VM), Node.js services (`manager-api`, `manager-web`, `manager-worker`), shell automation, pytest, API/e2e test suites.

---

## Planning Rules (Apply Every Sprint)

- Release train: 2 weeks.
- No new epic starts before previous epic quality gate passes.
- Every issue must include tests, logs/metrics impact, and rollback notes.
- DoD per issue: code + tests + docs + operability note.

## Sprint Cadence (Exact Dates)

- Sprint 1: March 2, 2026 - March 13, 2026
- Sprint 2: March 16, 2026 - March 27, 2026
- Sprint 3: March 30, 2026 - April 10, 2026
- Sprint 4: April 13, 2026 - April 24, 2026
- Sprint 5: April 27, 2026 - May 8, 2026
- Sprint 6: May 11, 2026 - May 22, 2026
- Sprint 7: May 25, 2026 - June 5, 2026
- Sprint 8: June 8, 2026 - June 19, 2026
- Sprint 9: June 22, 2026 - July 3, 2026
- Sprint 10: July 6, 2026 - July 17, 2026
- Sprint 11: July 20, 2026 - July 31, 2026
- Sprint 12: August 3, 2026 - August 14, 2026
- Sprint 13: August 17, 2026 - August 28, 2026

## March 2026 (Foundation and Reliability)

### Epic M1-E1: Declarative Cluster Spec and State Machine

Issues:
- M1-E1-I1 Define versioned cluster spec schema and validation contract.
- M1-E1-I2 Implement state machine for job lifecycle (`queued -> running -> succeeded/failed/cancelled`).
- M1-E1-I3 Add retry/backoff policy for transient bootstrap failures.
- M1-E1-I4 Persist structured events for each orchestration state transition.

### Epic M1-E2: Bootstrap Idempotency and Failure Recovery

Issues:
- M1-E2-I1 Make wizard/bootstrap rerunnable without manual cleanup.
- M1-E2-I2 Add preflight checks for Proxmox/Talos prerequisites.
- M1-E2-I3 Add failure codes with operator-friendly remediation hints.
- M1-E2-I4 Add "resume failed bootstrap" API path.

### Epic M1-E3: Baseline Observability

Issues:
- M1-E3-I1 Standardize structured log format across web/api/worker.
- M1-E3-I2 Add correlation IDs across API request -> worker execution.
- M1-E3-I3 Add minimum metrics set (job duration, failures, retries, queue lag).

Monthly Gate:
- Fresh environment bootstrap works on first run and re-run.
- e2e bootstrap pass rate >= 95% on supported test matrix.

## April 2026 (Security Baseline and Identity)

### Epic M2-E1: Authentication Foundation

Issues:
- M2-E1-I1 Implement local admin bootstrap login flow with forced password change.
- M2-E1-I2 Implement first external IDP integration path (OIDC baseline).
- M2-E1-I3 Add session management, expiry, and logout behavior.
- M2-E1-I4 Add auth boundary tests for all management endpoints.

### Epic M2-E2: RBAC v1

Issues:
- M2-E2-I1 Define role model (`owner`, `operator`, `viewer`) and permission matrix.
- M2-E2-I2 Enforce role checks in API and UI actions.
- M2-E2-I3 Add unauthorized access audit events and security logs.
- M2-E2-I4 Add role-based API contract tests.

### Epic M2-E3: Secrets and Audit Hygiene

Issues:
- M2-E3-I1 Centralize secret loading with redaction-by-default in logs.
- M2-E3-I2 Add secret rotation playbook and automation hook.
- M2-E3-I3 Add audit trail for critical actions (create/bootstrap/delete/update credentials).

Monthly Gate:
- All critical endpoints require authn/authz.
- Security review checklist passes before release.

## May 2026 (Storage and Backup/Restore v1)

### Epic M3-E1: Storage Baseline

Issues:
- M3-E1-I1 Implement storage profile configuration in cluster spec.
- M3-E1-I2 Validate storage readiness and surface status in UI.
- M3-E1-I3 Add storage health checks and failure alerts.

### Epic M3-E2: Backup Pipeline v1

Issues:
- M3-E2-I1 Define backup policy model (schedule, retention, target).
- M3-E2-I2 Implement backup job orchestration and status reporting.
- M3-E2-I3 Add backup verification metadata and integrity checks.

### Epic M3-E3: Restore Workflow v1

Issues:
- M3-E3-I1 Implement guided restore workflow.
- M3-E3-I2 Add restore dry-run validation and risk summary.
- M3-E3-I3 Add restore rehearsal automation for non-production target.

Monthly Gate:
- Backup and restore e2e succeeds on clean environment.
- RPO/RTO baseline metrics published.

## June 2026 (Networking, Tunnels, Operations UX)

### Epic M4-E1: Connectivity and Ingress

Issues:
- M4-E1-I1 Create tunnel/ingress configuration model with secure defaults.
- M4-E1-I2 Implement certificate issuance and renewal flow.
- M4-E1-I3 Add DNS/connectivity validation checks pre-publish.

### Epic M4-E2: Operations Dashboard

Issues:
- M4-E2-I1 Build single status page (cluster health, jobs, backups, updates).
- M4-E2-I2 Add timeline view for events and operator actions.
- M4-E2-I3 Add "what to do next" remediation cards for common failures.

### Epic M4-E3: Alerting and Notifications v1

Issues:
- M4-E3-I1 Define alert severities and escalation rules.
- M4-E3-I2 Implement notification channels (at least email/webhook).
- M4-E3-I3 Add alert deduplication and silence window controls.

Monthly Gate:
- First-time operator can publish an app externally without shell steps.
- All failure scenarios tested with actionable UI guidance.

## July 2026 (App Platform and Updates v1)

### Epic M5-E1: Curated App Catalog

Issues:
- M5-E1-I1 Define app packaging contract and metadata schema.
- M5-E1-I2 Ship first 3-5 curated apps with verified install flows.
- M5-E1-I3 Add dependency checks (storage, ingress, identity) before install.

### Epic M5-E2: App Policy Templates

Issues:
- M5-E2-I1 Implement reusable templates for IDP, RBAC, storage, backup hooks.
- M5-E2-I2 Add preconfigured policy bundles by segment (homelab/smb baseline).
- M5-E2-I3 Add template linting and compatibility checks.

### Epic M5-E3: Update Channels and Rollback

Issues:
- M5-E3-I1 Implement `stable` and `canary` channels.
- M5-E3-I2 Add version compatibility checks and upgrade blockers.
- M5-E3-I3 Add one-click rollback with safety checks.

Monthly Gate:
- Install/update/rollback works for all curated apps.
- No breaking update without migration path and rollback proof.

## August 2026 (SMB Product Readiness)

### Epic M6-E1: Supportability and Diagnostics

Issues:
- M6-E1-I1 Create diagnostics bundle command and API endpoint.
- M6-E1-I2 Add built-in environment validation report.
- M6-E1-I3 Add support-safe log export with secret redaction.

### Epic M6-E2: Operational Documentation and Runbooks

Issues:
- M6-E2-I1 Write operator runbooks for install, recovery, backup, upgrade.
- M6-E2-I2 Create incident response playbooks for top 10 failure modes.
- M6-E2-I3 Add in-product links to runbooks by error code.

### Epic M6-E3: Pilot Readiness and SLA Baseline

Issues:
- M6-E3-I1 Define pilot onboarding checklist and acceptance criteria.
- M6-E3-I2 Define incident severity model and response time targets.
- M6-E3-I3 Run 2-3 SMB pilot dry-runs and capture gap backlog.

Monthly Gate:
- Pilot readiness checklist passes for 2-3 target customers.
- Support workflows validated by non-author operators.

## Cross-Cutting Quality Track (Runs Every Sprint)

### Epic Q-E1: Test and Quality Automation

Issues:
- Q-E1-I1 Expand unit/contract/integration/e2e coverage for changed areas.
- Q-E1-I2 Keep deterministic CI and flaky test budget at zero.
- Q-E1-I3 Enforce coverage thresholds on critical orchestration code.

### Epic Q-E2: Maintainability and Architecture

Issues:
- Q-E2-I1 Record ADR for non-trivial architecture changes.
- Q-E2-I2 Keep module boundaries explicit; avoid cross-service coupling.
- Q-E2-I3 Refactor hotspots with measurable complexity reduction.

### Epic Q-E3: Security and Compliance Hygiene

Issues:
- Q-E3-I1 Run security scanning in CI for dependencies and containers.
- Q-E3-I2 Track and resolve high/critical findings within sprint.
- Q-E3-I3 Maintain auditable change and release notes.

## Backlog Format (Use This for Jira/GitHub Issues)

- Title: `[EpicCode] Short imperative summary`
- Description: user/problem/outcome in 3-5 lines.
- Acceptance Criteria: max 5 bullet points, testable.
- Test Plan: exact commands and expected pass criteria.
- Rollback Plan: explicit reversal path.
- Docs Impact: list docs that must be updated.

## Suggested Capacity Split per Sprint

- 50% roadmap domain epics (month theme).
- 20% reliability and maintenance debt.
- 20% test/security/automation hardening.
- 10% unplanned incidents and support.

## Exit Criteria for This 6-Month Program

- One-command provisioning is reliable and repeatable.
- Day-2 operations (identity, backup, update, diagnostics) are productized.
- SMB pilots can run production-like workloads with minimal operator effort.
- Enterprise requirements are de-risked without compromising core simplicity.
