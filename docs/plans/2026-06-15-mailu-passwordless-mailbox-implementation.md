# Mailu Passwordless Mailbox Auto-Creation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically create Mailu mailboxes when Authentik users are created, with passwordless Roundcube login via Authentik OIDC proxy auth.

**Architecture:** 7 tasks — Mailu values → Traefik middleware → Portal client module → Portal API integration → Portal UI button → Bulk sync in installer → Tests. Each mailbox gets a random password; users authenticate via Traefik forwardAuth injecting `X-authentik-email` header into Mailu.

**Tech Stack:** Kubernetes YAML (Kustomize), Node.js (Express), React, Bash, shell scripting

**Design doc:** `docs/plans/2026-06-15-mailu-passwordless-mailbox-design.md`

---

### Task 1: Enable Mailu proxy auth in Helm values

**Files:**
- Modify: `gitops/values/mailu.yaml:55-58`

**Step 1: Update proxyAuth values**

Change from:
```yaml
proxyAuth:
  whitelist: ""
  header: ""
  create: "false"
```

To:
```yaml
proxyAuth:
  whitelist: "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  header: "X-authentik-email"
  create: "true"
```

**Step 2: Commit**

```bash
git add gitops/values/mailu.yaml
git commit -m "feat(mailu): enable proxy auth for passwordless webmail login"
```

---

### Task 2: Add Authentik forwardAuth middleware to Mailu IngressRoutes

**Files:**
- Create: `gitops/platform-apps/mailu/authentik-forwardauth-middleware.yaml`
- Modify: `gitops/platform-apps/mailu/ingressroute.yaml:8-33`
- Modify: `gitops/platform-apps/mailu/kustomization.yaml:12`

**Step 1: Create the forwardAuth middleware**

Copy the pattern from `gitops/platform-apps/stirling-pdf/authentik-forwardauth-middleware.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forwardauth
  namespace: mailu
spec:
  forwardAuth:
    address: "http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik"
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
```

Write to `gitops/platform-apps/mailu/authentik-forwardauth-middleware.yaml`.

**Step 2: Add middleware to kustomization.yaml**

In `gitops/platform-apps/mailu/kustomization.yaml`, add at end of `resources:`:
```yaml
  - authentik-forwardauth-middleware.yaml
```

**Step 3: Add middlewares to both IngressRoutes**

In `gitops/platform-apps/mailu/ingressroute.yaml`:

For the `mailu` IngressRoute, add after `routes:` and before the route entry:
```yaml
    middlewares:
      - name: authentik-forwardauth
```

For the `mailu-netbird` IngressRoute, same addition.

These go inside the `spec:` of each IngressRoute, at the same indentation level as `routes:`.

**Step 4: Validate with kustomize**

```bash
kubectl kustomize gitops/platform-apps/mailu/ >/dev/null 2>&1 && echo OK
```

**Step 5: Commit**

```bash
git add gitops/platform-apps/mailu/
git commit -m "feat(mailu): add Authentik forwardAuth middleware for passwordless webmail"
```

---

### Task 3: Create Mailu API client module for Portal

**Files:**
- Create: `portal/src/mailu-client.mjs`
- Create: `portal/test/mailu-client.test.mjs`

**Step 1: Write failing test**

Write `portal/test/mailu-client.test.mjs`:

```js
import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const workspaceRoot = process.env.TEST_WORKSPACE || path.join(repoRoot, "test-tmp");

let mailuApiBase;
let mailuServer;
let lastRequest;

function startMailuMock() {
  return new Promise((resolve) => {
    mailuServer = http.createServer((req, res) => {
      lastRequest = { method: req.method, url: req.url, headers: req.headers, body: "" };
      req.on("data", (chunk) => { lastRequest.body += chunk; });
      req.on("end", () => {
        if (req.url === "/api/v1/user" && req.method === "POST") {
          try {
            const payload = JSON.parse(lastRequest.body);
            if (payload.email === "existing@test.com") {
              res.writeHead(409, { "Content-Type": "application/json" });
              res.end(JSON.stringify({ code: 409, message: "Duplicate user" }));
            } else {
              res.writeHead(200, { "Content-Type": "application/json" });
              res.end(JSON.stringify({ code: 200, message: "ok" }));
            }
          } catch {
            res.writeHead(400, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ code: 400, message: "Bad request" }));
          }
        } else {
          res.writeHead(404);
          res.end("{}");
        }
      });
    });
    mailuServer.listen(0, "127.0.0.1", () => {
      const addr = mailuServer.address();
      mailuApiBase = `http://127.0.0.1:${addr.port}`;
      resolve();
    });
  });
}

test.before(async () => {
  await startMailuMock();
});

test.after(() => {
  if (mailuServer) {
    mailuServer.close();
  }
});

test("createRandomMailboxPassword returns 48 hex chars", () => {
  const { createRandomMailboxPassword } = requireMailuClient();
  const pwd = createRandomMailboxPassword();
  assert.equal(pwd.length, 48);
  assert.match(pwd, /^[0-9a-f]+$/);
  const pwd2 = createRandomMailboxPassword();
  assert.notEqual(pwd, pwd2);
});

test("resolveMailuApiConfig returns correct base URL and token", () => {
  // We test this indirectly by passing env vars
  process.env.MAILU_API_BASE_URL = "https://mail.test.example/api";
  process.env.MAILU_API_TOKEN = "test-token-abc";
  const { resolveMailuApiConfig } = requireMailuClient();
  const cfg = resolveMailuApiConfig();
  assert.equal(cfg.baseUrl, "https://mail.test.example/api/v1");
  assert.equal(cfg.token, "test-token-abc");
});

test("isMailuInstalled returns true when token is set", () => {
  process.env.MAILU_API_TOKEN = "some-token";
  const { isMailuInstalled } = requireMailuClient();
  assert.equal(isMailuInstalled(), true);
  delete process.env.MAILU_API_TOKEN;
});

test("isMailuInstalled returns false when token is empty", () => {
  process.env.MAILU_API_TOKEN = "";
  const { isMailuInstalled } = requireMailuClient();
  assert.equal(isMailuInstalled(), false);
});

test("mailuCreateMailbox succeeds for new user", async () => {
  process.env.MAILU_API_BASE_URL = mailuApiBase;
  process.env.MAILU_API_TOKEN = "test-token";
  const { mailuCreateMailbox } = requireMailuClient();
  const result = await mailuCreateMailbox({
    email: "new@test.com",
    rawPassword: "abc123",
    displayedName: "Test User",
  });
  assert.equal(result.ok, true);
  assert.equal(lastRequest.method, "POST");
  assert.equal(lastRequest.url, "/api/v1/user");
});

test("mailuCreateMailbox returns exists for duplicate", async () => {
  const { mailuCreateMailbox } = requireMailuClient();
  const result = await mailuCreateMailbox({
    email: "existing@test.com",
    rawPassword: "abc123",
    displayedName: "Test User",
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "already-exists");
});

function requireMailuClient() {
  const mailuClientPath = path.join(repoRoot, "portal", "src", "mailu-client.mjs");
  delete require.cache[require.resolve(mailuClientPath)];
  return require(mailuClientPath);
}
```

**Step 2: Run test to confirm it fails**

```bash
node --test portal/test/mailu-client.test.mjs
```

Expected: FAIL with "Cannot find module" for `mailu-client.mjs`.

**Step 3: Implement the mailu-client module**

Write `portal/src/mailu-client.mjs`:

```js
import crypto from "crypto";

export function createRandomMailboxPassword() {
  return crypto.randomBytes(24).toString("hex");
}

export function resolveMailuApiConfig() {
  const baseUrl = String(process.env.MAILU_API_BASE_URL || "").trim();
  const token = String(process.env.MAILU_API_TOKEN || "").trim();
  return {
    baseUrl: baseUrl.replace(/\/+$/, "") + "/v1",
    token,
  };
}

export function isMailuInstalled() {
  return Boolean(String(process.env.MAILU_API_TOKEN || "").trim());
}

export async function mailuCreateMailbox({ email, rawPassword, displayedName, enabled }) {
  const { baseUrl, token } = resolveMailuApiConfig();
  if (!token) {
    return { ok: false, reason: "no-api-token" };
  }

  const body = JSON.stringify({
    email,
    raw_password: rawPassword,
    displayed_name: displayedName || email.split("@")[0],
    enabled: enabled !== false,
    enable_imap: true,
    enable_pop: false,
    spam_enabled: true,
  });

  try {
    const response = await fetch(`${baseUrl}/user`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body,
    });

    if (response.status === 409) {
      return { ok: false, reason: "already-exists" };
    }
    if (!response.ok) {
      const errorBody = await response.text().catch(() => "");
      return { ok: false, reason: `http-${response.status}`, detail: errorBody };
    }
    return { ok: true };
  } catch (error) {
    return { ok: false, reason: "network-error", detail: error.message };
  }
}
```

**Step 4: Run test to verify it passes**

```bash
node --test portal/test/mailu-client.test.mjs
```

Expected: All 6 tests PASS.

**Step 5: Commit**

```bash
git add portal/src/mailu-client.mjs portal/test/mailu-client.test.mjs
git commit -m "feat(portal): add Mailu API client module with passwordless mailbox creation"
```

---

### Task 4: Integrate mailbox creation into portal user creation flow

**Files:**
- Modify: `portal/server.mjs:1-16` (add import)
- Modify: `portal/server.mjs:1420-1429` (add mailbox creation call)
- Modify: `portal/server.mjs` (add new endpoint for manual mailbox creation)

**Step 1: Add import at top of server.mjs**

After line 15 (`} from "./authentik-admin.mjs";`), add:
```js
import { createRandomMailboxPassword, isMailuInstalled, mailuCreateMailbox } from "./mailu-client.mjs";
```

**Step 2: Add mailbox creation in user creation handler**

After line 1428 (the `}` closing the group assignment loop, before the directory reload), insert:

```js
    if (draft.email && isMailuInstalled()) {
      const mailboxPassword = createRandomMailboxPassword();
      mailuCreateMailbox({
        email: draft.email,
        rawPassword: mailboxPassword,
        displayedName: draft.name || draft.username,
      }).then(
        (result) => {
          if (result.ok) {
            console.log(`Mailu mailbox created for ${draft.email}`);
          } else {
            console.warn(`Mailu mailbox not created for ${draft.email}: ${result.reason}`);
          }
        }
      ).catch(
        (err) => console.warn(`Mailu mailbox creation error for ${draft.email}:`, err.message)
      );
    }
```

The mailbox creation runs asynchronously (fire-and-forget) so it doesn't slow down the user creation response.

**Step 3: Add manual mailbox creation endpoint**

After line 1440 (`});` closing the `POST /api/admin/users` handler), add:

```js
app.post("/api/admin/users/:userId/create-mailbox", async (req, res) => {
  const session = requirePortalCapability(
    req, res, "canManageUsers", "user management access required"
  );
  if (!session) return;

  try {
    if (!isMailuInstalled()) {
      return res.status(400).json({ error: "Mailu is not installed" });
    }

    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    const user = directory.users.find(
      (u) => u.id === req.params.userId || u.pk === req.params.userId
    );
    if (!user) {
      return res.status(404).json({ error: "User not found" });
    }
    if (!user.email) {
      return res.status(400).json({ error: "User has no email address" });
    }

    const mailboxPassword = req.body?.password?.trim() || createRandomMailboxPassword();
    const result = await mailuCreateMailbox({
      email: user.email,
      rawPassword: mailboxPassword,
      displayedName: user.name || user.username,
    });

    if (result.ok) {
      res.json({ ok: true, email: user.email });
    } else if (result.reason === "already-exists") {
      res.json({ ok: true, email: user.email, note: "Mailbox already exists" });
    } else {
      res.status(500).json({ error: `Failed to create mailbox: ${result.reason}` });
    }
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : "Unknown error" });
  }
});
```

**Step 4: Run existing portal tests to verify no regressions**

```bash
node --test portal/test/server.test.mjs
```

Expected: All existing tests PASS.

**Step 5: Commit**

```bash
git add portal/server.mjs
git commit -m "feat(portal): auto-create Mailu mailbox on user creation, add manual create endpoint"
```

---

### Task 5: Add "Create mailbox" button to Portal admin UI

**Files:**
- Modify: `portal/src/App.jsx` — UserAdminPage component (around lines 2808–3368)

**Step 1: Find the user list rendering area**

The `UserAdminPage` component renders user rows. Each row has action buttons (e.g., "Disable", "Restart onboarding"). We need to add a "Create mailbox" button.

Search for the existing action button pattern in the user list (around the table/row rendering in UserAdminPage).

**Step 2: Add Mailu status to the view model**

In `portal/src/user-admin-model.js`, function `buildUserAdminViewModel`, add a field to indicate whether Mailu is installed. This can be passed from the frontend config or loaded separately.

For simplicity, add a new state variable in App.jsx:

```jsx
const [mailuInstalled, setMailuInstalled] = useState(false);
```

And load it from config or check on mount. The simplest approach: add a `mailuEnabled` flag to the portal config JSON. Or: add a new endpoint `GET /api/mailu-status` in server.mjs that checks `isMailuInstalled()`.

**Step 3: Add the button**

In the user row, add a button (visible only when `mailuInstalled && user.email`):

```jsx
{mailuInstalled && user.email && (
  <button
    type="button"
    className="secondary-button"
    onClick={() => handleCreateMailbox(user)}
    title="Create Mailu mailbox"
  >
    Create mailbox
  </button>
)}
```

The `handleCreateMailbox` function calls `POST /api/admin/users/:userId/create-mailbox`.

**Step 4: Commit**

```bash
git add portal/src/App.jsx portal/src/user-admin-model.js
git commit -m "feat(portal): add Create mailbox button in user admin UI"
```

---

### Task 6: Bulk sync existing users during Mailu install

**Files:**
- Modify: `categories/apps/steps/install-mailu/run.sh`

**Step 1: Add sync function**

Insert this function definition near the other utility functions (before the main flow):

```bash
sync_mailu_mailboxes() {
  local mail_domain="$1"
  local api_token="$2"
  local api_base="https://mail.${mail_domain}/api/v1"

  log "Syncing Mailu mailboxes for existing Authentik users"

  local users_json
  users_json="$(authentik_api GET /core/users/ 2>/dev/null | jq '[.results[] | select(.email != null and .email != "") | {email, name, username}]')"
  if [[ -z "$users_json" || "$users_json" == "null" || "$users_json" == "[]" ]]; then
    log "No Authentik users with email addresses found; skipping mailbox sync"
    return 0
  fi

  local total=0 created=0 existed=0 failed=0
  total="$(jq length <<<"$users_json")"
  log "Found ${total} Authentik user(s) with email to sync"

  while IFS= read -r user_entry; do
    local email name displayed
    email="$(jq -r '.email' <<<"$user_entry")"
    name="$(jq -r '.name // .username' <<<"$user_entry")"
    displayed="${name:-$email}"

    local check_status
    check_status="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${api_token}" \
      "${api_base}/user/$(printf '%s' "$email" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')" 2>/dev/null || echo "000")"

    if [[ "$check_status" == "200" ]]; then
      existed=$((existed + 1))
      log "  SKIP ${email}: mailbox already exists"
      continue
    fi

    local raw_password
    raw_password="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"

    local create_status
    create_status="$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${api_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg email "$email" --arg pwd "$raw_password" --arg name "$displayed" \
        '{email: $email, raw_password: $pwd, displayed_name: $name, enabled: true, enable_imap: true, enable_pop: false, spam_enabled: true}')" \
      "${api_base}/user" 2>/dev/null || echo "000")"

    if [[ "$create_status" == "200" ]]; then
      created=$((created + 1))
      log "  OK   ${email}: mailbox created"
    else
      failed=$((failed + 1))
      log "  FAIL ${email}: HTTP ${create_status}"
    fi
  done < <(jq -c '.[]' <<<"$users_json")

  log "Mailbox sync complete: ${total} total, ${created} created, ${existed} existed, ${failed} failed"
}
```

**Step 2: Call sync function at the right point**

After the DNS records have been applied (around line 631, after `apply_mail_dns_records`) and before `ensure-netbird-service.sh`, add:

```bash
log "Syncing existing Authentik users to Mailu"
sync_mailu_mailboxes "$mail_domain" "$(jq -r '."api-token"' "$runtime_secret_file")"
log "Mailu mailbox sync complete"
```

**Step 3: Validate script syntax**

```bash
bash -n categories/apps/steps/install-mailu/run.sh
```

**Step 4: Commit**

```bash
git add categories/apps/steps/install-mailu/run.sh
git commit -m "feat(mailu): bulk sync existing Authentik users to Mailu during install"
```

---

### Task 7: Update portal deployment for Mailu API token

**Files:**
- Modify: `gitops/platform-apps/twinbox-portal/externalsecret.yaml`
- Modify: `gitops/platform-apps/twinbox-portal/deployment.yaml`

**Step 1: Add Mailu token to ExternalSecret**

In `gitops/platform-apps/twinbox-portal/externalsecret.yaml`, add after line 38 (`property: AUTHENTIK_API_TOKEN`):

```yaml
    - secretKey: MAILU_API_BASE_URL
      remoteRef:
        key: twinbox/global/mailu-runtime
        property: MAILU_API_BASE_URL
    - secretKey: MAILU_API_TOKEN
      remoteRef:
        key: twinbox/global/mailu-runtime
        property: api-token
```

Note: The `MAILU_API_BASE_URL` value will be set in the `twinbox/global/mailu-runtime` OpenBao secret by the install-mailu run.sh. We need to ensure that script writes this value.

**Step 2: In install-mailu/run.sh, add MAILU_API_BASE_URL to the runtime secret**

Around line 515-521 in run.sh (where `mailu-runtime` secret is written to OpenBao), add `MAILU_API_BASE_URL`:

```bash
"api-token": $api_token,
"initial-admin-password": $initial_admin_password,
"MAILU_API_BASE_URL": "https://mail.${mail_domain}/api"
```

**Step 3: Verify deployment yaml already uses envFrom portal-bootstrap**

The portal deployment at `gitops/platform-apps/twinbox-portal/deployment.yaml` already has:
```yaml
envFrom:
  - secretRef:
      name: portal-bootstrap
```

This automatically picks up any new keys added to the ExternalSecret, so no changes needed in deployment.yaml.

**Step 4: Commit**

```bash
git add gitops/platform-apps/twinbox-portal/externalsecret.yaml categories/apps/steps/install-mailu/run.sh
git commit -m "feat(portal): wire Mailu API token into portal via ExternalSecret"
```

---

### Task 8: Run full test suites

**Step 1: Run portal unit tests**

```bash
node --test portal/test/*.mjs
```

Expected: All tests PASS (including new mailu-client tests).

**Step 2: Run Python tests**

```bash
python3 -m pytest -q tests/test_mailu_gitops.py
```

Expected: All 14 tests PASS.

**Step 3: Build portal**

```bash
npm run build --prefix portal
```

Expected: Build succeeds with no errors.

**Step 4: Validate all changed shell scripts**

```bash
bash -n categories/apps/steps/install-mailu/run.sh
bash -n scripts/manager/configure-bastion-mailu-postfix.sh
```

---

### Task 9: Commit final state and verify

```bash
git status
git diff --stat
```

Push all changes:

```bash
git push
```
