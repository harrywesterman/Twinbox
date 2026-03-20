# Network Defaults And IP Suggestions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix provisioning defaults so the wizard auto-fills sane network values and only suggests contiguous free node IP ranges.

**Architecture:** Add API-level regression tests for host-network detection and contiguous range selection, then tighten the detection helpers in `manager-api/src/server.js`. Keep the UI behavior unchanged except for consuming the corrected API payload so user overrides still stick.

**Tech Stack:** Node.js, Express, React, Python `pytest`

---

### Task 1: Lock in API regressions

**Files:**
- Modify: `tests/api/test_clusters_api.py`
- Test: `tests/api/test_clusters_api.py`

**Step 1: Write the failing tests**

- Add one test where `/etc/resolv.conf` only exposes loopback/container DNS entries plus one real resolver and assert the API returns only the real resolver and an empty domain fallback.
- Add one test where the first preferred `start_ip` range contains a used middle address and assert the API skips it for the next fully free block.

**Step 2: Run tests to verify they fail**

Run: `pytest tests/api/test_clusters_api.py -k "dns or contiguous" -v`

Expected: FAIL because the API currently keeps loopback DNS/domain placeholders and/or chooses the wrong start IP block.

**Step 3: Write minimal implementation**

- Update DNS/default detection helpers in `manager-api/src/server.js`.
- Update the IP suggestion selection logic only if the tests prove it still accepts a broken range.

**Step 4: Run tests to verify they pass**

Run: `pytest tests/api/test_clusters_api.py -k "dns or contiguous" -v`

Expected: PASS

### Task 2: Verify UI integration still behaves correctly

**Files:**
- Modify: `manager-web/src/App.jsx` only if needed
- Test: existing API regression tests plus optional UI test coverage if behavior changes

**Step 1: Check whether the UI already preserves manual overrides**

- Inspect the `provision-nodes` draft merge logic in `manager-web/src/App.jsx`.

**Step 2: Change the UI only if the API fix reveals an integration gap**

- Keep API-provided defaults auto-applied only while the field still equals its untouched default.

**Step 3: Run relevant verification**

Run: `node --test manager-web/test/*.test.mjs`

Expected: PASS

### Task 3: Final verification

**Files:**
- Modify: `docs/plans/2026-03-20-network-defaults-and-ip-suggestions-design.md`
- Modify: `docs/plans/2026-03-20-network-defaults-and-ip-suggestions.md`

**Step 1: Run focused verification**

Run: `pytest tests/api/test_clusters_api.py -v`

Expected: PASS for the API suite.

**Step 2: Run web verification**

Run: `node --test manager-web/test/*.test.mjs`

Expected: PASS
