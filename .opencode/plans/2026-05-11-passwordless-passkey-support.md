# Passwordless / Passkey Support in Twinbox Portal

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable passkey (WebAuthn) passwordless login for Twinbox Portal users through Authentik, while keeping a temporary password as first-login fallback.

**Architecture:** Extend Authentik with blueprints that configure a WebAuthn setup stage, an authenticator validation stage, and a dedicated passwordless flow. Update the existing default authentication flow to support passkey autofill in the identification stage. Extend the portal backend to query WebAuthn devices and the frontend to display passkey status and improved onboarding guidance.

**Tech Stack:** Authentik 2026.2, Kubernetes ConfigMaps/blueprints, Node.js/Express, React

---

## Context

- Authentik runs in the `authentik` namespace via Helm chart `2026.2.2`.
- Existing blueprints are mounted from `gitops/apps/authentik/manifests/blueprint-twinbox-automation.yaml`.
- The portal creates users via `POST /api/admin/users` and returns a temporary password (`Tbx-...`).
- The portal login is OIDC (`openid profile email`) through Authentik.
- Authentik 2025.12+ supports passkey autofill (conditional UI) in the Identification stage.
- A user **must** log in once (with the temporary password) to register a passkey before they can use passwordless login.

---

## Task 1: Add WebAuthn/Passkey Blueprint

**Files:**
- Create: `gitops/apps/authentik/manifests/blueprint-passwordless.yaml`
- Modify: `gitops/apps/authentik/values.yaml`

**Step 1: Write the blueprint**

Create `gitops/apps/authentik/manifests/blueprint-passwordless.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-blueprint-passwordless
  namespace: authentik
  labels:
    blueprints.goauthentik.io/instances: "*"
data:
  passwordless.yaml: |
    version: 1
    metadata:
      name: twinbox-passwordless
      labels:
        blueprints.goauthentik.io/description: |
          Configures WebAuthn stages, a passwordless authentication flow,
          and updates the default identification stage to support passkey autofill.
    entries:
      # --- WebAuthn authenticator setup stage ---
      - id: twinbox-webauthn-setup
        model: authentik_stages_authenticator_webauthn.authenticatorwebauthnstage
        state: present
        identifiers:
          name: twinbox-webauthn-setup
        attrs:
          friendly_name: "Twinbox Passkey Setup"
          user_verification: preferred
          resident_key_requirement: preferred
          authenticator_attachment: ""

      # --- Authenticator validation stage (for passwordless flow) ---
      - id: twinbox-passwordless-validation
        model: authentik_stages_authenticator_validate.authenticatorvalidatestage
        state: present
        identifiers:
          name: twinbox-passwordless-validation
        attrs:
          device_classes:
            - webauthn
          not_configured_action: deny
          last_auth_threshold: seconds=0

      # --- Passwordless authentication flow ---
      - id: twinbox-passwordless-flow
        model: authentik_flows.flow
        state: present
        identifiers:
          slug: twinbox-passwordless
        attrs:
          name: "Twinbox Passwordless"
          title: "Log in with your passkey"
          designation: authentication
          authentication: require_authenticated
          policy_engine_mode: any
          compatibility_mode: true

      # --- Bind validation stage to passwordless flow ---
      - id: twinbox-passwordless-flow-binding-validation
        model: authentik_flows.flowstagebinding
        state: present
        identifiers:
          target: !KeyOf twinbox-passwordless-flow
          stage: !KeyOf twinbox-passwordless-validation
          order: 10

      # --- Bind user login stage to passwordless flow ---
      - id: twinbox-passwordless-flow-binding-login
        model: authentik_flows.flowstagebinding
        state: present
        identifiers:
          target: !KeyOf twinbox-passwordless-flow
        attrs:
          order: 20
        # Use the default user-login stage which already exists; we reference it by name
        identifiers:
          target: !KeyOf twinbox-passwordless-flow
          stage: !Find [authentik_stages_user_login.userloginstage, [name, "default-authentication-login"]]
          order: 20

      # --- Update default identification stage to support passkey autofill ---
      # We look up the default-authentication-identification stage by name and patch it.
      - id: twinbox-default-identification-passkey
        model: authentik_stages_identification.identificationstage
        state: updated
        identifiers:
          name: "default-authentication-identification"
        attrs:
          passwordless_flow: !KeyOf twinbox-passwordless-flow
```

**Step 2: Register the new blueprint in values.yaml**

Modify `gitops/apps/authentik/values.yaml`:

```yaml
blueprints:
  configMaps:
    - authentik-blueprint-twinbox-automation
    - authentik-blueprint-passwordless
```

**Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('gitops/apps/authentik/manifests/blueprint-passwordless.yaml'))"`
Expected: No output (success).

**Step 4: Commit**

```bash
git add gitops/apps/authentik/manifests/blueprint-passwordless.yaml gitops/apps/authentik/values.yaml
git commit -m "feat(authentik): add passwordless passkey flow blueprint"
```

---

## Task 2: Extend Portal Backend to Query WebAuthn Devices

**Files:**
- Modify: `portal/authentik-admin.mjs`
- Modify: `portal/server.mjs`
- Modify: `portal/test/server.test.mjs`

**Step 1: Add WebAuthn device query to the Authentik client**

In `portal/authentik-admin.mjs`, add inside the `createAuthentikAdminClient` return object:

```js
    listWebAuthnDevices(userId) {
      return request("GET", `/authenticators/admin/webauthn/?page_size=200&user=${encodeURIComponent(userId)}`);
    },
```

**Step 2: Add passkey status to the user listing endpoint**

In `portal/server.mjs`, update the user listing (`/api/admin/users`) to include whether each user has a registered passkey.

Replace the existing `app.get("/api/admin/users", ...)` handler around line 1079-1097 with an async helper and updated handler:

```js
async function enrichUsersWithPasskeyStatus(users, client) {
  const enriched = [];
  for (const user of users) {
    try {
      const devices = await client.listWebAuthnDevices(user.id);
      const hasPasskey = Array.isArray(devices?.results) && devices.results.length > 0;
      enriched.push({ ...user, hasPasskey });
    } catch {
      enriched.push({ ...user, hasPasskey: false });
    }
  }
  return enriched;
}

app.get("/api/admin/users", async (req, res) => {
  const session = requireAdminSession(req, res);
  if (!session) {
    return;
  }

  try {
    const config = await loadPortalConfig();
    const directory = await loadUserAdminDirectory(config);
    const client = getAuthentikAdminClient();
    const users = await enrichUsersWithPasskeyStatus(directory.users, client);
    res.json({
      users,
      groups: directory.groups,
      generatedAt: new Date().toISOString(),
    });
  } catch (error) {
    res
      .status(error?.status || 500)
      .json({ error: error instanceof Error ? error.message : "failed to load users" });
  }
});
```

Also update `loadUserAdminDirectory` or the caller so the groups are returned (the current code returns `directory.users` only; we now need `directory.groups` too).

**Step 3: Update tests**

In `portal/test/server.test.mjs`, add a mock endpoint for the WebAuthn device query in the fake Authentik server:

```js
  if (req.method === "GET" && pathname === "/api/v3/authenticators/admin/webauthn/") {
    sendJson(res, 200, { results: [] });
    return;
  }
```

Update the test around line 762 to also assert that the created user initially has `hasPasskey: false`.

Run tests: `node --test portal/test/server.test.mjs`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add portal/authentik-admin.mjs portal/server.mjs portal/test/server.test.mjs
git commit -m "feat(portal): query and expose WebAuthn device status per user"
```

---

## Task 3: Update Portal Frontend for Passkey Visibility

**Files:**
- Modify: `portal/src/App.jsx`

**Step 1: Display passkey status in the user list**

In `portal/src/App.jsx`, update the user list rendering (around the user admin table) to show a passkey badge/icon when `user.hasPasskey` is true.

Add a small helper or inline indicator, e.g.:

```jsx
{user.hasPasskey ? (
  <span className="passkey-badge" title="Passkey registered">🔐</span>
) : (
  <span className="passkey-missing" title="No passkey yet">—</span>
)}
```

**Step 2: Update onboarding copy after user creation**

Update the `temporaryPassword` success banner around line 2717 to include a short passkey instruction:

```jsx
{temporaryPassword ? (
  <div className="inline-notice is-accent">
    <strong>
      Temporary password for{" "}
      {temporaryPassword.user?.name || temporaryPassword.user?.username}
    </strong>
    <code>{temporaryPassword.password}</code>
    <span>
      Show this once to the user. After first login they should register a passkey in Authentik.
    </span>
    <button
      type="button"
      className="secondary-button"
      onClick={() => setTemporaryPassword(null)}
    >
      Hide password
    </button>
  </div>
) : null}
```

**Step 3: Build check**

Run: `npm run build --prefix portal`
Expected: Build succeeds with no errors.

**Step 4: Commit**

```bash
git add portal/src/App.jsx
git commit -m "feat(portal): show passkey status and improved onboarding copy"
```

---

## Task 4: Update Portal Settings Links

**Files:**
- Modify: `portal/src/App.jsx`

**Step 1: Rename "Enable 2FA" to "Manage Authenticators"**

In `portal/src/App.jsx` around line 880, update the link card:

```jsx
<a
  className="link-card"
  href={config?.settings?.authentikOtpUrl || "#"}
  target="_blank"
  rel="noreferrer"
>
  <strong>Manage Authenticators</strong>
  <span>Set up passkeys, TOTP, and other authentication methods.</span>
</a>
```

**Step 2: Build check**

Run: `npm run build --prefix portal`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add portal/src/App.jsx
git commit -m "feat(portal): rename 2FA link to Manage Authenticators"
```

---

## Task 5: Test End-to-End Blueprint Validity

**Files:**
- (no new files)

**Step 1: Lint the new blueprint**

Run: `python3 -c "import yaml; yaml.safe_load(open('gitops/apps/authentik/manifests/blueprint-passwordless.yaml'))"`
Expected: No errors.

**Step 2: Validate the updated values file**

Run: `helm lint gitops/apps/authentik/charts/authentik-2026.2.2/authentik -f gitops/apps/authentik/values.yaml`
Expected: No errors (lint passes). If `helm` is unavailable, verify the YAML structure manually.

**Step 3: Run portal tests**

Run: `node --test portal/test/*.mjs`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add -A
git commit -m "test: verify blueprint and portal tests pass"
```

---

## Deployment Notes

1. After merging to `main`, wait for the GitHub Actions "Publish Docker Images" workflow to complete for the portal image.
2. Refresh the Authentik app in Argo CD so the new blueprint ConfigMap is picked up; the Authentik worker will reconcile it automatically.
3. The blueprint references existing managed objects (`default-authentication-identification`, `default-authentication-login`) using `!Find` lookups. If those names differ in your Authentik instance, adjust the blueprint `identifiers` accordingly.
4. Passkey autofill requires **HTTPS** on the Authentik endpoint. Ensure `authentik.__ZONE_NAME__` serves over TLS (it already does via `websecure` entrypoint).
5. Users must log in once with their temporary password, then navigate to **User interface > Settings > MFA/Authenticators** to register a passkey. After that, the browser will offer passkey autofill on the login screen.

---

## Rollback Plan

- Remove `authentik-blueprint-passwordless` from `values.yaml` blueprints list.
- Delete the `blueprint-passwordless.yaml` ConfigMap manifest.
- Revert the portal commits.
- The default flows remain untouched because the blueprint used `state: updated` only on the identification stage; removing the blueprint does not auto-revert that change. If needed, manually unset `passwordless_flow` on the `default-authentication-identification` stage in the Authentik admin UI.
