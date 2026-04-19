# Immich v2.7.5 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the Twinbox-managed Immich deployment to Immich `v2.7.5` without changing the Helm chart version unless the chart itself is required.

**Architecture:** Twinbox deploys Immich through the official Helm chart in Argo CD, but the chart does not automatically follow each Immich app release. The safest path is to keep the pinned chart at `0.11.1` and explicitly override the shared Immich image tag in `gitops/values/immich.yaml`, then run the standard Twinbox publish and management VM refresh flow.

**Tech Stack:** Argo CD, Helm values, GitHub Actions, Docker Compose, Kubernetes, SSH

---

### Task 1: Confirm the upgrade target and source of truth

**Files:**
- Modify: `docs/plans/2026-04-19-immich-v275-upgrade.md`
- Review: `gitops/apps/immich.yaml`
- Review: `gitops/values/immich.yaml`

**Step 1: Verify the official chart metadata**

Run: `curl -fsSL https://raw.githubusercontent.com/immich-app/immich-charts/refs/tags/immich-0.11.1/charts/immich/Chart.yaml`
Expected: `appVersion: v2.6.3`

**Step 2: Verify the official chart guidance**

Run: `curl -fsSL https://raw.githubusercontent.com/immich-app/immich-charts/main/README.md | rg "image.tag"`
Expected: output showing that `image.tag` must be set explicitly

**Step 3: Confirm Twinbox does not already pin the newer version**

Run: `sed -n '1,220p' gitops/values/immich.yaml`
Expected: no `image.tag: v2.7.5` override present yet

### Task 2: Apply the GitOps override

**Files:**
- Modify: `gitops/values/immich.yaml`

**Step 1: Add the shared image tag override**

Set `controllers.main.containers.main.image.tag` to `v2.7.5` so the server and machine-learning workloads inherit the requested Immich release.

**Step 2: Keep the rest of the deployment unchanged**

Do not change the Helm chart version or the database and ingress manifests unless verification proves they are required.

### Task 3: Verify the repository change locally

**Files:**
- Test: `gitops/values/immich.yaml`

**Step 1: Parse the YAML**

Run: `python3 - <<'PY'`
`import pathlib, yaml; yaml.safe_load(pathlib.Path("gitops/values/immich.yaml").read_text())`
`PY`
Expected: exit code `0`

**Step 2: Inspect the diff**

Run: `git diff -- gitops/values/immich.yaml docs/plans/2026-04-19-immich-v275-upgrade.md`
Expected: only the plan file and the Immich image tag override are changed

### Task 4: Publish through the Twinbox release flow

**Files:**
- Modify: `gitops/values/immich.yaml`
- Modify: `docs/plans/2026-04-19-immich-v275-upgrade.md`

**Step 1: Commit to `main`**

Run: `git add gitops/values/immich.yaml docs/plans/2026-04-19-immich-v275-upgrade.md && git commit -m "chore: upgrade immich to v2.7.5"`
Expected: commit created on `main`

**Step 2: Push to GitHub**

Run: `git push origin main`
Expected: remote `main` updated

**Step 3: Wait for the Docker image workflow**

Run: `gh run watch <run-id> --exit-status`
Expected: the publish workflow completes successfully

### Task 5: Refresh the management VM and verify the live cluster

**Files:**
- Review only: remote `/opt/twinbox` runtime state on the management VM

**Step 1: Refresh the manager stack**

Run remotely: `cd /opt/twinbox && docker compose pull && docker compose up -d`
Expected: latest `manager-api`, `manager-worker`, and `manager-web` containers are running

**Step 2: Verify Immich workload images**

Run remotely against the cluster: `kubectl -n immich get deploy,statefulset -o json`
Expected: Immich pods reference `v2.7.5`

**Step 3: Verify rollout health**

Run remotely: `kubectl -n immich get pods -o wide`
Expected: Immich pods are `Running` and ready after the upgrade
