# Mailu Storage-Node Selection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Mailu's shared-storage node selection disk- and capacity-aware so it never pins the Mailu workloads to a node that cannot host them.

**Architecture:** Rewrite `choose_mailu_storage_node()` in `categories/apps/steps/install-mailu/run.sh`. Keep the existing label-driven flow (`twinbox.io/mailu-storage-node=<slug>` node label + Argo CD cluster secret annotation) untouched — only the chooser becomes smarter. The chooser keeps an existing Ready labeled node, else filters Ready/schedulable/non-control-plane candidates through a must-fit capacity check (pod slots, CPU, memory), then ranks survivors by free Longhorn disk (`nodes.longhorn.io` `status.diskStatus[*].storageAvailable`) with an `ephemeral-storage` fallback. If nothing fits, it fails with a per-node rejection diagnostic instead of silently picking `head -n1`.

**Tech Stack:** bash, `kubectl`, `jq` (already a required dep of the script), optional `python3` (already required). No new deps.

**Key numbers (must-fit budget for the pinned set):** pinned deployments are front, admin, postfix, dovecot, rspamd, webmail.
- Requests sum: CPU `750m`, memory `1664Mi`, pods `6`.
- Conservative budgets used in the filter: **pods ≥ 8**, **CPU ≥ 1000m**, **memory ≥ 2048Mi** (a few deployments worth of headroom).

**Background:** In the `prd` cluster the old `head -n1` behavior chose `twinbox-prd-worker-1` (alphabetically first), which was already at 110/110 pods, so five pinned Mailu deployments stayed `Pending` and the step timed out. With this fix the must-fit filter removes worker-1 (free pods = -1) and ranks worker-3 (639 GiB free) over worker-2 (461 GiB free) → worker-3 wins.

---

### Task 1: Add parse + capacity helpers to the installer

**Files:**
- Modify: `categories/apps/steps/install-mailu/run.sh:168-225` (replace the `sanitize_label_value`…`choose_mailu_storage_node` block region; keep `sanitize_label_value` and `random_hex` as-is, add helpers before `choose_mailu_storage_node`)

**Step 1: Add the two numeric helpers just above `choose_mailu_storage_node`**

Insert after the `sanitize_label_value()` function (ends at line ~178):

```bash
# Parse a k8s CPU quantity to milli-cores ("750m" -> 750, "2" -> 2000, "0.5" -> 500).
cpu_to_millicores() {
  local value="$1"
  local number unit
  if [[ "$value" == *m ]]; then
    number="${value%m}"
  elif [[ "$value" == *.* ]]; then
    number="$value"
  else
    number="$value"
  fi
  python3 -c 'import re,sys; v=sys.argv[1]; m=re.match(r"^(\d+(?:\.\d+)?)m?$", v)
if not m: sys.exit(f"unparseable cpu: {v}")
n=float(m.group(1)); print(int(n*1000))' "$value"
}

# Parse a k8s memory quantity to Mi ("128Mi" -> 128, "1Gi" -> 1024, "22025760Ki" -> 21509).
mem_to_mib() {
  python3 -c 'import re,sys; v=sys.argv[1]; m=re.match(r"^(\d+(?:\.\d+)?)([KMG]i?|)$", v)
if not m: sys.exit(f"unparseable memory: {v}")
n=float(m.group(1)); unit=m.group(2)
mul={"":1,"K":1/1000,"Ki":1/1024,"M":1000,"Mi":1024,"G":1000**2,"Gi":1024**2}[unit] if unit else 1
print(int(n*1024//mul) if mul<1 else int(n*mul//1024))' "$value"
}
```

**Step 2: Verify syntax and the helpers**

Run: `bash -n categories/apps/steps/install-mailu/run.sh` and:
```bash
source <(sed -n '1,9p;/cpu_to_millicores/,/^}/p' categories/apps/steps/install-mailu/run.sh)
```
then manually: `cpu_to_millicores 750m` → `750`; `cpu_to_millicores 2` → `2000`; `mem_to_mib 1664Mi` → `1664`; `mem_to_mib 1Gi` → `1024`; `mem_to_mib 22025760Ki` → `21509`.

Expected: all commands run without error and produce the expected integers.

**Step 3: Commit**

```bash
git add categories/apps/steps/install-mailu/run.sh
git commit -m "feat(mailu): add cpu/memory quantity parse helpers"
```

---

### Task 2: Rewrite `choose_mailu_storage_node` with disk + capacity selection

**Files:**
- Modify: `categories/apps/steps/install-mailu/run.sh:180-225` (replace the existing function body)

**Step 1: Replace the function**

```bash
choose_mailu_storage_node() {
  local label_value="$1"
  local existing_node candidates_json pods_json alloc_json
  local node used_cpu used_mem used_pods alloc_cpu alloc_mem alloc_pods
  local free_cpu free_mem free_pods free_disk best_node best_disk reason
  local required_pod_slots required_cpu_milli required_mem_mi

  # Idempotent: reuse an existing Ready storage node for this cluster.
  existing_node="$(
    kubectl get nodes -l "twinbox.io/mailu-storage-node=${label_value}" -o json |
      jq -r '
        .items[]
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | .metadata.name
      ' |
      head -n1
  )"
  if [[ -n "$existing_node" ]]; then
    printf '%s\n' "$existing_node"
    return 0
  fi

  # Must-fit budget for the pinned Mailu workloads (front/admin/postfix/dovecot/rspamd/webmail).
  required_pod_slots="${MAILU_PINNED_POD_SLOTS:-8}"
  required_cpu_milli="${MAILU_PINNED_CPU_MILLI:-1000}"
  required_mem_mi="${MAILU_PINNED_MEM_MIB:-2048}"

  candidates_json="$(kubectl get nodes -o json)"
  pods_json="$(kubectl get pods -A -o json)"

  best_node=""
  best_disk=-1

  for node in $(
    printf '%s' "$candidates_json" | jq -r '
      .items[]
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | select((.spec.unschedulable // false) == false)
      | select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) == false)
      | .metadata.name
    '
  ); do
    alloc_json="$(printf '%s' "$candidates_json" | jq -c --arg n "$node" '
      .items[] | select(.metadata.name == $n) | .status.allocatable
    ')"

    alloc_cpu="$(printf '%s' "$alloc_json" | jq -r '.cpu // "0"')"
    alloc_mem="$(printf '%s' "$alloc_json" | jq -r '.memory // "0"')"
    alloc_pods="$(printf '%s' "$alloc_json" | jq -r '.pods // "0"')"
    alloc_cpu="$(cpu_to_millicores "$alloc_cpu")"
    alloc_mem="$(mem_to_mib "$alloc_mem")"

    used_json="$(printf '%s' "$pods_json" | jq -c --arg n "$node" '
      [ .items[]
        | select((.spec.nodeName // "") == $n)
        | .spec.containers[]?
        | .resources.requests
      ] as $reqs
      | {
          pods: ([ .items[] | select((.spec.nodeName // "") == $n) ] | length),
          cpu_milli: ( [ $reqs[] | .cpu? // "0"
                         | if endswith("m") then (. | rtrimstr("m") | tonumber)
                           else (tonumber * 1000) end ] | add // 0 ),
          mem_mi: ( [ $reqs[] | .memory? // "0"
                      | if endswith("Ki") then (. | rtrimstr("Ki") | tonumber / 1024)
                        elif endswith("Mi") then (. | rtrimstr("Mi") | tonumber)
                        elif endswith("Gi") then (. | rtrimstr("Gi") | tonumber * 1024)
                        elif endswith("Ti") then (. | rtrimstr("Ti") | tonumber * 1024 * 1024)
                        else (tonumber / 1024 / 1024) end ] | add // 0 )
        }
    ')"

    used_pods="$(printf '%s' "$used_json" | jq -r '.pods')"
    used_cpu="$(printf '%s' "$used_json" | jq -r '.cpu_milli')"
    used_mem="$(printf '%s' "$used_json" | jq -r '.mem_mi')"

    free_pods=$((alloc_pods - used_pods))
    free_cpu=$((alloc_cpu - used_cpu))
    free_mem=$((alloc_mem - used_mem))

    # Prefer Longhorn's true storage availability; fall back to ephemeral-storage.
    if kubectl -n longhorn-system get "nodes.longhorn.io/$node" >/dev/null 2>&1; then
      free_disk="$(
        kubectl -n longhorn-system get "nodes.longhorn.io/$node" -o json |
          jq '[.status.diskStatus[]?.storageAvailable // 0] | add // 0'
      )"
    else
      free_disk="$(
        kubectl get "nodes/$node" -o jsonpath='{.status.allocatable.ephemeral-storage}' 2>/dev/null
      )"
      free_disk="${free_disk:-0}"
    fi

    reason=""
    if [[ "$free_pods" -lt "$required_pod_slots" ]]; then
      reason="${reason} pods free=${free_pods}<${required_pod_slots}"
    fi
    if [[ "$free_cpu" -lt "$required_cpu_milli" ]]; then
      reason="${reason} cpu_milli free=${free_cpu}<${required_cpu_milli}"
    fi
    if [[ "$free_mem" -lt "$required_mem_mi" ]]; then
      reason="${reason} mem_mi free=${free_mem}<${required_mem_mi}"
    fi

    if [[ -n "$reason" ]]; then
      log "Mailu storage-node candidate ${node} rejected:${reason} (disk_mi=${free_disk})"
      continue
    fi

    if [[ "$free_disk" -gt "$best_disk" ]]; then
      best_disk="$free_disk"
      best_node="$node"
    fi
    log "Mailu storage-node candidate ${node} fits: disk_mi=${free_disk}, pods_free=${free_pods}, cpu_milli_free=${free_cpu}, mem_mi_free=${free_mem}"
  done

  if [[ -z "$best_node" ]]; then
    fail "No Ready schedulable worker has capacity to host Mailu. Required: pods>=${required_pod_slots}, cpu>=${required_cpu_milli}m, mem>=${required_mem_mi}Mi. See per-candidate log lines above. Free disk space or move workloads off full workers before retrying."
  fi

  log "Choosing ${best_node} as Mailu storage node (free disk ${best_disk} bytes)"
  kubectl label node "$best_node" "twinbox.io/mailu-storage-node=${label_value}" --overwrite >/dev/null
  printf '%s\n' "$best_node"
}
```

**Step 2: Verify syntax**

Run: `bash -n categories/apps/steps/install-mailu/run.sh`
Expected: exit code 0, no output.

**Step 3: Sanity-check the selection logic against the live cluster (dry, read-only)**

On the Management VM (safe read-only commands):

```bash
export KUBECONFIG=/opt/twinbox/bootstrap/secrets/cluster/prd/kubeconfig/kubeconfig
sudo bash -c 'source <(sed -n "/cpu_to_millicores()/,/^}/p;/mem_to_mib()/,/^}/p" /var/lib/twinbox/categories/apps/steps/install-mailu/run.sh)'
```

If the helpers are easily sourcable, run the two helper functions against the cluster's allocatable values by hand:
`cpu_to_millicores 9950m`, `cpu_to_millicores 1950m`, `mem_to_mib 22025760Ki`, `mem_to_mib 8118436Ki`, `mem_to_mib 9150636Ki`.

Expected: `9950`, `1950`, `21509`, `7928`, `8938` respectively (rounded approximations are fine).

**Step 4: Commit**

```bash
git add categories/apps/steps/install-mailu/run.sh
git commit -m "feat(mailu): pick storage node by capacity + free Longhorn disk"
```

---

### Task 3: Add contract tests for the new selection logic

**Files:**
- Modify: `tests/test_mailu_gitops.py` (append new tests)

**Step 1: Add the tests**

Append to `tests/test_mailu_gitops.py`:

```python
def test_mailu_installer_chooses_storage_node_by_capacity_and_disk():
    script = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "run.sh"
    ).read_text(encoding="utf-8")

    # Must-fit budget names are wired into the chooser.
    assert "MAILU_PINNED_POD_SLOTS:-8" in script
    assert "MAILU_PINNED_CPU_MILLI:-1000" in script
    assert "MAILU_PINNED_MEM_MIB:-2048" in script

    # Selection reads Longhorn storage, with ephemeral-storage fallback.
    assert "nodes.longhorn.io" in script
    assert "storageAvailable" in script
    assert "ephemeral-storage" in script


def test_mailu_installer_rejects_full_nodes_and_fails_loudly():
    script = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "run.sh"
    ).read_text(encoding="utf-8")

    # A node that cannot fit the pinned set is skipped, never silently chosen.
    assert "rejected:" in script
    assert "free_pods" in script
    assert "free_cpu" in script
    assert "free_mem" in script

    # If nothing fits the installer fails with a clear diagnostic.
    assert "No Ready schedulable worker has capacity to host Mailu" in script
```

**Step 2: Run the new tests**

Run: `python3 -m pytest -q tests/test_mailu_gitops.py::test_mailu_installer_chooses_storage_node_by_capacity_and_disk tests/test_mailu_gitops.py::test_mailu_installer_rejects_full_nodes_and_fails_loudly -v`
Expected: 2 passed.

**Step 3: Run the full mailu + general suite**

Run: `python3 -m pytest -q tests`
Expected: all pass, no regressions in the existing Mailu installer assertions (`choose_mailu_storage_node` still present, `twinbox.io/mailu-storage-node` still present, etc.).

**Step 4: Commit**

```bash
git add tests/test_mailu_gitops.py
git commit -m "test(mailu): assert capacity-aware storage node selection"
```

---

### Task 4: Lint, full verification, and push

**Files:** none (verification only)

**Step 1: Run all verification per AGENTS.md**

```bash
bash -n categories/apps/steps/install-mailu/run.sh
python3 -m pytest -q tests
```

Expected: both pass.

**Step 2: Push to `main`**

```bash
git push origin main
```

**Step 3: Watch the GitHub Actions "Publish Docker Images" workflow**

Wait for it to go green before any Management VM refresh. Do NOT pull images before the workflow succeeds.

---

### Task 5: Deploy to the Management VM and re-run Mailu on `prd`

**Files:** none (runtime operations on `twinbox@192.168.2.70`)

**Step 1: Refresh the stack on the Management VM**

SN as `twinbox`, after the publish workflow is green:

```bash
sudo -n sh -lc 'cd /opt/twinbox && sudo -n sed -i "s/^TWINBOX_IMAGE_TAG=.*/TWINBOX_IMAGE_TAG=sha-<first-7-commit-chars>/" .env && docker compose pull && docker compose up -d'
```

Verify the tag is updated before pulling (`TWINBOX_IMAGE_TAG=sha-<tag> docker compose config --images`). Replace `<first-7-commit-chars>` with the real short SHA of the pushed commit.

**Step 2: Re-run the failed Mailu step on the live cluster**

Either re-trigger step `install-mailu` from the manager API/web, or manually repoint the label and re-sync:

```bash
export KUBECONFIG=/opt/twinbox/bootstrap/secrets/cluster/prd/kubeconfig/kubeconfig
sudo kubectl label node twinbox-prd-worker-1 twinbox.io/mailu-storage-node- >/dev/null 2>&1 || true
sudo kubectl label node twinbox-prd-worker-3 "twinbox.io/mailu-storage-node=prd" --overwrite
```

Then sync the Argo CD application (`argocd app sync mailu` or the netbird/argocd app refresh). Verify in `manager-web` that step `install-mailu` shows succeeded and all Mailu deployments become Ready on worker-3.

**Step 3: Confirm the fix lands correctly**

Run: `python3 -m pytest -q tests` locally again if anything changed during deploy, and confirm no Mailu pods remain `Pending`.

---

## Notes / gotchas

- Do not hard-code any node name — `kubectl get nodes` output drives everything, so the same script works on other clusters.
- Completed/`Succeeded` pods still count against `maxPods`; the `used_pods` count uses **all** pods bound to the node (any phase) so the worker-1 failure mode is caught.
- `storageAvailable` already subtracts Longhorn's `storageReserved` and scheduling reservations, so it is a truer "free bytes" signal than raw ephemeral-storage.
- The env-var budgets (`MAILU_PINNED_*`) allow future tuning without code edits and default to the conservative values above.