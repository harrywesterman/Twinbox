# Cluster capacity: right-size CPU requests

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Free schedulable CPU-request capacity on the `prd` cluster so the `twinbox-portal` pod (currently stuck `Pending` with `Insufficient cpu`) and new applications can run again on the existing VMs.

**Architecture:** The cluster is over-committed on CPU *requests* (18.6 CPU requested vs 17.8 allocatable = 104%), while actual CPU usage is only ~32%. Lowering CPU requests to realistic values frees scheduling headroom without touching CNPG replicas, control-plane taints, maxPods, or hardware. Memory requests stay unchanged (actual memory usage is close to requests; lowering them would risk OOM kills).

**Tech Stack:** bash (manager worker scripts), YAML (GitOps manifests), Argo CD (applies manifests), kube-prometheus-stack (Helm values).

---

## Background / measurements

- Cluster `prd`: 2 control-plane + 4 worker VMs.
- Worker allocatable CPU: worker-1 9950m, worker-2 1950m, worker-3 3950m, worker-4 1950m (total 17800m).
- Current CPU requests per node: 97% / 95% / 97% / 94% → scheduler rejects any new pod (`Insufficient cpu`).
- Actual CPU usage (`kubectl top nodes`): 15–52% per node.
- Affected workloads (request → actual):
  - prometheus 500m → 139m
  - karakeep 500m → 13m, chrome 500m → ~low
  - outline 500m → 1m
  - mailu rspamd 250m → ~low, clamav 250m → 6m
  - paperless 250m → 3m
  - argocd-server 150m (via LimitRange, no explicit resources in HA install manifests)
- LimitRange defaults (from `namespace_resource_baseline` in `apply-argocd-application.sh`) apply to every container that does not set its own resources. For the `standard` profile these are 150m CPU (infrastructure tier) and 50m CPU (application tier) per container.

## Scope

- **In scope:** CPU request reductions via LimitRange defaults + explicit manifest/values edits. Argo CD sync on cluster.
- **Out of scope (user decision):** CNPG replica reduction, control-plane node scheduling, maxPods increase, physical RAM/hardware.

---

### Task 1: Lower LimitRange default CPU requests

**Files:**
- Modify: `scripts/manager/apply-argocd-application.sh:105-167`
- Test: `tests/scripts/test_manager_scripts_args.py` (assertions on script text)

**Step 1: Edit `namespace_resource_baseline`**

For the `standard` profile (`*` case, since `prd` is `standard`):
- infrastructure tier: `request_cpu="150m"` → `"75m"`
- application tier: `request_cpu="50m"` → `"25m"`

`small` and `large` profiles are left untouched (not used by `prd`).

**Step 2: Verify**

Run: `python3 -m pytest -q tests/scripts/test_manager_scripts_args.py -k apply_argocd`
Expected: PASS.

**Step 3: Commit**

```bash
git add scripts/manager/apply-argocd-application.sh
git commit -m "perf: halve LimitRange default CPU requests for standard profile"
```

---

### Task 2: Lower explicit CPU requests to match real usage

**Files:**
- Modify: `gitops/values/prometheus.yaml:13` (prometheus 500m → 250m)
- Modify: `gitops/optional-apps/karakeep.yaml:46` (karakeep 500m → 100m)
- Modify: `gitops/optional-apps/karakeep.yaml` chrome container (add resources 500m → 100m)
- Modify: `gitops/platform-apps/outline/deployment.yaml:69` (outline 500m → 100m)
- Modify: `gitops/values/mailu.yaml:124,133` (rspamd 250m → 100m, clamav 250m → 100m)
- Modify: `gitops/platform-apps/paperless/deployment.yaml:31` (paperless 250m → 100m)
- Test: `tests/scripts/test_manager_scripts_args.py:3605-3626` (prometheus), `:4312-4322` (paperless), `:4914-4930` (karakeep)

Values chosen as actual usage × 2–3 margin, rounded up to a sane minimum:
- prometheus: 500m → 250m (actual 139m)
- karakeep: 500m → 100m (actual 13m); chrome 500m → 100m
- outline: 500m → 100m (actual 1m)
- mailu rspamd: 250m → 100m; clamav: 250m → 100m (actual 6m)
- paperless: 250m → 100m (actual 3m)
- Memory requests unchanged. CPU limits unchanged.

**Step 1: Update tests that assert the old values**

`test_prometheus_values_configures_alertmanager_and_storage` asserts `"cpu: 500m"`; change to `"cpu: 250m"`.
`test_paperless_deployment_uses_reasonable_resources` asserts `"cpu: 250m"`; change to `"cpu: 100m"`.
`test_karakeep_argo_application_manages_the_platform_overlay` asserts `"cpu: 500m"`; change to `"cpu: 100m"`.

**Step 2: Run the full Python suite**

Run: `python3 -m pytest -q tests`
Expected: PASS.

**Step 3: Verify manifests are valid YAML**

Run: `python3 -c "import yaml,pathlib; [yaml.safe_load(p.read_text()) for p in pathlib.Path('gitops').rglob('*.yaml')]"` (or rely on pytest loading them).

**Step 4: Commit**

```bash
git add gitops/
git commit -m "perf: lower explicit CPU requests for prometheus, karakeep, outline, mailu, paperless"
```

---

### Task 3: Verify and ship

**Step 1: Lint + format**

Run: `make lint && make format-check`
Expected: PASS.

**Step 2: Shell syntax checks for changed bash**

Run: `bash -n scripts/manager/apply-argocd-application.sh`
Expected: no output.

**Step 3: Push and wait for image build**

```bash
git push origin main
```

Watch GitHub Actions "Publish Docker Images" workflow (management VM containers build from `main`). Wait for success. Do not pull before it finishes.

**Step 4: Refresh Management VM stack**

On the Management VM (192.168.2.70, via SSH), update `TWINBOX_IMAGE_TAG` to the published `sha-<7>` and run:
`sudo -n sh -lc 'cd /opt/twinbox && docker compose pull && docker compose up -d'`

**Step 5: Verify scheduling on the cluster**

From the Management VM:
```
kubectl describe nodes                       # no "Insufficient cpu" for portal
kubectl get pods -n twinbox-portal           # portal Running
kubectl get pods -A --field-selector status.phase=Pending   # empty or reduced
```
Note: LimitRange default changes only apply to pods created *after* the baseline is reapplied. Existing workloads keep their current requests until they roll. The explicit-request reductions (Task 2) take effect when Argo CD syncs and recreates those workloads. If the portal is still `Pending` immediately after the VM refresh, trigger an Argo CD sync / hard-refresh of the affected apps and re-check.