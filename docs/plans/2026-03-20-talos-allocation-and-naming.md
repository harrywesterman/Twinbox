# Talos Allocation And Naming Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add smart Talos provisioning defaults for VMIDs and IP ranges, enforce the same checks server-side, and propagate the selected cluster slug into Talos naming.

**Architecture:** Extend the manager API with allocation helpers that can inspect used VMIDs cluster-wide and probe IP availability for a requested node count. Reuse those helpers for both UI suggestions and create-step validation, then update provisioning to derive Talos VM names and cluster identity from a normalized `twinbox-<cluster-slug>` prefix.

**Tech Stack:** Node.js/Express, React, Bash, pytest

---

### Task 1: Lock Down Allocation Behavior In Tests

**Files:**
- Modify: `tests/api/test_clusters_api.py`
- Modify: `tests/api/test_jobs_api.py`

**Step 1: Write the failing test**

Add tests for:
- allocation suggestions that include `start_vmid` for a requested node count
- rejection when requested VMID/IP ranges are already occupied
- persisted cluster names that use `twinbox-<cluster-slug>`

**Step 2: Run test to verify it fails**

Run: `pytest tests/api/test_clusters_api.py tests/api/test_jobs_api.py -q`
Expected: FAIL because the API does not yet provide or validate the new allocation fields.

**Step 3: Write minimal implementation**

Implement allocation discovery and request validation in the API, then update cluster build logic to normalize names.

**Step 4: Run test to verify it passes**

Run: `pytest tests/api/test_clusters_api.py tests/api/test_jobs_api.py -q`
Expected: PASS

### Task 2: Wire Suggestions Into The Provision Form

**Files:**
- Modify: `manager-web/src/App.jsx`

**Step 1: Write the failing test**

No dedicated frontend test for this change; rely on API tests and manual verification because the existing app has no focused form test harness here.

**Step 2: Run test to verify it fails**

Skip; no existing targeted test coverage for this form behavior.

**Step 3: Write minimal implementation**

Fetch allocation suggestions using the current node counts and fill `start_vmid`, `vip_ip`, and `start_ip` only while those fields are still at defaults.

**Step 4: Run test to verify it passes**

Run the existing API tests plus a manual UI smoke check if needed.

### Task 3: Apply Naming In Provisioning

**Files:**
- Modify: `scripts/manager/create-talos-vms.sh`

**Step 1: Write the failing test**

Extend existing script contract coverage if required by assertions on generated names.

**Step 2: Run test to verify it fails**

Run: `pytest tests/scripts/test_manager_scripts_args.py -q`
Expected: FAIL once naming assertions are added.

**Step 3: Write minimal implementation**

Derive a `twinbox-<cluster-slug>` base name from the persisted cluster name and use it for Talos VM names.

**Step 4: Run test to verify it passes**

Run: `pytest tests/scripts/test_manager_scripts_args.py -q`
Expected: PASS

### Task 4: Verify End To End

**Files:**
- Modify: `manager-api/src/server.js`
- Modify: `manager-api/src/lib/clusters.js`
- Modify: `manager-web/src/App.jsx`
- Modify: `scripts/manager/create-talos-vms.sh`

**Step 1: Run focused verification**

Run:
- `pytest tests/api/test_clusters_api.py tests/api/test_jobs_api.py tests/scripts/test_manager_scripts_args.py -q`

Expected: PASS

**Step 2: Commit**

```bash
git add docs/plans/2026-03-20-talos-allocation-and-naming.md tests/api/test_clusters_api.py tests/api/test_jobs_api.py tests/scripts/test_manager_scripts_args.py manager-api/src/server.js manager-api/src/lib/clusters.js manager-web/src/App.jsx scripts/manager/create-talos-vms.sh
git commit -m "feat: add smart talos allocation defaults"
```
