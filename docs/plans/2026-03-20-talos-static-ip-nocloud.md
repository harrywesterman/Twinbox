# Talos Static IP Nocloud Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Talos Proxmox nodes boot with their final static IP configuration immediately, without DHCP, by switching the provisioning flow to Talos `nocloud`.

**Architecture:** Extend the Talos cluster payload with explicit network settings and surface host-derived defaults in the UI. Generate per-node Talos `nocloud` artifacts during provisioning, attach them to each Proxmox VM, and simplify bootstrap so it only performs cluster bootstrap and kubeconfig retrieval against the known static control-plane IPs.

**Tech Stack:** Node.js/Express, React, Bash, pytest, Proxmox API, Talos `talosctl`

---

### Task 1: Lock Down The New Cluster Payload

**Files:**
- Modify: `tests/api/test_clusters_api.py`
- Modify: `manager-api/src/lib/clusters.js`
- Modify: `docs/configuration.md`

**Step 1: Write the failing test**

Add coverage for:
- accepted `node_prefix_length`, `gateway_ip`, `dns_servers`, and `dns_domain`
- rejected invalid prefix lengths and malformed DNS server lists
- persisted cluster metadata containing the new fields

**Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/api/test_clusters_api.py -q`
Expected: FAIL because the API does not yet validate or persist the added network fields.

**Step 3: Write minimal implementation**

Update cluster request parsing and validation to accept the new network fields, normalize DNS server lists, and persist the values on the cluster record.

**Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/api/test_clusters_api.py -q`
Expected: PASS

### Task 2: Extend Network Suggestions And Provision Inputs

**Files:**
- Modify: `tests/api/test_clusters_api.py`
- Modify: `manager-api/src/server.js`
- Modify: `categories/talos-cluster/steps/provision-nodes/step.yaml`
- Modify: `manager-web/src/App.jsx`

**Step 1: Write the failing test**

Add API coverage for `/api/ip-suggestions` returning host-derived defaults for:
- `node_prefix_length`
- `gateway_ip`
- `dns_servers`
- `dns_domain`

**Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/api/test_clusters_api.py -q`
Expected: FAIL because the suggestion payload does not yet expose these values.

**Step 3: Write minimal implementation**

Teach the API to detect host networking defaults and return them in the suggestions response. Add the new input fields to the Talos provision step and auto-fill them in the UI only while they remain at defaults.

**Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/api/test_clusters_api.py -q`
Expected: PASS

### Task 3: Move Proxmox Talos Provisioning To Nocloud

**Files:**
- Modify: `tests/scripts/test_manager_scripts_args.py`
- Modify: `tests/worker/test_worker_lifecycle.py`
- Modify: `scripts/manager/create-talos-vms.sh`
- Modify: `manager-worker/src/worker.js`

**Step 1: Write the failing test**

Extend script and worker contract coverage for:
- passing the new network arguments through the worker
- creating Proxmox VMs with cloud-init support for Talos `nocloud`
- generating per-node config artifacts instead of assuming DHCP

**Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/scripts/test_manager_scripts_args.py tests/worker/test_worker_lifecycle.py -q`
Expected: FAIL because the worker and provisioning script do not yet accept or use the network settings.

**Step 3: Write minimal implementation**

Update the worker to pass the new fields into provisioning. Update `create-talos-vms.sh` to generate per-node Talos configs and Proxmox snippet references for `nocloud`, and to record those artifacts in cluster state.

**Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/scripts/test_manager_scripts_args.py tests/worker/test_worker_lifecycle.py -q`
Expected: PASS

### Task 4: Simplify Bootstrap For Preconfigured Static Nodes

**Files:**
- Modify: `tests/scripts/test_manager_scripts_args.py`
- Modify: `scripts/manager/bootstrap-talos.sh`
- Modify: `docs/talos-integration.md`

**Step 1: Write the failing test**

Add coverage ensuring bootstrap no longer performs `talosctl apply-config --insecure` and instead only bootstraps and retrieves kubeconfig from the known control-plane IP.

**Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/scripts/test_manager_scripts_args.py -q`
Expected: FAIL because the bootstrap script still applies configs during bootstrap.

**Step 3: Write minimal implementation**

Remove the insecure apply-config phase from bootstrap and keep only the Talos bootstrap and kubeconfig operations against the first control-plane IP.

**Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/scripts/test_manager_scripts_args.py -q`
Expected: PASS

### Task 5: Verify The End-To-End Contract

**Files:**
- Modify: `docs/configuration.md`
- Modify: `docs/talos-integration.md`

**Step 1: Run focused verification**

Run:
- `.venv/bin/python -m pytest tests/api/test_clusters_api.py tests/scripts/test_manager_scripts_args.py tests/worker/test_worker_lifecycle.py -q`

Expected: PASS

**Step 2: Commit**

```bash
git add docs/plans/2026-03-20-talos-static-ip-nocloud-design.md docs/plans/2026-03-20-talos-static-ip-nocloud.md tests/api/test_clusters_api.py tests/scripts/test_manager_scripts_args.py tests/worker/test_worker_lifecycle.py manager-api/src/lib/clusters.js manager-api/src/server.js manager-web/src/App.jsx categories/talos-cluster/steps/provision-nodes/step.yaml scripts/manager/create-talos-vms.sh scripts/manager/bootstrap-talos.sh manager-worker/src/worker.js docs/configuration.md docs/talos-integration.md
git commit -m "feat: provision talos nodes with static nocloud networking"
```
