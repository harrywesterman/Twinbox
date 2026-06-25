# Mailu Passwordless Mailbox Auto-Creation

## Motivation

Twinbox is passwordless: Authentik users authenticate via passkeys (WebAuthn), not
passwords. But Mailu requires a password for every mailbox. Users should never
need to know their Mailu password — they log in to Roundcube webmail via
Authentik SSO.

This design adds automatic mailbox creation when users are created, with a
passwordless webmail experience backed by Authentik's forward-auth.

## Design Decisions

| Decision | Choice | Reasoning |
|----------|--------|-----------|
| Mailbox password | Random 24-char hex (never shown) | Users never use it; OIDC proxy auth handles login |
| Webmail auth | Traefik forwardAuth → Authentik → `X-Auth-Email` header → Mailu proxy auth | No passwords needed; reuses existing Authentik infra |
| New portal users | Best-effort: create mailbox if Mailu is installed, skip silently otherwise | Mailu is optional |
| Wizard first user | Bulk sync at end of `install-mailu/run.sh` | Mailu doesn't exist yet when the first user is created |
| Retroactive users | Bulk sync in installer + manual "Create mailbox" button in portal | Covers all cases |

## Architecture

### Component Overview

```
                    ┌──────────────────────┐
                    │   Portal server.mjs   │
                    │                       │
 ┌──────────┐  POST │ 1. Create Authentik   │
 │  Admin   │──────►│    user               │
 │  Browser │       │ 2. Create Mailu       │
 └──────────┘       │    mailbox (best-     │
                    │    effort via REST)    │
                    └──────┬────────────────┘
                           │
                    ┌──────▼────────────────┐
                    │    Mailu REST API      │
                    │  POST /api/v1/user     │
                    │  {email, raw_password, │
                    │   displayed_name}      │
                    └────────────────────────┘

 ┌──────────┐        ┌──────────────────────┐
 │  User    │───────►│  Traefik IngressRoute  │
 │  Browser │        │  mail.bierineenweek.nl │
 └──────────┘        │  → forwardAuth        │
                     │  → Authentik OIDC      │
                     │  → X-Auth-Email header │
                     └──────┬────────────────┘
                            │
                     ┌──────▼────────────────┐
                     │  Mailu Front (nginx)   │
                     │  PROXY_AUTH_HEADER:    │
                     │    X-authentik-email   │
                     │  PROXY_AUTH_CREATE:    │
                     │    true                │
                     └────────────────────────┘
```

### Data Flow: New User Creation (Portal)

```
POST /api/admin/users {username, name, email, groupNames}
  │
  ├─ 1. Authentik: createUser({username, name, email, is_active:true, ...})
  ├─ 2. Authentik: setPassword(userId, temporaryPassword)
  ├─ 3. Authentik: addUserToGroup() — per requested group
  │
  ├─ 4. [NEW] if email is set:
  │     ├─ isMailuInstalled() → checks step-state via manager API
  │     ├─ if installed: mailuCreateMailbox({email, randomPassword, displayedName})
  │     └─ if not installed: skip, log
  │
  └─ 5. Return {user, temporaryPassword}
```

### Data Flow: Bulk Sync (install-mailu/run.sh)

```
install-mailu/run.sh — after Mailu is deployed and healthy:
  │
  ├─ 1. Read api-token from OpenBao twinbox/global/mailu-runtime
  ├─ 2. Resolve mailu API base URL from mail.<zone>
  ├─ 3. Authentik: GET /core/users/ → list all users with email
  ├─ 4. Mailu: GET /api/v1/user/{email} → check if mailbox exists
  ├─ 5. For each user without a mailbox:
  │     ├─ generate random 24-char hex password
  │     └─ Mailu: POST /api/v1/user {email, raw_password, displayed_name}
  └─ 6. Log summary (N users synced, M already existed, K failed)
```

## Implementation Tasks

### Task 1: Mailu values — enable proxy auth

**File:** `gitops/values/mailu.yaml`

Set proxy auth so Traefik's OIDC-forwarded `X-authentik-email` header is trusted:

```yaml
proxyAuth:
  whitelist: "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  header: "X-authentik-email"
  create: "true"
```

### Task 2: Mailu Traefik — add Authentik forwardAuth

**Files:**
- `gitops/platform-apps/mailu/authentik-forwardauth-middleware.yaml` (new)
- `gitops/platform-apps/mailu/ingressroute.yaml` (edit)
- `gitops/platform-apps/mailu/kustomization.yaml` (edit)

Add the standard Authentik forwardAuth middleware (copy from `stirling-pdf`) and
apply it to the `mailu` and `mailu-netbird` IngressRoutes.

### Task 3: Portal — Mailu API client module

**File:** `portal/src/mailu-client.mjs` (new)

```js
// Functions:
// - isMailuInstalled(config)     → checks step-state via manager API
// - resolveMailuApiConfig()      → reads api-token from k8s secret + zone from config
// - mailuCreateMailbox(opts)     → POST /api/v1/user with {email, raw_password, displayed_name}
// - createRandomMailboxPassword()→ 24 hex chars from crypto.randomBytes
```

### Task 4: Portal — mailbox creation in user creation flow

**File:** `portal/server.mjs`

In `POST /api/admin/users` handler (after line 1414 — user created in Authentik):
- If `draft.email` is set, call `mailuCreateMailbox()` best-effort
- Log success/failure but don't fail the user creation

### Task 5: Portal — "Create mailbox" button in admin UI

**Files:**
- `portal/server.mjs` — new endpoint `POST /api/admin/users/:userId/create-mailbox`
- `portal/src/App.jsx` — add button to UserAdminPage that shows when Mailu is installed and user has email but no mailbox

### Task 6: install-mailu — bulk sync of existing users

**File:** `categories/apps/steps/install-mailu/run.sh`

Add a function `sync_mailu_mailboxes` called near the end of the installer (after
Mailu is confirmed healthy, before NetBird service creation). It:
1. Reads the api-token from OpenBao
2. Queries Authentik for all users with email addresses
3. For each, checks if a Mailu mailbox already exists
4. Creates missing mailboxes with random passwords

### Task 7: Tests

- Unit tests for `mailu-client.mjs`
- Integration test in `tests/test_mailu_gitops.py` for the bulk sync logic
- Frontend test for the "Create mailbox" button visibility

## Mailu REST API Reference

**Base URL:** `https://mail.<zone>/api/v1`
**Auth:** `Authorization: Bearer <api-token>`

**POST /api/v1/user** — Create user/mailbox:
```json
{
  "email": "user@bierineenweek.nl",
  "raw_password": "<random-24-hex>",
  "displayed_name": "John Doe",
  "enabled": true,
  "enable_imap": true,
  "enable_pop": false,
  "spam_enabled": true
}
```

Responses: `200` success, `409` duplicate (already exists), `401`/`403` auth, `400` validation.

**GET /api/v1/user/{email}** — Check if mailbox exists:
Returns `200` with user object if exists, `404` if not.

## Security Notes

- The random mailbox password is generated with `crypto.randomBytes(24)` and
  never stored or displayed. It's only used for the initial REST API call.
- The `api-token` is read from the Kubernetes secret `mailu-runtime` in namespace
  `mailu`, never hard-coded.
- Proxy auth whitelist in Mailu values is scoped to cluster-internal CIDRs only
  (`10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16`), preventing header spoofing from
  external sources.
