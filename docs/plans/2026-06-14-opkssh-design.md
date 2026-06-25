# Design: opkssh-based SSH access to Management VM and Bastion via Authentik

**Date:** 2026-06-14
**Status:** Design — approved for implementation
**Owner:** Twinbox maintainers
**Supersedes:** the static SSH key + password model for browser-SSH access via Termix

---

## 1. Problem statement

The Twinbox platform currently exposes SSH access to two privileged hosts — the **Management VM** (a Proxmox VM running the wizard containers) and the **Bastion** (a Hetzner VPS running self-hosted NetBird) — through Termix (`https://termix.<zone>`), the in-cluster browser SSH front-end.

The current authentication model has these weaknesses:

- The **Management VM** accepts password auth (`ansible/management-vm-maintenance.yml:108-120`) with a long-lived `PasswordAuthentication yes` setting. The password is the one written to `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json` at `wizard/setup-wizard.sh:1463`. It is also the password of the first Authentik user, so a leak of one compromises both. Brute force, accidental log print, and shared-secret rotation are all real risks.
- The **Bastion** accepts a static ed25519 key generated at `categories/talos-cluster/steps/provision-netbird-bastion/run.sh:288-298` and stored under `SSH_PRIVATE_KEY` in `netbird-bastion-<cluster-id>.json`. Anyone with that key (and NetBird access) can `ssh root@bastion` without any further authentication. There is no MFA, no per-user attribution, and no time-bound access.
- Both hosts have a single shared credential for all admin users. There is no per-user audit trail at the SSH layer. Revoking one user's access requires rotating the shared secret for everyone.
- Authentik (`https://authentik.<zone>`) is already the cluster's OIDC IdP and enforces MFA on most apps via Traefik `forwardAuth` and OIDC integrations, but **none of that protection extends to the SSH layer**. An operator on NetBird with the static key or password bypasses every identity check.

The goal is to make SSH to the management VM and bastion a **first-class Authentik-protected resource**: every SSH session requires a valid Authentik login (with MFA), is bound to a specific user, and uses a short-lived cryptographic credential that expires automatically.

The user has chosen:

| Decision | Value |
| --- | --- |
| SSH CA tool | **opkssh** (OpenPubkey-based, not step-ca) |
| Termix hosts to wire up | **Management VM** + **Bastion** (no change to existing host names) |
| Authentik gating group | existing **`admins`** group (no new group) |
| Cert validity | **16h default, 7d max** |
| Existing static creds | **removed from Termix**, retained on the hosts as break-glass backdoor |
| Migration | **3 phases**, additive, no lockout risk |
| Distribution | **Ansible playbooks** for the host-side config; new manager-script `setup-opkssh-authentik.sh` for the Authentik/Termix side |
| Scope | **only management VM + bastion**, Talos nodes stay on talosconfig |

The full research that produced these decisions is at `docs/plans/2026-06-14-opkssh-research.md`. Read that first if any section below is unclear.

---

## 2. Architecture

```
                                                                 ┌─────────────────────┐
                                                                 │   Authentik         │
   operator browser ──HTTPS─▶ Authentik (OIDC, MFA enforced)──────▶ OAuth2 provider    │
            │                       │                                app: opkssh         │
            │                       │ id_token (groups claim)        (dedicated client) │
            ▼                       ▼                                └────────┬──────────┘
   ┌─────────────────┐       ┌────────────────────┐                         │
   │ Termix (pod)    │       │ Management VM      │                         │ JWKS
   │ runs opkssh     │ ────▶ │ sshd + opkssh      │──── verifies PK Token ───┘ over
   │ login inside    │ SSH   │ verify (sshd       │     against Authentik     HTTPS
   │ the container   │       │ AuthorizedKeys-    │     at every
   │                 │       │ Command)           │     connection
   └─────────────────┘       └────────────────────┘
            │                                                 │
            │                          NetBird overlay ────────┤
            ▼                                                 ▼
   ┌─────────────────┐                                 ┌──────────────────┐
   │ opkssh client   │ ────────── SSH via NetBird ────▶ │ Bastion          │
   │ (Termix or      │            (100.64.0.0/10)      │ sshd + opkssh    │
   │  operator       │                                 │ verify           │
   │  laptop)        │                                 │                  │
   └─────────────────┘                                 └──────────────────┘
```

Key properties of this architecture:

- **No separate SSH CA server.** The Authentik JWKS endpoint is the trust root. opkssh wraps the OIDC `id_token` in a PK Token whose `nonce` claim commits to the user's fresh SSH public key. The server's `opkssh verify` re-fetches Authentik's JWKS on every connection and checks (a) the Authentik signature on the `id_token` and (b) the nonce binding to the cert's public key. See `docs/plans/2026-06-14-opkssh-research.md:1.2` and `:1.6`.
- **No CA private key to distribute or rotate.** The opkssh verifier extracts the user's public key from the cert's PK Token and presents it to `sshd` as a synthetic `cert-authority` line. The user's own key is what `sshd` ends up trusting, but the OP signature on the PK Token is what proves it. See `docs/plans/2026-06-14-opkssh-research.md:1.6`.
- **MFA is enforced at the OIDC layer.** If the Authentik flow does not complete MFA, no `id_token` is issued, and `opkssh login` cannot produce a cert. See `docs/plans/2026-06-14-opkssh-research.md:A.3`.
- **Group-based authorisation is declarative.** `/etc/opk/auth_id` lines of the form `twinbox oidc:groups:admins <issuer>` say "any user in the Authentik `admins` group may SSH as the Linux user `twinbox` on this host". See `docs/plans/2026-06-14-opkssh-research.md:8.1.1`.
- **Termix is already OPKSSH-capable.** Termix upstream ships OPKSSH support in `src/backend/ssh/opkssh-auth.ts` and `src/backend/ssh/opkssh-cert-auth.ts`. We just need to mount the right `~/.opk/config.yml` into the Termix container and switch the host auth type from "credential" to "OPKSSH" in `scripts/manager/setup-termix.sh`.

---

## 3. Components

### 3.1 New: `scripts/manager/setup-opkssh-authentik.sh`

Imperative script (matches the pattern of `scripts/manager/setup-termix-authentik.sh`) that:

1. Creates the Authentik OAuth2 application `opkssh` (slug `opkssh`, dedicated client ID, redirect URI `https://termix.<zone>/host/opkssh-callback`).
2. Creates the `groups` scope mapping (re-using or sharing the helper from `setup-termix-authentik.sh:255-265`).
3. Binds the `opkssh` application to the existing `admins` group.
4. Stores the OIDC client ID, client secret, issuer URL, and discovery URL in OpenBao at `twinbox/global/opkssh` and renders an ExternalSecret consumed by the Termix pod.
5. Renders the `~/.opk/config.yml` for the Termix container (committed to `gitops/platform-apps/termix/` after rendering, see §3.3).
6. Registers a new NetBird service `termix-opkssh` (the Termix OIDC callback URL needs to be reachable from operators' browsers; the existing `scripts/manager/ensure-netbird-service.sh` handles this).

### 3.2 New: `categories/talos-cluster/steps/install-opkssh/step.yaml` + `run.sh`

A new wizard step **`install-opkssh`** that:

1. Reads the OIDC client ID from the bootstrap secret created in §3.1.
2. SSHes into the management VM and runs the opkssh install script (idempotent, can be re-run).
3. SSHes into the bastion (via the existing ed25519 key, until Phase 3) and runs the same install script.
4. Writes `/etc/opk/auth_id` on both hosts (different content per host — see §3.4).
5. Verifies by attempting a no-op `opkssh verify` against a test cert (the wizard generates a throwaway key and a `VerifyPKToken` dry-run).

The step runs **after** `install-browser-ssh` in the talos-cluster journey, because it depends on Termix being up.

### 3.3 Modify: `gitops/platform-apps/termix/deployment.yaml` and `externalsecret.yaml`

- Add a `volume` and `volumeMount` for `/app/data/.opk/config.yml`.
- Add an entry to `externalsecret.yaml` that pulls the OIDC client ID/secret/issuer from OpenBao and renders the YAML.
- The provider block in `config.yml` follows the opkssh default shape, with `default_provider: authentik` and `redirect_uris: [http://localhost:3000/login-callback, http://localhost:10001/login-callback, http://localhost:11110/login-callback]`.
- The Termix callback URL `https://termix.<zone>/host/opkssh-callback` is registered in Authentik as the public redirect URI; opkssh's `--remote-redirect-uri` flag proxies the response to the localhost listener. See `docs/plans/2026-06-14-opkssh-research.md:9.5`.

### 3.4 Modify: `scripts/manager/setup-termix.sh`

- Replace the `ensure_termix_credential` calls for the management VM and bastion with `ensure_termix_opkssh_host` calls. The new function:
  - Calls Termix's REST API to create or update a host with `authType: "OPKSSH"` and `connectionType: "ssh"`.
  - Stores the OIDC identity (`alice@example.com` is the default principal source; we use `oidc:groups:admins` on the server side instead).
  - The `~/.opk/config.yml` mounted in §3.3 supplies the provider so Termix's OPKSSH client can complete the dance.
- Keep the `Browser SSH` role and `share_termix_host_with_browser_role` calls unchanged.
- After Phase 2, the static `Management VM Password` and `Bastion VM SSH Key` credentials are deleted from Termix. They stay in OpenBao only as break-glass material (see §6.3).

### 3.5 Modify: `ansible/management-vm-maintenance.yml`

The existing `99-twinbox-management.conf` drop-in (line 108-120) is replaced by `99-twinbox-opkssh.conf`:

```
TrustedUserCAKeys /etc/ssh/authentik-ssh-ca.pub
AuthorizedPrincipalsFile /etc/opk/authentik_principals/%u

# Phases 1 and 2: keep password auth enabled (Phase 1) or disable (Phase 2)
PubkeyAuthentication yes
PasswordAuthentication yes      # Phase 1
KbdInteractiveAuthentication no

# After Phase 2:
# PasswordAuthentication no
# AuthenticationMethods publickey
```

Plus a new task:

```
- name: Install opkssh on the management VM
  ansible.builtin.import_tasks: install-opkssh.yml
```

Where `install-opkssh.yml`:

- Fetches the pinned opkssh binary (sha256-verified) into `/usr/local/bin/opkssh`.
- Renders `/etc/opk/providers` from a template (one line, parameterized with the OIDC issuer URL and client ID).
- Renders `/etc/opk/auth_id` with the management-VM-specific mapping (see §4.2).
- Renders `/etc/ssh/authentik-ssh-ca.pub` (the OIDC discovery endpoint is the trust root, but we ship a static `TrustedUserCAKeys` file that contains the Authentik JWKS root, see `docs/plans/2026-06-14-opkssh-research.md:1.6` and `:4.2` for why the static file is empty-by-design).
- Runs `opkssh verify --help` as a smoke test.
- Restarts `sshd` (existing handler).

### 3.6 Modify: `categories/talos-cluster/steps/provision-netbird-bastion/run.sh`

- The current `run.sh:288-298` generates an ed25519 key for the bastion and ships the public key to Hetzner. After this change:
  - The ed25519 key remains, but is now labelled as a **break-glass** key in the secret file and on the bastion's `sshd_config`.
  - Cloud-init installs opkssh (`/usr/local/bin/opkssh`) and drops `/etc/opk/{providers,auth_id,config.yml}` and `/etc/ssh/sshd_config.d/60-opk-ssh.conf` (the opkssh install script handles all of this; we call it from cloud-init).
- The existing `ssh_keys = [hcloud_ssh_key.default.id]` (in `infra/opentofu/netbird/main.tf:13`) is preserved for Phase 1; we plan to remove it in Phase 3 (see §6).

### 3.7 Modify: `categories/talos-cluster/steps/install-browser-ssh/step.yaml`

- Updated summary and explanation text mentioning opkssh.
- New run order: `setup-opkssh-authentik.sh` runs *before* `setup-termix.sh` so the OIDC client and the Termix config.yml are in place when Termix is configured.

---

## 4. Group-to-principal mapping

The load-bearing config is `/etc/opk/auth_id` on each target host. From `docs/plans/2026-06-14-opkssh-research.md:8.1.1`:

### 4.1 The existing `admins` Authentik group

`admins` is created in `scripts/manager/.../create-users-and-groups` and is already bound to Termix's Authentik application (`setup-termix-authentik.sh:266, 384`). We reuse it for SSH.

### 4.2 Management VM — `/etc/opk/auth_id`

```
# Anyone in Authentik 'admins' may SSH as the Linux user 'twinbox'
twinbox oidc:groups:admins https://authentik.<zone>/application/o/opkssh/
```

Permissions: `chown root:opksshuser /etc/opk/auth_id; chmod 640`.

### 4.3 Bastion — `/etc/opk/auth_id`

```
# Anyone in Authentik 'admins' may SSH as 'root' on the bastion
root oidc:groups:admins https://authentik.<zone>/application/o/opkssh/
```

The bastion root account matches the existing model (`AGENTS.md:43-44` documents `ssh root@<bastion-ip>`). `PermitRootLogin prohibit-password` on the bastion already permits publickey (and therefore cert) auth.

### 4.4 Authentik OAuth2 application

Created in Authentik with:

| Setting | Value |
| --- | --- |
| Name | `opkssh` |
| Type | OAuth2/OpenID Provider |
| Client type | Confidential |
| Client ID | (generated, dedicated) |
| Redirect URIs | `https://termix.<zone>/host/opkssh-callback` |
| Scopes | `openid profile email groups` |
| Issuer mode | Per-application (`iss = https://authentik.<zone>/application/o/opkssh/`) |
| Subject mode | Based on the user's `username` |
| Property mappings | (default) + custom `groups` mapping that emits `[group.name for group in request.user.ak_groups.all()]` |

Bound to the `admins` group via `ensure_group_binding` (mirroring `setup-termix-authentik.sh:384`).

**Critical:** the opkssh README warns that a client ID must not be shared between opkssh and other services (replay attack risk). The new application is dedicated.

### 4.5 Policy plugin (optional, reserved for future)

For Phase 1 we use only `/etc/opk/auth_id`. A policy plugin is reserved for break-glass scenarios (e.g. an `admins-breakglass` group with shorter cert TTL) and IP allow-listing, but is **not** in scope for the initial rollout.

---

## 5. Cert lifecycle

- **Default TTL:** 16h (matches the user's choice).
- **Max TTL:** 7d (matches the user's choice; enforced server-side by opkssh's per-provider expiration policy in `/etc/opk/providers`).
- **MFA enforcement:** implicit. The Authentik OAuth2 flow requires the configured authenticator stage (TOTP/WebAuthn). `opkssh login` opens the Authentik browser flow, so the user cannot complete the OIDC dance without MFA. The opkssh verifier does not check an `amr` claim; it trusts the OP signature on the `id_token`.
- **Renewal:** the user runs `opkssh login` again (from their laptop, or from the Termix container). The new cert replaces the old one. No server-side interaction needed; the cert is presented at the next SSH connect.
- **Revocation:** opkssh does not implement CRLs. Revocation is by **time** (cert expires) or by **removing the user from the `admins` group in Authentik** (next cert issued is no longer valid for SSH, and existing certs are still valid until their 16h TTL expires). For a hard cut, rotate the Authentik signing key — every existing `id_token` becomes unverifiable.
- **Cert file location on operator devices:** `~/.ssh/id_ecdsa-cert.pub` (default; opkssh supports `id_ed25519` too). The cert and the underlying key are also loaded into `ssh-agent` automatically.

---

## 6. Migration — 3 phases

The user chose gradual migration. Each phase is independently testable and revertible.

### 6.1 Phase 0 — pre-flight (no production change)

- Deploy `setup-opkssh-authentik.sh` output (Authentik app created, secrets written to OpenBao, Termix config rendered).
- Deploy the opkssh install on a **throwaway VM** (e.g. a fresh Proxmox VM with a test user).
- Verify the OIDC dance forces MFA: log in to Authentik without a TOTP factor on a test user; `opkssh login` should fail.
- Verify the cert authenticates against the throwaway VM.
- Verify `opkssh audit` reports the auth_id and providers files as consistent.

**Exit criteria:** end-to-end auth works on a non-production host. Static Termix flows unchanged.

### 6.2 Phase 1 — additive: management VM, key still present

- Run `install-opkssh` step on the management VM.
- `/etc/opk/auth_id` is in place.
- **Existing `PasswordAuthentication yes` and `PubkeyAuthentication yes` are kept.** The static Termix password credential still works.
- Termix gets a **new** host entry `Management VM (opkssh)` with `authType: "OPKSSH"`. The existing `Management VM` host entry is left in place.
- An operator can now choose: static password (existing flow) **or** opkssh (new flow).
- All admins are encouraged to use opkssh for at least 7 days before Phase 2.

**Exit criteria:** every admin has successfully completed an MFA-gated SSH login to the management VM via opkssh. `scripts/manager/setup-termix.sh` runs idempotently and creates the new host.

### 6.3 Phase 2 — remove static Termix credentials: management VM

- `setup-termix.sh` deletes the `Management VM Password` credential from Termix.
- The Termix UI hides the `Management VM` (old) host entry; only `Management VM (opkssh)` is visible.
- The static password is **retained** in `twinbox-login.json` and the Management VM's `authorized_keys` (it has no entry today but the static `cloud-init` password still works) as break-glass. Documented in `docs/operations.md` and the AGENTS.md update.
- `PasswordAuthentication no` is **NOT yet set**. Password auth stays on as a documented break-glass.

**Exit criteria:** all admin traffic to the management VM has been via opkssh for at least 7 days. No regressions in CI/scripts that depend on SSH-as-twinbox.

### 6.4 Phase 3 — bastion

- Run `install-opkssh` step on the bastion.
- The bastion cloud-init now installs opkssh, but the existing ed25519 key remains in `sshd_config` (as `authorized_keys`) and on the bastion file system.
- Termix gets a new `Bastion VM (opkssh)` host entry. The existing `Bastion VM` entry stays.
- After 7 days of stable opkssh use, delete the static key:
  - Remove from Hetzner `ssh_keys` via OpenTofu.
  - Remove from `/root/.ssh/authorized_keys` on the bastion.
  - Remove `SSH_PRIVATE_KEY` from `netbird-bastion-<cluster-id>.json` (set to empty string; the field is preserved for backwards compat with `setup-termix.sh` reading it, but it's empty).
  - Termix no longer has the `Bastion VM` (old) entry.
  - Update `wizard/setup-wizard.sh` doc to not advertise the ed25519 path.

**Exit criteria:** the bastion has been opkssh-only for at least 7 days. NetBird policies unchanged. The Termix `Browser SSH` role still grants both hosts to admins.

### 6.5 Rollback

- Phase 1/2 rollback: remove the opkssh host from Termix, remove `install-opkssh` step from the journey. The original password/key flows continue working unchanged.
- Phase 3 rollback: re-apply the ed25519 key to Hetzner, push it via the bastion's `cloud-init` update, restore the Termix `Bastion VM` entry. Documented in `docs/operations.md`.

---

## 7. Data flow

### 7.1 First-time opkssh login (operator)

```
1. Operator opens Termix, logs in via Authentik OIDC (existing flow).
2. Operator picks "Management VM (opkssh)".
3. Termix container runs: opkssh login --provider=<issuer,client_id>
4. opkssh generates a fresh ECDSA P-256 keypair in /app/data/.opk/.
5. opkssh binds the public key into the id_token nonce (PK Token trick).
6. opkssh starts an HTTP listener on 127.0.0.1:3000 in the pod.
7. Termix opens the operator's browser to https://authentik.<zone>/application/o/authorize/...
   with the PK-bound nonce. Authentik enforces MFA.
8. Authentik redirects to https://termix.<zone>/host/opkssh-callback with the code.
9. Termix proxies the code to opkssh's localhost listener.
10. opkssh exchanges the code for id_token at Authentik's token endpoint.
11. opkssh signs the CIC token, builds the PK Token + SSH cert.
12. Cert + key are stored in Termix's DB (encrypted at rest) and added to the in-memory ssh-agent.
13. Termix opens the SSH session using the cert.
14. sshd on the management VM runs /usr/local/bin/opkssh verify %u %k %t.
15. opkssh verify fetches https://authentik.<zone>/application/o/opkssh/jwks/.
16. opkssh verify validates the Authentik signature on the id_token.
17. opkssh verify validates the nonce binding.
18. opkssh verify reads /etc/opk/auth_id; finds twinbox oidc:groups:admins <issuer>; the user's groups claim contains "admins"; principal "twinbox" is allowed.
19. opkssh verify emits "cert-authority,principals=\"twinbox\" <user-pubkey>" to sshd.
20. sshd verifies the cert, grants the session as Linux user "twinbox".
```

### 7.2 Subsequent logins (within 16h cert validity)

Steps 3-12 are skipped. Termix loads the cached cert from the DB and uses it directly. If the cert is past 75% of its lifetime, Termix transparently re-runs `opkssh login`.

### 7.3 Direct SSH from an operator laptop (not via Termix)

The same flow as 7.1, except `opkssh login` runs on the operator's machine (not in Termix), and the cert lands in `~/.ssh/id_ecdsa-cert.pub`. The operator's `~/.ssh/config` should have:

```
Host mgmt-*
  IdentityFile ~/.ssh/id_ecdsa
  IdentitiesOnly yes
```

(`IdentitiesOnly` is required so sshd does not try the static key from `authorized_keys` if the cert fails.)

---

## 8. Error handling and edge cases

| Case | Behaviour |
| --- | --- |
| Authentik is down | `opkssh verify` fails to fetch JWKS → cert rejected → operator's existing certs still work for the remainder of their 16h TTL. New logins impossible. |
| Authentik returns no `groups` claim | opkssh `policy.Enforcer` denies; error is logged. Operator must ask admin to fix the property mapping. |
| Operator removed from `admins` group | Existing cert still works for ≤16h. After 16h, no new cert can be issued. NetBird policies also drop the operator's access to the management-vm and bastion groups (`infra/opentofu/netbird-network/main.tf:203-252` controls NetBird, not opkssh). |
| Operator's Termix pod is restarted mid-session | Termix's encrypted-at-rest cert table is on the `termix-data` PVC, so certs survive pod restarts. |
| Bastion goes down | The break-glass ed25519 key in `netbird-bastion-<cluster-id>.json` allows `ssh root@bastion` directly via NetBird (Phase 3 only, the key remains in Hetzner for one rotation cycle then is removed). |
| opkssh binary upgrade is broken | Pin a specific version (v0.14.0 at time of writing). Verify the SHA256 of the binary on the management VM. Phase 1 keeps the old sshd config so a botched opkssh install does not break password auth. |
| Authentik signing key rotates | All existing `id_token`s become unverifiable. Operators must re-login. This is by design and rare (Authentik rotates signing keys yearly at most). |
| `twinbox` user `authorized_keys` is empty in Phase 1 | By design. Cert auth does not require `authorized_keys`. The break-glass password is in `twinbox-login.json`, not in `authorized_keys`. |
| Multiple Termix instances (e.g. dev cluster) | Each cluster has its own Authentik app and its own `~/.opk/config.yml`. Per-cluster `providers` URL is rendered from the cluster's `ZONE_NAME`. |

---

## 9. Security tradeoffs

| Topic | Tradeoff |
| --- | --- |
| Trust root | Authentik is the trust root. Compromise of the Authentik signing key = compromise of every SSH cert. Mitigated by Authentik running in-cluster with HSM-backed signing key (future) and the short 16h TTL. |
| Cert revocation | None. Revocation is by time (≤16h exposure window) or by removing the user from `admins`. We accept this; CRLs are not worth the complexity for two hosts. |
| Bastion `root` | Cert allows login as `root`. This matches the existing model. We do not introduce a non-root account on the bastion. The 16h TTL is the only protection against a stolen cert. |
| Static key as break-glass | The ed25519 key on the bastion survives Phase 3. It is a documented escape hatch. It is rotated annually and removed if the bastion is rebuilt. |
| Password on management VM | Survives Phase 2 (kept for break-glass). Removed in a future phase once the team is comfortable that opkssh is reliable. |
| Termix callback URL exposure | `https://termix.<zone>/host/opkssh-callback` is exposed via the existing `termix-netbird` ingress route. The callback is idempotent and only accepts a code from Authentik; replaying a captured code fails at the token exchange step. |
| `opkssh` client ID replay | Mitigated by using a dedicated `opkssh` client ID per the opkssh README warning. Not shared with Termix, Argo CD, or Portal. |
| MFA bypass via session caching | The Authentik flow does not cache MFA. Each OIDC login is a fresh flow. We do not use Authentik's `prompt=none`. |
| No GQ signatures | opkssh does not enable GQ by default. GQ would prevent Authentik from re-using the `id_token` against another RP, but the dedicated client ID approach is sufficient. We do not enable GQ in Phase 1. |

---

## 10. Testing

| Layer | Test |
| --- | --- |
| Authentik OAuth2 app | Manual: create the app in a dev Authentik instance, run `opkssh login`, confirm cert is issued. |
| opkssh install on the management VM | New `tests/scripts/test_install_opkssh_step.py` (integration test using a vagrant or LXC VM) — install opkssh, run `opkssh audit`, assert exit 0. |
| Group mapping | New `tests/scripts/test_opkssh_auth_id.py` — feed sample `auth_id` lines into a fixture opkssh build, assert that `oidc:groups:admins` matches a token with `groups: ["admins", "users"]` and rejects a token with `groups: ["users"]`. |
| Termix OPKSSH integration | Manual: open `https://termix.<zone>` in browser, log in, pick `Management VM (opkssh)`, complete MFA, observe terminal. |
| End-to-end | `tests/integration/test_ssh_opkssh_e2e.py` — provision a Talos cluster, run `install-opkssh`, run `setup-termix.sh`, log in via Termix (use browser-use or playwright as per AGENTS.md), assert shell prompt. |
| Rollback | `tests/integration/test_opkssh_rollback.py` — run Phase 1 install, run the rollback script, assert that password auth still works. |
| Lint/format | `make lint && make format-check` (existing). |
| Shellcheck | `bash -n scripts/manager/setup-opkssh-authentik.sh` (new). |

The test files are added in the same commit as the corresponding code. Per AGENTS.md, we run `python3 -m pytest -q tests` and `node --test manager-*/test/*.mjs` before pushing.

---

## 11. Documentation updates

- `docs/termix.md` (new) — what Termix does, how opkssh fits in, screenshots of the OPKSSH host entry. Replaces the inline Termix notes in `docs/netbird.md`.
- `docs/ssh-access.md` (new) — the operator's guide to `opkssh login` and connecting directly from a laptop. Includes the NetBird prerequisite.
- `docs/operations.md` (new) — break-glass procedures, including the static ed25519 key location and the Management VM password.
- `AGENTS.md` — update the "Bastion Node" section to reference the opkssh login flow; add a "SSH Authentication" section.
- `docs/talos-integration.md` — update step 32 (`install-browser-ssh`) to mention the new opkssh dependency and the `install-opkssh` step.
- `docs/netbird.md` — strip out the Termix section (moves to `docs/termix.md`).

---

## 12. Out of scope

- SSH access to **Talos control-plane / worker nodes**. Talos has its own auth model (talosconfig, API). opkssh could be added later but is not in this design.
- Workload identities (CI jobs, GitHub Actions, etc.). opkssh supports them, but the user did not ask for them.
- GQ signatures. See §9.
- opkssh on the **Termix pod** for use from the operator's laptop to the Termix container. Not needed.
- The **Hetzner exit peer** (`twinbox-${cluster_id}-hetzner-exit`) — that is a NetBird exit node, not an SSH target.
- A **Termix `opkssh` UI in the Twinbox Portal**. The Twinbox Portal is a separate app; OPKSSH login is a Termix concern.

---

## 13. Decisions made during design

| Decision | Chosen value | Rationale |
| --- | --- | --- |
| SSH CA tool | opkssh | No separate CA server, stateless, Termix already supports it, OpenPubkey pattern fits Authentik OIDC. |
| Authentik gating group | existing `admins` | Single group to manage; matches existing app binding pattern. |
| Cert TTL | 16h default, 7d max | User request; balances usability and exposure. |
| Migration | 3 phases | Additive, safe rollback, no lockout risk. |
| Static creds | removed from Termix, kept on host as break-glass | Maximizes security where operators see it, keeps escape hatch documented. |
| Distribution | Ansible for host config, manager-script for Authentik/Termix | Matches existing patterns (`setup-termix-authentik.sh`, `management-vm-maintenance.yml`). |
| Scope | management VM + bastion only | Minimum viable change; Talos auth stays unchanged. |

---

## 14. Approvals and next steps

- [x] User approves this design (via "implementeer dit").
- [ ] Implementation plan produced (`writing-plans` skill).
- [ ] Phase 0: Authentik app + OpenBao secrets + throwaway host verification.
- [ ] Phase 1: opkssh on management VM, additive.
- [ ] Phase 2: remove static Termix credential for management VM.
- [ ] Phase 3: opkssh on bastion, remove static key.
- [ ] All tests pass and documentation updated.

**Next immediate step:** invoke the `writing-plans` skill to produce `docs/plans/2026-06-14-opkssh-implementation.md`.
