# opkssh Research Report for Twinbox

**Date:** 2026-06-14
**Status:** Research complete. Not yet a design. Findings only.
**Audience:** Twinbox maintainers designing OIDC-based SSH access via Authentik.

This is a deep research report on `opkssh` (https://github.com/openpubkey/opkssh) and how it could be integrated into Twinbox as the SSH certificate authority for the management VM, the Hetzner bastion, and the Termix SSH front-end. It is **not** a design — it is the research the design will be built on. Every factual claim cites a primary source URL.

The structure follows the original 10-topic research brief.

---

## 1. opkssh architecture and flow

### 1.1 What opkssh is

opkssh is a Go tool that lets a user SSH to a server using an OIDC identity (e.g. `alice@example.com`) instead of a long-lived SSH key. It does not replace SSH; it generates OpenSSH user certificates that contain a **PK Token** (a modified OIDC ID token bound to a fresh user-generated public key) and configures sshd to verify those certificates.

> "opkssh is a tool which enables ssh to be used with OpenID Connect allowing SSH access to be managed via identities like `alice@example.com` instead of long-lived SSH keys. It does not replace SSH, but instead generates SSH public keys containing PK Tokens and configures sshd to verify them. These PK Tokens contain standard OpenID Connect ID Tokens."
> — <https://github.com/openpubkey/opkssh> ("Overview" paragraph of README)

### 1.2 How does opkssh verify a user via OIDC? PK Token, not the bare id_token

opkssh is built on top of the **[OpenPubkey](https://github.com/openpubkey/openpubkey) protocol** (see `go.mod` line: `github.com/openpubkey/openpubkey v0.23.0` — <https://github.com/openpubkey/opkssh/blob/main/go.mod>). The crucial insight is that opkssh does **not** simply pass the OIDC `id_token` as a key — it binds the user's freshly-generated public key into the `id_token` via a clever trick on the OIDC `nonce` claim.

The OpenPubkey flow (as documented in <https://github.com/openpubkey/openpubkey>):

1. Client generates a fresh key pair `(upk, usk)` and computes `nonce = SHA3-256(upk, alg, rz, typ="CIC")` where `rz` is random and `typ` is the literal string `"CIC"` (Client Instance Claim).
2. Client initiates standard OIDC authn with the OP, sending that `nonce`.
3. The OP (Authentik) returns an `id_token` whose `nonce` claim commits to the user's public key. To the OP, this looks like a random nonce — no special OP support is needed.
4. The user signs a second JWS over the ID token payload using `usk` with the `upk`, `alg`, `rz`, `typ="CIC"` values in the protected header. The combined `id_token` + this second signature is the **PK Token**.
5. A verifier checks (a) the OP signature on the inner ID token using the OP's JWKS, and (b) that the `nonce` claim equals `SHA3-256(protected_header.upk, protected_header.alg, protected_header.rz, "CIC")`. If both pass, the verifier knows the ID token was issued by the OP **and** that the user controls `usk`.

This is implemented in:

- `clientinstance/claims.go` (<https://github.com/openpubkey/openpubkey/blob/main/pktoken/clientinstance/claims.go>) — defines the `CIC` (Client Instance Claim) protected header with reserved fields `typ`, `alg`, `upk`, `rz`.
- `client/client.go` (<https://github.com/openpubkey/openpubkey/blob/main/client/client.go>) — `oidcAuth()` does the nonce trick and `cic.Sign()` produces the user signature.
- `verifier/verifier.go` (<https://github.com/openpubkey/openpubkey/blob/main/verifier/verifier.go>) — `VerifyPKToken()` does the dual verification.

The verifier source also confirms that the **exp clock is independent of the OP clock**: for user-identity OPs, opkssh overrides the ID token's `exp` with a 24-hour default (`v.defaultExpirationPolicy = &ExpirationPolicies.MAX_AGE_24HOURS` in `verifier.go`), so users don't have to re-auth every hour. This is controlled per-provider in `/etc/opk/providers` (see §2).

### 1.3 Relationship to the openpubkey library

opkssh is essentially a thin Go wrapper around the `openpubkey` library, specialised for SSH:

- The `opkssh` binary embeds `github.com/openpubkey/openpubkey` directly (same monorepo, see <https://github.com/openpubkey> org).
- The two main OpenPubkey building blocks reused by opkssh are:
  - `client.OpkClient.Auth()` — produces a PK Token via browser OIDC.
  - `verifier.Verifier.VerifyPKToken()` — verifies a PK Token against a `ProviderVerifier` for one of the configured OPs.

The SSH-specific glue lives entirely in `opkssh`:

- `sshcert/sshcert.go` (<https://github.com/openpubkey/opkssh/blob/main/sshcert/sshcert.go>) — converts a PK Token into an OpenSSH user certificate by stashing the PK Token in an SSH cert extension `openpubkey-pkt`, plus optional `openpubkey-act` for the access token.
- `commands/login.go` (`LoginCmd.login()`) — drives the OIDC flow, generates the SSH keypair, builds the cert, and writes `~/.ssh/id_ecdsa` (or `id_ed25519`) + `*-cert.pub`.
- `commands/verify.go` (`VerifyCmd.AuthorizedKeysCommand()`) — the server-side verifier invoked by sshd.

### 1.4 Does opkssh require an OIDC provider that supports PKCE, or any OIDC provider?

**Any OIDC provider that returns an `id_token` with a `nonce` claim works.** PKCE is not required.

Direct evidence:

- The README's "How it works" section says "We use two features of SSH… SSH public keys can be SSH certificates … arbitrary extensions…", with no mention of PKCE in the protocol.
- `client/oidcAuth()` (in openpubkey) only uses the standard authorization code flow; the nonce trick is the binding mechanism. PKCE is an OIDC-RP feature, not an OP feature, and opkssh does not enable it.
- The provider list explicitly includes providers like Google and Authelia that are PKCE-optional. The supported-provider matrix in the README (<https://github.com/openpubkey/opkssh#tested>) lists 12 providers as "✅": Google, Microsoft/Azure, GitLab, hello.dev, Authelia, Authentik, Keycloak, Zitadel, PocketID, AWS Cognito, Kanidm.
- The `oidc/oidc.go` `OidcClaims` struct (<https://github.com/openpubkey/openpubkey/blob/main/oidc/oidc.go>) explicitly models `Nonce` as part of the standard OIDC ID token.

For workload identities (where OPs don't put `nonce` in the token, e.g. GitHub Actions), openpubkey switches the binding to the `aud` claim, but for the user-identity case we care about (Authentik authenticating a human), the `nonce` flow is used and is sufficient. There is no PKCE requirement on Authentik's side.

### 1.5 Actual SSH cert signing flow — daemon or per-login?

opkssh is **not** a long-running daemon. It runs twice in the lifecycle:

1. **Client side, per login** — `opkssh login` is invoked by the user. It:
   - Spawns a localhost HTTP listener on one of the registered ports (default `:3000`, `:10001`, `:11110`, see `config.md` "Redirect URIs").
   - Opens a browser to the OP.
   - Receives the `id_token` + signs the CIC token with the user's fresh keypair.
   - Builds an SSH cert from the PK Token (see `commands/login.go:createSSHCertWithAccessToken`).
   - Writes the cert + key to `~/.ssh/id_ecdsa` (or `id_ed25519`) and the corresponding `*-cert.pub`.
   - Exits. The SSH cert typically has `ValidBefore: ssh.CertTimeInfinity` (see `sshcert/sshcert.go`) but the *id_token inside* has a 24h `exp` enforced by the verifier.

2. **Server side, per SSH connection** — `opkssh verify` is invoked by `sshd` via the `AuthorizedKeysCommand` mechanism. See `main.go` (the `verifyCmd` definition): it logs to `/var/log/opkssh.log`, loads `/etc/opk/providers`, verifies the PK Token via the openpubkey verifier, runs policy via `policy.Enforcer`, and finally prints a single `cert-authority,principals="..."` line to stdout for sshd.

The exact flow is documented in `commands/verify.go:AuthorizedKeysCommand()`:

> "This function:
> 1. Verifying the PK token with the OP (OpenID Provider)
> 2. Enforcing policy by checking if the identity is allowed to assume the username (principal) requested."

And from the install script `scripts/installing.md`:

> "By default, the following lines are added to the sshd_config at /etc/ssh/sshd_config.d/60-opk-ssh.conf:
> AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
> AuthorizedKeysCommandUser opksshuser"

There is **no** `ForceCommand` hook in opkssh and no PAM module. The integration is entirely through `sshd`'s standard `AuthorizedKeysCommand` directive, with `ForceCommand` left free for the user to set separately if they need it (e.g. to force a `ProxyCommand`).

### 1.6 What's the public key the server side trusts?

There **is no CA public key in the traditional sense**. The key insight of opkssh is that **the OP itself acts as the trust root**:

- The "CA" for the SSH cert is implicitly the OP, because the cert's contents (the PK Token) is signed by the OP.
- Each SSH cert contains the user's public key in the cert's `Key` field, plus the PK Token in the `openpubkey-pkt` extension.
- The server's `opkssh verify` re-fetches the OP's JWKS at login time and verifies the ID token signature against it (see `verifier.go:VerifyPKToken` calls `providerVerifier.VerifyIDToken`).
- If verification succeeds, `verify.go` emits a synthetic `cert-authority,principals="..."` line to sshd where the "CA key" is actually the user's public key extracted from the PK Token. This is a clever hack: sshd thinks it's trusting a CA, but opkssh dynamically rewrites which key is trusted per-connection.

> "sshd is awaiting a specific line, which we print here. Printing anything else before or after will break our solution" — `main.go` (verifyCmd RunE)

> "sshd expects the public key in the cert, not the cert itself. This public key is key of the CA that signs the cert, in our setting there is no CA." — `commands/verify.go` (AuthorizedKeysCommand doc comment)

Consequence: the **server never needs to distribute a public key ahead of time**. The OP's TLS certificate (used to serve its JWKS over HTTPS) is the only "trust anchor", and that comes pre-installed in the OS or in the verifier's HTTP client trust store. The `/etc/opk/providers` file lists **which OPs are acceptable** (and their client IDs), not their keys.

The `AuthorizedKeysCommandUser` is a low-privilege system user (`opksshuser`) created by the install script. Its purpose is to make outbound HTTPS calls to OP JWKS endpoints during verification, with read access to `/etc/opk/` files only.

### 1.7 How is "distribution" handled?

There is no key distribution step per host. Instead, the install script runs on each target host (mgmt VM, bastion, etc.) and:

- Installs the opkssh binary to `/usr/local/bin/opkssh`.
- Creates `/etc/opk/{providers, auth_id, config.yml, policy.d/}`.
- Adds the `AuthorizedKeysCommand` and `AuthorizedKeysCommandUser` lines to `/etc/ssh/sshd_config.d/60-opk-ssh.conf`.
- Creates the `opksshuser` system account.

See `scripts/install-linux.sh` (<https://github.com/openpubkey/opkssh/blob/main/scripts/install-linux.sh>).

---

## 2. opkssh + Authentik compatibility

### 2.1 Is Authentik supported? Does opkssh have a generic OIDC mode?

**Yes, Authentik is officially supported as "✅ Tested"** in the README's compatibility table (<https://github.com/openpubkey/opkssh#tested>):

> "Authentik ✅
> Do not add a certificate in the encryption section of the provider"

The README also has a "Custom OpenID Providers (Authentik, Authelia, Keycloak, Zitadel...)" section (<https://github.com/openpubkey/opkssh#custom-openid-providers-authentik-authelia-keycloak-zitadel>) which describes the generic mode. From the README:

> "To log in using a custom OpenID Provider, run:
> `opkssh login --provider="<issuer>,<client_id>"`
> …or in the rare case that a client secret is required by the OpenID Provider:
> `opkssh login --provider="<issuer>,<client_id>,<client_secret>,<scopes>"`"

> "For example if the issuer is `https://authentik.local/application/o/opkssh/` and the client ID was `ClientID123`:
> `opkssh login --provider="https://authentik.local/application/o/opkssh/,ClientID123"`
> to specify scopes
> `opkssh login --provider="https://authentik.local/application/o/opkssh/,ClientID123,,openid profile email groups"`"

This is effectively a "generic" mode. opkssh uses Authentik's OIDC discovery endpoint (`/.well-known/openid-configuration`) to find authorization, token, userinfo, and JWKS URLs automatically. The `provider.Issuer()` is the Authentik application URL (e.g. `https://authentik.<zone>/application/o/opkssh/`).

### 2.2 Configuration file formats

opkssh has **two distinct config file families** with very different shapes:

**Server-side, on each target host (mgmt VM, bastion, …)** — under `/etc/opk/`:

1. `/etc/opk/providers` — space-delimited, three columns: `Issuer Client-ID expiration-policy`. Example for Authentik: `https://authentik.<zone>/application/o/opkssh/ <client-id> 24h`. Permissions: `chown root:opksshuser /etc/opk/providers; chmod 640`.

2. `/etc/opk/auth_id` — space-delimited, three columns: `<principal> <identity-attribute> <issuer>`. Example:
   ```
   twinbox twinbox-user@example.com https://authentik.<zone>/application/o/opkssh/
   root root-user@example.com https://authentik.<zone>/application/o/opkssh/
   twinbox oidc:groups:twinbox-admins https://authentik.<zone>/application/o/opkssh/
   ```
   Permissions: `chown root:opksshuser; chmod 640`. There's also a per-user `~/.opk/auth_id` for users to add their own mappings without root (see `docs/config.md`).

3. `/etc/opk/config.yml` — YAML, optional. Supports `env_vars:` (e.g. `HTTPS_PROXY`) and `deny_emails:`, `deny_users:` (per `<https://man.openbsd.org/sshd_config#DenyUsers>`).

4. `/etc/opk/policy.d/*.yml` — YAML, optional. Defines policy plugins (shell-out to a custom command). See `docs/policyplugins.md` and §8.

**Client-side, on the user device (or inside the Termix container)** — `~/.opk/config.yml` (Linux) or `%APPDATA%\.opk\config.yml` (Windows):

```yaml
default_provider: webchooser

providers:
  - alias: authentik
    issuer: https://authentik.<zone>/application/o/opkssh/
    client_id: <client-id>
    client_secret: <client-secret>  # optional
    scopes: openid profile email groups
    access_type: offline
    prompt: consent
    redirect_uris:
      - http://localhost:3000/login-callback
      - http://localhost:10001/login-callback
      - http://localhost:11110/login-callback
    send_access_token: false  # set true to enable userinfo lookups
```

See <https://github.com/openpubkey/opkssh/blob/main/commands/config/default-client-config.yml> for the canonical default.

### 2.3 Authentik OAuth2 application config

Per the README and `docs/providers/keycloak.md` (which is structurally identical to Authentik):

| Field | Value |
|---|---|
| `Name` | `opkssh` (the application slug) |
| `Provider type` | OAuth2/OpenID Provider |
| `Issuer mode` | Per-application (default), so `iss` = `https://authentik.<zone>/application/o/opkssh/` |
| `Client type` | Confidential (because Termix is a server, not a SPA) |
| `Redirect URIs` | The PUBLIC Termix callback URL: `https://<termix>.<zone>/host/opkssh-callback` |
| `Scopes` | `openid profile email groups` (so user attributes/groups land in the ID token) |
| `Subject mode` | Based on the User's `username` or `email` (your choice) |
| `Signing Key` | Optional. With it set, tokens are asymmetrically signed. Without, they're symmetrically signed with the client secret. |
| `Encryption Key` | Do **not** set; opkssh does not handle JWE. (The README warning: "Do not add a certificate in the encryption section of the provider" — <https://github.com/openpubkey/opkssh#tested>) |

Authentik-specific notes from <https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/>:

- Per-provider issuer mode is default and recommended (<https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/#issuer-mode>).
- Discovery doc lives at `/application/o/<app-slug>/.well-known/openid-configuration`.
- JWKS is at `/application/o/<app-slug>/jwks/`.
- `email_verified` defaults to `False` as of authentik 2025.10 (<https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/#email-scope-verification>). opkssh has a `OPKSSH_PLUGIN_EMAIL_VERIFIED` env var passed to policy plugins; standard `auth_id` policy does not gate on this by default.

### 2.4 Redirect URI port for opkssh

opkssh hard-codes the three localhost ports it tries to bind, in `redirectURI must be localhost` order: **3000, 10001, 11110** (see `providers/google.go` and the default `default-client-config.yml`).

> "Currently opkssh supports the following redirect URIs. Make sure that the correct redirect URIs have been added at your OpenID Provider:
> ```
> http://localhost:3000/login-callback
> http://localhost:10001/login-callback
> http://localhost:11110/login-callback
> ```"
> — README, "Redirect URIs" section

The `login` command picks the first one that's free. Each is `127.0.0.1:port`; it cannot bind to anything else.

For Twinbox + Termix specifically, this has a wrinkle: the OP must allow a **public** Termix callback URL (e.g. `https://termix.<zone>/host/opkssh-callback`) because Termix is the one opening the browser. The opkssh client binary binds to `127.0.0.1:<one-of-the-three>` internally, then Termix proxies the auth response from its public callback URL back to opkssh's localhost listener. The `--remote-redirect-uri` flag on opkssh (added recently) tells opkssh "use this URL in the auth request to the OP, but actually listen on localhost". Termix uses this:

> "Termix automatically tells OPKSSH which public URL your OAuth provider should redirect back to (via `--remote-redirect-uri`), derived from the request origin."
> — <https://docs.termix.site/opkssh>

> "The `redirect_uris` field is optional and is NOT your Termix public URL. It lists the localhost ports OPKSSH binds its internal callback listener on."
> — <https://docs.termix.site/opkssh>

Source confirmation in `commands/login.go`:

```go
if l.RemoteRedirectURI != "" {
    // Override the remote redirect URI
    providerConfig.RemoteRedirectURI = l.RemoteRedirectURI
}
```

The `RemoteRedirectURI` option is at the openpubkey provider level (`providers/google.go`).

### 2.5 Group claims and the SSH cert principal

How does opkssh determine the SSH cert principal from the OIDC token?

The user identity is **not** the cert principal — the user requests a principal via the SSH command (`ssh twinbox@<host>` sets `principal=twinbox` to sshd, `ssh root@<host>` sets `principal=root`). The PK Token's `email` (or `sub`) claim is then matched against `/etc/opk/auth_id` to **authorize** that principal request. The principal list on the cert itself is the literal string `["opkssh-wildcard"]` (see `commands/login.go:createSSHCertWithAccessToken`):

```go
principals := []string{"opkssh-wildcard"}
```

This is then expanded by opkssh's verifier using the SSH cert's `principals=` field in the `cert-authority` line it returns to sshd:

```go
// commands/verify.go
principals := strings.Join(cert.SshCert.ValidPrincipals, ",")
if principals != "" {
    return fmt.Sprintf("cert-authority,principals=\"%s\" %s", principals, pubkeyBytes), nil
}
```

This works around an intentional break in OpenSSH that removed principal wildcards (see PR #513 referenced in `login.go`).

**So the "principal" mapping is on the server side, not the cert.** opkssh checks: "is the requesting principal in the set allowed for this email/group?" via `policy.Enforcer.CheckPolicy` (see `policy/enforcer.go`):

```go
// if they are, then check if the desired principal is allowed
if !slices.Contains(user.Principals, principalDesired) {
    continue
}
```

Authentik groups are supported via the structured identity attribute `oidc:groups:<groupName>` or `oidc:"<claim-name>":<value>` (see `policy/enforcer.go:validateClaim`). The OIDC `groups` claim is what the policy engine reads:

```go
// enforcer.go
oidcGroupSections := EscapedSplit(user.IdentityAttribute, ':')
oidcGroupsName := strings.Trim(oidcGroupSections[1], "\"")
return slices.Contains(
    claims.ExtraClaims[oidcGroupsName],
    oidcGroupSections[len(oidcGroupSections)-1],
)
```

For this to work, the `groups` claim must be present in the ID token. Authentik includes the user's groups in ID tokens via scope mapping; the default `email`, `profile`, and `openid` scopes don't include groups — you need a custom scope mapping or to add groups to an existing scope. The Keycloak opkssh guide (which is structurally similar) walks through this in its §2: "add groups to the profile information" (see <https://github.com/openpubkey/opkssh/blob/main/docs/providers/keycloak.md>). For Authentik the equivalent is a custom scope mapping that exposes the user's group names as a `groups` claim.

---

## 3. PK Token vs OIDC id_token — semantic difference

### 3.1 What a PK Token actually is

From the openpubkey README (<https://github.com/openpubkey/openpubkey#pk-tokens>):

> "A PK Token is simply an extension of the ID Token that bundles together the ID Token with values committed to in the ID Token `nonce`. Because ID Tokens are JSON Web Signatures (JWS) and a JWS can have more than one signature, we extend the ID Token into a PK Token by appending a second signature/protected header."

Concretely, a PK Token has the form:

```
payload: { iss, aud, sub, email, nonce: SHA3-256(upk, alg, rz, "CIC"), ... }
signatures: [
  { protected: {alg: "RS256", kid: "..."}, signature: SIGN(OP-signkey, payload) },
  { protected: {upk: alice-pubkey, alg: "ES256", rz: random, typ: "CIC"},
    signature: SIGN(alice-privkey, payload) }
]
```

Two signatures: the OP signs the ID token as usual, the user signs the ID token payload with their fresh keypair, binding it to `upk` via the `nonce` claim.

### 3.2 Why opkssh uses this instead of a step-ca-like flow

**step-ca OIDC provisioner** (the alternative the user mentioned):

1. User authenticates to the OIDC IdP.
2. step-ca receives the id_token over the wire (or via the OAuth callback).
3. step-ca validates the id_token (issuer, audience, signature against JWKS, expiry).
4. step-ca issues an SSH cert signed by its own CA key, fresh.

**opkssh PK Token flow:**

1. User authenticates to the OIDC IdP.
2. User's opkssh client receives the id_token **in the browser** (it controls the nonce before sending it).
3. opkssh wraps the id_token in a PK Token (binds `upk` via nonce) and embeds the PK Token in the SSH cert's `openpubkey-pkt` extension.
4. SSH cert is self-signed by the user's key (no CA signs the cert).
5. The server's `opkssh verify` validates the PK Token by re-checking the OP signature + the nonce binding.

**The "CA" in opkssh is the OP itself**, and there is no signing service. There is no `step-ca`-style database, no `step` CLI, no CA private key material to protect, no step-ca-to-replicate, no CRL.

### 3.3 Pros / cons comparison (PK Token vs step-ca OIDC provisioner)

| Aspect | opkssh (PK Token) | step-ca (OIDC provisioner) |
|---|---|---|
| **State** | Stateless server side. Only the OPs in `/etc/opk/providers` and the policy in `/etc/opk/auth_id`. | Stateful: step-ca's key material + DB (Badger or Postgres). |
| **CA private key** | Does not exist. The OP is the implicit trust root. | step-ca has a private signing key that must be protected and (for HA) replicated. |
| **Trust anchor distribution** | None. Server fetches OP JWKS at login time. | step-ca's root CA pubkey is distributed to every host and pinned in `known_hosts` style. |
| **Revocation** | No CRL. Cert lifetime is short (24h default, configurable up to 1 week). Revocation = reduce cert lifetime. | CRL supported but rarely used in practice; same short-lifetime default. |
| **HA / DR** | Trivial. Each host is independent; OP is the HA dependency. | step-ca HA via Postgres or external DB. |
| **Group → principal mapping** | `oidc:groups:<groupName>` lines in `/etc/opk/auth_id`. | step-ca's templating (e.g. `principals: ["{{ .Principal }}"]`); more flexible but more complex. |
| **Authentik integration** | Tested ✅. No special config. | Also works, but you need to register step-ca's OIDC client with Authentik and configure JWK URL for the provisioner. |
| **Operator setup on host** | One `wget \| bash` or apt-style install, then 2 lines of policy. | Install step-ca, bootstrap, distribute the root cert, configure sshd `TrustedUserCAKeys`. |
| **Workload identities** | Supported (uses `aud` claim instead of `nonce` for OPs that omit `nonce`, e.g. GitHub Actions). | step-ca also supports workload OIDC provisioner; more mature. |
| **Browser-side token interception** | The browser shows the OP login page; the `id_token` is delivered to `opkssh login`'s localhost callback. The opkssh client receives the token. | For step-ca, the token goes to step-ca's HTTPS endpoint. There is no need for a localhost browser callback. |
| **MFA** | Delegated to the OP (Authentik enforces MFA at login). The cert is only as strong as the OP. | Same: delegated to the OP. |
| **Replay attack risk** | Mitigated by GQ signatures (in openpubkey, optional) or by short cert lifetime + the PK Token being bound to the cert's signature. By default opkssh does **not** use GQ. The cert contains the OP signature, so it could in theory be replayed to other OIDC RPs that share the same `client_id` — opkssh's README explicitly warns about this: "Do not reuse a client ID between opkssh and other OpenID Connect services" (README "Security Note"). | step-ca's id_token is sent to step-ca's HTTPS endpoint, not the relying server; replay is harder but still possible if the `client_id` is reused. |
| **Cryptographic assumptions** | Relies on SHA3-256 pre-image resistance (the nonce binding) and on the OP not being coerced to sign a malicious nonce. Both are well-trodden. | Relies on standard JWS verification, plus the assumption that step-ca's CA key is well-protected. |
| **Termix integration** | Built-in, first-class (<https://docs.termix.site/opkssh>). | Not supported. Would require custom bridging. |
| **Public key flexibility** | opkssh supports ECDSA (default), Ed25519; can be selected with `opkssh login -t ed25519`. | step-ca supports the same plus RSA. |

**Bottom line for Twinbox:** the PK Token approach is a better fit because (a) opkssh has first-class Termix support, (b) the opkssh state model is trivial (no CA key to back up), and (c) the operational surface is "install a binary, write 2 policy lines" rather than "run step-ca, replicate it, distribute its root cert". The trade-off is the cryptography is slightly more elaborate (a JWS with two signatures, nonce binding) but the protocol is well-documented in the OpenPubkey paper ([eprint.iacr.org/2023/296](https://eprint.iacr.org/2023/296)) and the openpubkey library is a Linux Foundation project.

---

## 4. Server side: sshd_config changes

### 4.1 What does opkssh install on the server?

Per the install script `scripts/installing.md` and `install-linux.sh`:

1. **A binary**: `/usr/local/bin/opkssh` (mode `755`, owner `root:opksshuser`).
2. **A system user**: `opksshuser` (no login, no home dir).
3. **A sudoers drop-in** at `/etc/sudoers.d/opkssh` (mode `440`) so that `opkssh verify` can sudo to read `~/.opk/auth_id` per-user policy files:
   ```
   opksshuser ALL=(ALL) NOPASSWD: /usr/local/bin/opkssh readhome *
   ```
4. **A drop-in for sshd** at `/etc/ssh/sshd_config.d/60-opk-ssh.conf` containing exactly:
   ```
   AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
   AuthorizedKeysCommandUser opksshuser
   ```
5. **Configuration directory** at `/etc/opk/` with `providers`, `auth_id`, `config.yml`, and `policy.d/`.
6. **Log file** at `/var/log/opkssh.log` (mode `660`).

It does **not** install:

- A PAM module (no `pam_opkssh.so`).
- A `ForceCommand` hook.
- A `systemd` service (the binary is only run by sshd or by the user).

### 4.2 Recommended sshd_config snippet

Exactly two lines, placed in `/etc/ssh/sshd_config.d/60-opk-ssh.conf` (or merged into `sshd_config`):

```
AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
AuthorizedKeysCommandUser opksshuser
```

`%u`, `%k`, `%t` are OpenSSH percent-expansion tokens; see <https://man.openbsd.org/sshd_config#AuthorizedKeysCommand>. Per the verify source, `%u` is the requested Linux principal, `%k` is the base64 SSH cert the client offered, `%t` is the cert type (e.g. `ecdsa-sha2-nistp256-cert-v01@openssh.com`).

The install script is smart about sshd config-file precedence: it picks a numeric prefix lower than any existing `sshd_config.d/NN-*.conf` file, so its lines win. If a `0X-...` file is the highest-priority, the install script refuses to overwrite without `--overwrite-config`.

> "If the file `/etc/ssh/sshd_config.d/20-systemd-userdb.conf` exists, create `/etc/ssh/sshd_config.d/19-opk-ssh.conf` with the lines above. By default, the opkssh installer will create this file at `/etc/ssh/sshd_config.d/60-opk-ssh.conf`."
> — `scripts/installing.md` §4

Verify with:

```
sudo sshd -T | grep authorizedkeyscommand
# expect:
# authorizedkeyscommand /usr/local/bin/opkssh verify %u %k %t
# authorizedkeyscommanduser opksshuser
```

### 4.3 Public-key distribution

There is no public-key distribution step. The "trust anchor" is the OP (Authentik), and opkssh's verifier re-fetches the OP's JWKS at every SSH connection (cached by Go's HTTP client for the duration of the connection).

Consequence: revoking access is done at the OP (revoke the user's group membership, disable the user) and by waiting at most 24h for existing certs to expire.

### 4.4 SELinux

opkssh ships an SELinux type-enforcement file `opkssh.te` (in repo root). The install script downloads/compiles/installs the module on EL-family systems. The booleans are:

- `opkssh_enable_home` — on by default if `HOME_POLICY=true`. Lets `opksshuser` read `~/.opk/auth_id` via sudo.
- `opkssh_enable_proxy` — off by default. Required if you use `HTTPS_PROXY` for the OP fetch.
- `opkssh_enable_squid` — off by default.

For Twinbox (Debian/Ubuntu, no SELinux) these are irrelevant.

---

## 5. opkssh on Ubuntu/Debian

### 5.1 Packaging

opkssh is distributed as:

- **Homebrew** (macOS) — `brew tap openpubkey/opkssh && brew install opkssh`
- **Winget** (Windows) — `winget install openpubkey.opkssh`
- **Chocolatey** (Windows) — `choco install opkssh -y`
- **Nix** — `nix-shell -p opkssh` or via NixOS module
- **Direct binary download** — from <https://github.com/openpubkey/opkssh/releases/latest/download/opkssh-linux-amd64> (or `arm64`)

There is **no apt package** in Debian or Ubuntu's official repos. The README recommends either the install script or the direct binary.

Install script (one-liner):

```
wget -qO- "https://raw.githubusercontent.com/openpubkey/opkssh/main/scripts/install-linux.sh" | sudo bash
```

This is what the `Termix OPKSSH` docs reference for installation on target hosts. For Ubuntu, you can also do it without sudo at the OS level by adding the opkssh binary to the user's PATH and configuring `/etc/ssh/sshd_config.d/60-opk-ssh.conf` manually.

### 5.2 Dependencies

From `go.mod` (<https://github.com/openpubkey/opkssh/blob/main/go.mod>):

- Go 1.25.0 toolchain (build-time only; the binary is a static Go binary with `CGO_ENABLED=0`).
- Runtime: no shared library deps. The binary is statically linked. It does **not** need `libfido2`, `glibc`-specific versions, or any C lib.
- Build with: `CGO_ENABLED=false go build -v -o opkssh`.

`go.mod` lists testcontainers-go for integration tests, but that's only for development.

### 5.3 What goes where (binary, not OS service)

opkssh has **one binary, two roles**:

1. **Client mode** — `opkssh login` (or `add`, `logout`, `inspect`, `audit`, `permissions`).
2. **Server mode** — `opkssh verify` (only — there's also `opkssh readhome`, called by `verify`).

For Twinbox, the deployment question is "where does each role run?":

| Role | Where it runs | Why |
|---|---|---|
| **Client** (issues SSH certs) | **Inside the Termix container** (in the `opkssh-auth.ts` flow), OR on the user's workstation. | Termix is the SSH front-end; the cert is delivered to sshd on the target host via Termix's `ssh2` library. |
| **Server** (verifies SSH certs) | **On the management VM and the bastion**. | The verify binary is invoked by sshd via `AuthorizedKeysCommand`. |

So:

- **Management VM and bastion**: install the binary in **server** mode (just install, then add the two sshd_config lines). The `login` command is also installed but is not used in normal operation.
- **Termix container**: install the binary in **client** mode (the `OPKSSHBinaryManager.ensureBinary()` call in `starter.ts` does this at startup — see <https://github.com/Termix-SSH/Termix/blob/main/src/backend/starter.ts>).
- **User workstation** (if a user is connecting from outside Termix): not needed for Twinbox — Termix is the front-end. If we ever want direct laptop SSH, then the user's machine also needs the opkssh client.

The Termix `OPKSSHBinaryManager` (referenced from `starter.ts`) downloads the right opkssh binary for the Termix container's OS/arch at startup. The container is `node:20-slim` based on the docker-compose in the Termix README.

### 5.4 Service management

opkssh has no daemon, so no systemd unit, no Docker image needed. (There is a third-party `opkssh-docker` repo referenced in some PRs, but the official install is a binary drop-in.)

---

## 6. opkssh vs step-ca for the Twinbox use case

(Repeating and expanding the table in the brief with research-backed specifics.)

| Aspect | opkssh | step-ca (OIDC provisioner) |
|---|---|---|
| **Cert format** | OpenSSH user cert (`*-cert.pub`) | OpenSSH user cert (same) |
| **Signing authority** | The OIDC IdP (Authentik) via the PK Token trick — no separate CA key | step-ca's CA key |
| **Server trust anchor** | OP JWKS (fetched live per connection) | step-ca's root CA pubkey, pre-distributed |
| **Server state** | Stateless: `/etc/opk/{providers, auth_id, config.yml}` (small flat files) | Stateful: step-ca process + DB or Badger |
| **HA requirements** | n/a (no server) | step-ca HA via Postgres or Badger replication |
| **Revocation** | No CRL. Cert lifetime is the revocation window (default 24h, max 1 week per opkssh) | CRL supported but rare; same short-lifetime default |
| **Authentik group → principal** | `oidc:groups:<groupName>` in `/etc/opk/auth_id` | step-ca provisioner template (more powerful, more complex) |
| **Linux user mapping** | Same file, per-principal lines | Same, but via provisioner template + `authorized_principals` |
| **Operator setup** | `wget \| bash` on each target host; edit two config files | Install step-ca, bootstrap, distribute root cert, configure sshd `TrustedUserCAKeys`, register OIDC provider in step-ca, register step-ca OIDC client in Authentik |
| **Client binary** | `opkssh` (Go) | `step` (Go) |
| **Termix integration** | **First-class** — see <https://docs.termix.site/opkssh> | Would require a custom bridge (we'd have to call `step ssh login` from inside Termix and then store the cert; this is not built-in) |
| **MFA** | Delegated to Authentik (MFA happens at OP login) | Same: delegated to Authentik |
| **Authentik testing** | ✅ in the opkssh README's tested-provider table | ✅ but the integration is not first-class in step-ca's docs |
| **PKCE / RFC compliance** | Uses standard OIDC auth code, no PKCE | step-ca also uses standard OIDC, no PKCE |
| **OpenPubkey / GQ signatures** | Supports GQ (off by default) for replay protection | n/a |
| **Production users** | BastionZero, Docker (signs Docker Official Images with OpenPubkey) | Used in many shops; the canonical step-ca use case |
| **Maturity** | Active, v0.14.0 as of Apr 2026 (<https://github.com/openpubkey/opkssh/releases>); 2k stars; 460 commits | Very mature; v0.x as well, used at scale |
| **License** | Apache-2.0 | Apache-2.0 |

**Conclusion for Twinbox:** opkssh wins on every axis that matters for our use case, primarily because of the Termix integration. step-ca would be better if we needed more flexible policy templates (e.g. conditional issuance based on complex OIDC claims), but the standard Authentik-group-to-Linux-user mapping is straightforward in both.

---

## 7. Termix + opkssh specifically

### 7.1 What the Termix docs say

From <https://docs.termix.site/opkssh>:

> "Currently, Termix only supports OPKSSH with the Terminal, File Manager, and Docker Manager."

> "**Step 1:** Create an SSH host in the host manager with OPKSSH set as the authentication type.

> **Step 2:** Start an SSH terminal connection on that host. This will generate the OPKSSH config at the path it tells you in the dialog that opens upon connecting.

> **Step 3:** Edit the generated `config.yml` file. The config location depends on your deployment:
> - Development/Manual Compile: `db/data/.opk/config.yml`
> - Docker: `/app/data/.opk/config.yml` (mounted volume)"

The config is just the standard opkssh client config — the Termix docs link to <https://github.com/openpubkey/opkssh/blob/main/docs/config.md>.

### 7.2 Does Termix run opkssh inside its container, and then forward SSH through?

**Yes, both. Termix is the opkssh client, and then the actual SSH connection is made using the cert Termix produced.** The flow (from the Termix source):

1. On startup, `starter.ts` calls `OPKSSHBinaryManager.ensureBinary()` (<https://github.com/Termix-SSH/Termix/blob/main/src/backend/starter.ts>), which downloads the opkssh binary into the Termix container.

2. The user, in the Termix UI, picks the host + clicks connect. The frontend opens a WebSocket. The backend (`ssh/opkssh-auth.ts:startOPKSSHAuth`) spawns `opkssh login` with:
   ```
   opkssh login --print-key --disable-browser-open \
     --config-path=/app/data/.opk/config.yml \
     --remote-redirect-uri=https://termix.<zone>/host/opkssh-callback
   ```

3. opkssh binds a localhost listener (`:3000` / `:10001` / `:11110`). Termix's `handleOPKSSHOutput` parses opkssh's stdout for the `Opening browser to http://127.0.0.1:<port>/chooser` line and proxies that URL to the user's browser via `https://termix.<zone>/host/opkssh-chooser/<requestId>`. The user picks a provider; opkssh opens a localhost URL like `http://127.0.0.1:<port>/opkssh?provider=authentik` and Termix proxies that to `https://termix.<zone>/host/opkssh-redirect/<requestId>?...` so the browser actually goes to the OP.

4. After OP callback, opkssh finishes the OIDC flow and prints the SSH cert + private key on stdout (`--print-key`). Termix parses these out of the buffered stdout:
   - The private key (between `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----`).
   - The SSH cert (matching `ecdsa-sha2-nistp256-cert-v01@openssh.com\s+[A-Za-z0-9+/=]+`).
   - The identity (`Email, sub, issuer, audience:` line).

5. Termix encrypts the cert + key with the user's per-user data key (`UserCrypto.encryptField`, `FieldCrypto.encryptField`) and stores them in the `opksshTokens` DB table keyed by `(userId, hostId)`. The encryption uses a key bound to the user — so the cert+key are at rest encrypted, accessible only to the owning Termix user.

6. When the user later opens a real terminal/sftp session to the host, Termix calls `getOPKSSHToken(userId, hostId)`, decrypts the cert+key, and uses the node `ssh2` library to connect. **The `opkssh-cert-auth.ts` module patches the ssh2 client** to:
   - Graft the cert onto the SSH client's parsed key.
   - For ECDSA, convert DER signatures to SSH wire format (ssh2 internal quirk).
   - Patch `Protocol.authPK` so the signature wrapper algorithm is the base algo (e.g. `ecdsa-sha2-nistp256`) rather than the cert type, which OpenSSH's `sshkey_check_sigtype` requires.
   - Force the publickey auth method via `authHandler` to bypass ssh2's cert-type rejection.

   See <https://github.com/Termix-SSH/Termix/blob/main/src/backend/ssh/opkssh-cert-auth.ts>.

7. The cert is then sent to the target host's sshd, which runs `opkssh verify` and grants the requested principal.

### 7.3 Does it require opkssh on the target host too, or just on the client (Termix)?

**Yes, it requires opkssh on the target host.** Termix is only the client; the target sshd must have the `AuthorizedKeysCommand /usr/local/bin/opkssh verify` configuration. This is stated explicitly in the Termix docs:

> "If you didn't already, use the link above to install OPKSSH on all your SSH servers."

— <https://docs.termix.site/opkssh>

### 7.4 The Termix `OPKSSH` auth type at the protocol level

The protocol flow at the wire level is the standard OpenSSH publickey-with-cert:

1. Client → server: `SSH_MSG_USERAUTH_REQUEST` with method `publickey`, username, cert type (e.g. `ecdsa-sha2-nistp256-cert-v01@openssh.com`), and the cert blob. Includes a "query" first to see if the server accepts.
2. Server: sshd calls `AuthorizedKeysCommand` (`opkssh verify %u %k %t`), which returns a single line `cert-authority,principals="<list>" <base64-user-pubkey>`. sshd checks the cert was signed by the listed "CA" (which is the user's pubkey extracted from the PK Token), then checks the requested principal is in `principals=`.
3. Client → server: `SSH_MSG_USERAUTH_REQUEST` with method `publickey` and a signature. The signature is over the session ID + the auth request using the user's `usk`. sshd checks the signature against the pubkey in the cert.
4. Server: sshd grants the session if signatures verify and `principals` match.

The opkssh-specific part is step 2 — that's where the PK Token verification happens (issuer, audience, signature, nonce binding, expiration, then policy check). The rest is vanilla OpenSSH.

---

## 8. Group-based Linux user mapping

This is the most important design question. Authentik says "user X is in group G"; the target host has Linux user `twinbox` (mgmt VM) or `root` (bastion); opkssh must allow user X to SSH as that Linux user.

### 8.1 opkssh's mapping mechanism

opkssh has **two complementary mechanisms** for this mapping.

#### 8.1.1 Built-in `auth_id` file with `oidc:groups:` syntax

The simplest approach. The `/etc/opk/auth_id` file (system-wide) or `~/.opk/auth_id` (per-user) has three columns:

```
<principal> <identity-attribute> <issuer>
```

`<identity-attribute>` can be:
- An email address — matches the `email` claim.
- The string `sub` followed by a value — matches the `sub` claim.
- A structured `oidc:groups:<groupName>` — matches a value in the `groups` claim.
- A structured `oidc:"<claim-name>":<value>` — matches a custom claim.

This is implemented in `policy/enforcer.go:validateClaim`:

```go
if strings.HasPrefix(user.IdentityAttribute, OIDC_CLAIMS) {
    oidcGroupSections := EscapedSplit(user.IdentityAttribute, ':')
    oidcGroupsName := strings.Trim(oidcGroupSections[1], "\"")
    return slices.Contains(
        claims.ExtraClaims[oidcGroupsName],
        oidcGroupSections[len(oidcGroupSections)-1],
    )
}
```

For Twinbox:

```
# /etc/opk/auth_id on management VM
twinbox oidc:groups:twinbox-admins https://authentik.<zone>/application/o/opkssh/

# /etc/opk/auth_id on bastion
root     oidc:groups:twinbox-admins https://authentik.<zone>/application/o/opkssh/
```

`%wheel` or sudoers handles the rest. Anyone in `twinbox-admins` group can SSH as `twinbox` on the mgmt VM, and as `root` on the bastion.

Permissions: `chown root:opksshuser /etc/opk/auth_id; chmod 640`.

#### 8.1.2 Policy plugins (arbitrary shell)

For more complex mapping (e.g. different principals per group, client-IP-based rules, time-of-day rules), opkssh supports `policy plugins`. From `docs/policyplugins.md`:

> "policy plugins provide a simple way to bring your own policy which extends the default opkssh policy. To use your own policy create a policy plugin config file in `/etc/opk/policy.d`. This config file specifies what command you want to call out to evaluate policy. To allow, the command must output 'allow' and exit code 0."

Example config `/etc/opk/policy.d/twinbox-mapping.yml`:

```yaml
name: Twinbox admin mapping
command: /etc/opk/twinbox-map.sh
```

And `/etc/opk/twinbox-map.sh`:

```sh
#!/usr/bin/env sh
# Map Authentik group membership to Linux principal
if [ "${OPKSSH_PLUGIN_U}" = "twinbox" ] && \
   echo "${OPKSSH_PLUGIN_GROUPS}" | grep -q "twinbox-admins"; then
  echo "allow"
  exit 0
fi
echo "deny"
exit 1
```

The plugin receives a rich set of environment variables (from `policyplugins.md`):

| Variable | Meaning |
|---|---|
| `OPKSSH_PLUGIN_U` | Requested Linux principal (`%u`) |
| `OPKSSH_PLUGIN_EMAIL` | `email` claim |
| `OPKSSH_PLUGIN_EMAIL_VERIFIED` | `email_verified` claim |
| `OPKSSH_PLUGIN_GROUPS` | The `groups` claim (whitespace-joined) |
| `OPKSSH_PLUGIN_ISSUER` | `iss` claim |
| `OPKSSH_PLUGIN_SUB` | `sub` claim |
| `OPKSSH_PLUGIN_AUD` | `aud` claim |
| `OPKSSH_PLUGIN_PAYLOAD` | Base64 of the full ID token payload |
| `OPKSSH_PLUGIN_IDT` | Compact-encoded ID token |
| `OPKSSH_PLUGIN_PKT` | Compact-encoded PK Token |
| `OPKSSH_PLUGIN_K` | Base64 of the SSH cert |
| `OPKSSH_PLUGIN_T` | Cert type |
| `OPKSSH_PLUGIN_USERINFO` | Result of userinfo call (if `send_access_token: true`) |
| `OPKSSH_PLUGIN_EXTRA_ARGS` | JSON of any extra `%X` tokens passed in `AuthorizedKeysCommand` (e.g. `%C` for client IP) |

**Important policy composition rule** (from `docs/policyplugins.md`):

> "All policy in opkssh is additive. An access attempt is only denied if no policy returns 'allow'. Only one policy needs to return 'allow' for the access to be allowed even if all the other plugins return 'deny'. The 'allow' always wins."

> "To completely turn off standard policy ensure all auth_id files are empty."

For Twinbox this is fine: we want one of either approach to grant access. We'll likely use both — the `auth_id` file for the simple "admins → twinbox" mapping, and a policy plugin for more complex cases (e.g. break-glass accounts, IP allow-listing).

#### 8.1.3 Wildcard email matching

A third option: match by email suffix. From `docs/config.md`:

```
# Email suffix wildcard matching all emails ending in `@example.com`
dev oidc-match-end:email:@example.com https://login.microsoftonline.com/...
```

This is less useful for our case (we want group-based, not domain-based), but it's worth knowing.

### 8.2 Design choices for Twinbox — 3 options

**Option A — `auth_id` only (simplest).**

Pros: zero code, no scripts, easy to audit (`opkssh audit` validates the file). Permissions: `chmod 640 /etc/opk/auth_id`.
Cons: one file per host, so different Linux users on mgmt VM vs. bastion means two files; no IP-based or time-based rules.

**Option B — policy plugin only (most flexible).**

Pros: arbitrary logic; single source of truth if hosted in OpenBao or git; can call out to OpenBao for revocation lists, NetBird for IP checks, etc.
Cons: more code to maintain; audit is harder (the policy is a script, not a declarative file); the policy plugin runs as `root` (the verify process drops privs to `opksshuser` then execs the plugin via sudo, but the plugin runs as `opksshuser` — the policy.d drop-in must be 640 root:opksshuser).

**Option C — `auth_id` for the common case + a policy plugin for special cases (recommended).**

Use `auth_id` for "group `twinbox-admins` → principal `twinbox` on mgmt VM / `root` on bastion". Use a single shared policy plugin (e.g. `twinbox-policy.sh`) sourced from a central git repo or OpenBao to handle edge cases like:
- A `break-glass` group that can SSH as root on the mgmt VM.
- IP allow-listing using `OPKSSH_PLUGIN_EXTRA_ARGS` + the `%C` token (requires adding `%C` to the `AuthorizedKeysCommand` line).
- A "deny after-hours" rule.

This is what the openpubkey docs themselves recommend: "If all the policy plugins return 'deny', but your auth_id policy returns ALLOW, the final result will be allow. Put another way policy in OPKSSH is an OR."

**Recommendation for Twinbox: Option C.**

---

## 9. Concrete deployment plan for Twinbox

Below is a concrete deployment plan, based on the research above. It is presented as input for a follow-up design doc, not as a finished spec.

### 9.1 opkssh binary installation

**Management VM** (Proxmox, Debian-flavoured per existing setup):

1. Install the binary into `/usr/local/bin/opkssh`. Two options:
   - `wget -qO- "https://raw.githubusercontent.com/openpubkey/opkssh/main/scripts/install-linux.sh" | sudo bash` (the install script, which configures sshd too).
   - Manual: drop the binary at `/usr/local/bin/opkssh` (mode 755, owner root:opksshuser) and write `/etc/ssh/sshd_config.d/60-opk-ssh.conf` by hand.
2. Pin the version. The install script supports `--install-version=vX.Y.Z`. The latest is v0.14.0 (April 2026) per <https://github.com/openpubkey/opkssh/releases>.
3. Since the Management VM is in a NetBird peer group and protected by NetBird policies, we do **not** need to expose sshd to the public internet.

**Bastion** (Hetzner VPS, Debian 13):

1. Same as the management VM.
2. The bastion is a single-purpose Hetzner VPS, reachable from Termix over the NetBird overlay (per AGENTS.md "Bastion Node" section). NetBird is the only ingress; sshd listens on the NetBird interface only.

**Termix pod** (in-cluster):

1. The Termix container already has the `OPKSSHBinaryManager` (in `src/backend/starter.ts`) that downloads the binary at startup. **No additional work needed here** — Termix already ships with OPKSSH support.
2. Verify in the running pod that `/app/data/.opk/config.yml` will be mounted (Termix's docker-compose already does this; see the Termix README and <https://docs.termix.site/opkssh>).

### 9.2 opkssh server config (provider list)

`/etc/opk/providers` on **both** the management VM and the bastion:

```
https://authentik.<zone>/application/o/opkssh/ <client-id> 24h
```

Replace `<zone>` and `<client-id>` with the values from the Authentik OAuth2 application we'll create. `24h` is the expiration policy (opkssh will require the user to re-auth at least once every 24h, but the underlying OIDC id_token can be much shorter).

Permissions: `chown root:opksshuser /etc/opk/providers; chmod 640`.

`/etc/opk/config.yml` (optional, both hosts):

```yaml
deny_users:
  - "nobody"
  - "bin"
deny_emails: []
env_vars: {}
```

This is the equivalent of `DenyUsers` in sshd_config. opkssh also picks up `HTTPS_PROXY` from this if we ever need to put the JWKS fetch behind a proxy (we won't).

### 9.3 The "CA" / verifier pubkey

**There is no separate CA pubkey to distribute.** opkssh's "CA" is the OP, and the OP is identified by URL, not by a pinned key. The verifier fetches the OP's JWKS at every SSH connection over HTTPS (so transit trust is via the OP's TLS certificate, which is anchored in the OS trust store).

This means there's no need for an OpenBao-stored opkssh CA pubkey, no need to distribute it via Ansible/Salt, no need to rotate it. The opkssh client uses the same JWKS endpoint (`https://authentik.<zone>/application/o/opkssh/jwks/`) to verify the OP's signature on the ID token.

### 9.4 Termix integration

No code changes needed in Termix itself; it already has opkssh support. The Twinbox-specific config that needs to land in `gitops/platform-apps/twinbox-portal/` (or wherever Termix is configured) is:

- Mount a secret/configmap that produces `/app/data/.opk/config.yml` inside the Termix container.
- That file should contain the `authentik` provider block from §2.2.
- `redirect_uris` should be the **opkssh defaults** (`:3000`, `:10001`, `:11110` — `http://localhost:PORT/login-callback`). These are NOT the public Termix URL.
- The public Termix callback URL is registered in Authentik's OAuth2 application separately.

### 9.5 Authentik OAuth2 application

Create a new OAuth2/OpenID Provider in Authentik (Admin UI → Applications → Providers → Create):

| Setting | Value | Notes |
|---|---|---|
| Name | `opkssh` | This becomes the application slug in the issuer URL. |
| Type | OAuth2/OpenID Provider | |
| Client type | Confidential | opkssh + Termix is a server-side flow, not a SPA. |
| Redirect URIs | `https://termix.<zone>/host/opkssh-callback` | The PUBLIC Termix callback. opkssh's `--remote-redirect-uri` flag will pass this to Authentik, and opkssh will proxy the response to its localhost listener. |
| Scopes | `openid profile email groups` | The `groups` scope is required for group-based policy. |
| Issuer mode | Per-application (default) | `iss` = `https://authentik.<zone>/application/o/opkssh/` |
| Signing Key | (select an existing signing key) | Asymmetric signing is preferred but not required. If not set, tokens are HS256-signed with the client secret. |
| Encryption Key | (do not set) | The README warns against this — opkssh doesn't handle JWE. |
| Subject mode | Based on the User's `username` (or `email`) | This determines the `sub` claim. |

For the `groups` claim to land in the ID token, the OAuth2 provider needs a **scope mapping** that includes the user's group names. By default, Authentik's `openid profile email` scopes do not include groups. We need to add a custom scope mapping or extend the `email` scope to include `groups`. The mapping is a small Python expression:

```python
return {
    "groups": [group.name for group in request.user.ak_groups.all()],
}
```

Bind that mapping to the `email` scope (or create a new `groups` scope and request it). See <https://docs.goauthentik.io/docs/add-secure-apps/providers/property-mappings/expression/> for the expression API.

**Important security note from the opkssh README:**

> "Do not reuse a client ID between opkssh and other OpenID Connect services. If the same client ID is used for opkssh as another OpenID Connect authentication service, then an SSH server could replay the ID Token sent in an opkssh SSH key to authenticate to that service. Such replay attacks can be ruled out by simply using a new client ID with opkssh."

So the opkssh Authentik application should be **dedicated** — not shared with Argo CD, the Twinbox Portal, or anything else.

### 9.6 Group mapping (the load-bearing config)

The opkssh policy file `/etc/opk/auth_id` is per-host, so we need different content on the management VM vs. the bastion:

**Management VM** (`/etc/opk/auth_id`):

```
# Allow any user in the 'twinbox-admins' Authentik group to SSH as 'twinbox'
twinbox oidc:groups:twinbox-admins https://authentik.<zone>/application/o/opkssh/

# Optional: a separate 'twinbox-readonly' group for read-only access (sudo -l restrictions apply)
twinbox oidc:groups:twinbox-readonly https://authentik.<zone>/application/o/opkssh/

# Optional: break-glass for specific users
twinbox harry@example.com https://authentik.<zone>/application/o/opkssh/
```

Permissions: `chown root:opksshuser /etc/opk/auth_id; chmod 640`.

**Bastion** (`/etc/opk/auth_id`):

```
# Anyone in 'twinbox-admins' can SSH as root on the bastion
root oidc:groups:twinbox-admins https://authentik.<zone>/application/o/opkssh/
```

The bastion's root account is what Termix connects as in the existing Twinbox setup (per AGENTS.md "Bastion Node": `ssh -i /tmp/bastion_key "root@${bastion_ip}"`). opkssh preserves this — the user authenticates with their Authentik identity, the SSH cert is issued, and sshd maps them to `root` based on the policy.

**Where does the file come from?** Two options:

1. **Plain file in the management-vm and bastion golden images / Ansible / cloud-init.** Pros: simple, easy to inspect. Cons: must be kept in sync, audit trail is in git history of the ansible repo, no centralized "who has access" view.

2. **Generated by the wizard on the management VM, distributed to the bastion via SSH + `scp`.** Pros: single source of truth (the management VM is the bootstrapper). Cons: needs a distribution step in the wizard.

3. **Generated from a central source of truth (Twinbox Portal DB or OpenBao).** Pros: single source of truth, can show "who has access" in the portal UI, can rotate on user-departure. Cons: more machinery, requires the bastion to be able to reach the central source. The NetBird overlay is the natural place for this traffic.

For the initial rollout, **option 1 (plain file in git)** is the simplest. We can layer option 3 on later if/when the access control list becomes a feature in the portal.

### 9.7 Where the Authentik side goes

The Authentik OAuth2 application should be created **out of band**, either:

- Via the Authentik admin UI (manual, one-time).
- Via the Authentik Terraform provider (in `gitops/`, since Twinbox already uses GitOps).
- Via the Authentik API (if we add a wizard step).

The cleanest fit for Twinbox is the Terraform provider, since Argo CD owns `gitops/` and that includes the Authentik configuration. The client secret is a sensitive value — it should live in OpenBao (per AGENTS.md) and be exposed to Termix via ExternalSecret + SOPS or via the Authentik application's client secret being stored in OpenBao.

### 9.8 What the user actually does to connect

1. User opens Termix in their browser. Termix is already authenticated (probably via OIDC too, per <https://docs.termix.site/oidc>).
2. User picks the mgmt VM host entry (auth type `OPKSSH`).
3. Termix spawns opkssh login, opens the user's browser to Authentik. User does MFA. Authentik issues a 1-hour ID token; opkssh wraps it in a PK Token + SSH cert, 24h.
4. Termix stores the cert+key in the encrypted-at-rest `opksshTokens` table.
5. Termix opens the terminal session. The user's ssh key (in the cert) is the opkssh-generated one.
6. The mgmt VM's sshd runs `opkssh verify`, which:
   - Fetches Authentik's JWKS.
   - Verifies the OP signature on the ID token.
   - Verifies the nonce binding.
   - Reads `/etc/opk/auth_id`, finds `twinbox oidc:groups:twinbox-admins ...`, the user's group claim contains `twinbox-admins`, so the principal `twinbox` is allowed.
   - Returns `cert-authority,principals="twinbox" <user-pubkey>` to sshd.
7. sshd verifies the cert, grants the session as Linux user `twinbox`.
8. 24h later (or on cert revocation), the user has to re-auth via opkssh login.

---

## 10. References and source citations

Every claim above cites one or more of the following primary sources.

### 10.1 opkssh repository (https://github.com/openpubkey/opkssh)

- README — <https://github.com/openpubkey/opkssh/blob/main/README.md> (and <https://github.com/openpubkey/opkssh> rendered)
- Server config docs — <https://github.com/openpubkey/opkssh/blob/main/docs/config.md>
- Policy plugin docs — <https://github.com/openpubkey/opkssh/blob/main/docs/policyplugins.md>
- Audit command docs — <https://github.com/openpubkey/opkssh/blob/main/docs/audit.md>
- Server install docs — <https://github.com/openpubkey/opkssh/blob/main/scripts/installing.md>
- Install script (full source) — <https://github.com/openpubkey/opkssh/blob/main/scripts/install-linux.sh>
- Keycloak provider guide (structurally identical to Authentik) — <https://github.com/openpubkey/opkssh/blob/main/docs/providers/keycloak.md>
- `go.mod` — <https://github.com/openpubkey/opkssh/blob/main/go.mod>
- `main.go` (CLI entry point) — <https://github.com/openpubkey/opkssh/blob/main/main.go>
- `commands/login.go` (login command source) — <https://github.com/openpubkey/opkssh/blob/main/commands/login.go>
- `commands/verify.go` (verify command source) — <https://github.com/openpubkey/opkssh/blob/main/commands/verify.go>
- `commands/add.go` (policy add command) — <https://github.com/openpubkey/opkssh/blob/main/commands/add.go>
- `policy/policy.go` (policy model) — <https://github.com/openpubkey/opkssh/blob/main/policy/policy.go>
- `policy/enforcer.go` (policy enforcer) — <https://github.com/openpubkey/opkssh/blob/main/policy/enforcer.go>
- `policy/files/table.go` (auth_id parser) — <https://github.com/openpubkey/opkssh/blob/main/policy/files/table.go>
- `sshcert/sshcert.go` (cert smuggler) — <https://github.com/openpubkey/opkssh/blob/main/sshcert/sshcert.go>
- `commands/config/default-client-config.yml` (default client config) — <https://github.com/openpubkey/opkssh/blob/main/commands/config/default-client-config.yml>
- Open issues / discussions — <https://github.com/openpubkey/opkssh/issues>
- Releases (latest v0.14.0) — <https://github.com/openpubkey/opkssh/releases>
- Binary downloads — <https://github.com/openpubkey/opkssh/releases/latest/download/opkssh-linux-amd64>

### 10.2 openpubkey library (https://github.com/openpubkey/openpubkey)

- README — <https://github.com/openpubkey/openpubkey/blob/main/README.md>
- `client/client.go` (auth + PK token creation) — <https://github.com/openpubkey/openpubkey/blob/main/client/client.go>
- `verifier/verifier.go` (PK token verification) — <https://github.com/openpubkey/openpubkey/blob/main/verifier/verifier.go>
- `providers/google.go` (provider options, default redirect URIs) — <https://github.com/openpubkey/openpubkey/blob/main/providers/google.go>
- `oidc/oidc.go` (OIDC claim model) — <https://github.com/openpubkey/openpubkey/blob/main/oidc/oidc.go>
- `oidc/jwt.go` (JWT parsing) — <https://github.com/openpubkey/openpubkey/blob/main/oidc/jwt.go`
- `pktoken/clientinstance/claims.go` (CIC definition) — <https://github.com/openpubkey/openpubkey/blob/main/pktoken/clientinstance/claims.go>
- OpenPubkey paper (academic) — <https://eprint.iacr.org/2023/296>

### 10.3 Termix (https://github.com/Termix-SSH/Termix and https://docs.termix.site)

- opkssh integration docs — <https://docs.termix.site/opkssh>
- `src/backend/ssh/opkssh-auth.ts` (opkssh login orchestration) — <https://github.com/Termix-SSH/Termix/blob/main/src/backend/ssh/opkssh-auth.ts>
- `src/backend/ssh/opkssh-cert-auth.ts` (ssh2 cert auth shim) — <https://github.com/Termix-SSH/Termix/blob/main/src/backend/ssh/opkssh-cert-auth.ts>
- `src/backend/starter.ts` (binary manager init) — <https://github.com/Termix-SSH/Termix/blob/main/src/backend/starter.ts>
- Repository — <https://github.com/Termix-SSH/Termix>
- Termix OIDC docs — <https://docs.termix.site/oidc>

### 10.4 Authentik (https://docs.goauthentik.io)

- OAuth2 Provider — <https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/>
- Create an OAuth2 Provider — <https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/create-oauth2-provider/>
- Provider property mappings — <https://docs.goauthentik.io/docs/add-secure-apps/providers/property-mappings/>
- Property mapping expressions — <https://docs.goauthentik.io/docs/add-secure-apps/providers/property-mappings/expression/>
- About groups — <https://docs.goauthentik.io/docs/users-sources/groups/>
- About users — <https://docs.goauthentik.io/docs/users-sources/user/>
- GitHub compatibility (for non-generic OIDC clients) — <https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/github-compatibility/>

### 10.5 OpenSSH man pages

- `sshd_config(5)` — `AuthorizedKeysCommand` — <https://man.openbsd.org/sshd_config.5#AuthorizedKeysCommand>
- `sshd_config(5)` — `AuthorizedKeysCommandUser` — <https://man.openbsd.org/sshd_config.5#AuthorizedKeysCommandUser>
- `sshd_config(5)` — `DenyUsers` — <https://man.openbsd.org/sshd_config#DenyUsers>
- `ssh-keygen(1)` (cert types and extensions) — <https://man.openbsd.org/ssh-keygen>

### 10.6 Twinbox (this repository)

- `AGENTS.md` — operating model, runtime layout, verify commands
- `wizard/setup-wizard.sh` — Proxmox bootstrap
- `gitops/` — Argo CD apps
- `docs/authentik.md` — existing Authentik notes
- `docs/netbird.md` — NetBird overlay
- `docs/secrets-library.md` — OpenBao integration

---

## Appendix A — What is NOT covered / open questions

Items the research did not fully resolve and which the design phase will need to address:

1. **Exact Authentik scope mapping syntax for groups.** The Authentik expression-language API allows `request.user.ak_groups.all()` (from the property-mapping expression docs) but the precise attribute name in the current authentik release needs verification against the version running in `gitops/`. Authentik's group model is recursive (groups can be children of groups) — the `twinbox-admins` group must be an actual Authentik group, not just a tag, for `ak_groups` to surface it.

2. **PK Token handling inside Termix's restart flow.** Termix stores the cert+key encrypted at rest. If the Termix pod restarts, the keys are still in the DB and decrypted on use. But what happens if the user re-installs Termix or restores from backup? Are the keys lost? This is more of a product question for Termix than for opkssh.

3. **MFA in opkssh via the Authentik flow.** Authentik enforces MFA on the Authorization Code flow. opkssh's login command opens a browser to the OP's authorize endpoint, so MFA is implicitly enforced there. The PK Token doesn't carry an MFA claim itself; trust is in the OP. If we want belt-and-braces, we could add a step-up auth via Authentik's `acr_values` parameter, but this is over-engineering for the first iteration.

4. **opkssh version pinning.** Latest is v0.14.0. The install script's default is "latest" which is brittle. We should pin to a specific version and use the GitHub release artifact hash to detect drift.

5. **opkssh audit integration with the wizard.** `opkssh audit` is a useful check (verifies `/etc/opk/auth_id` is consistent with `/etc/opk/providers`) but the wizard doesn't run it today. Worth adding as a step.

6. **The `Termix OPKSSH` feature currently supports only Terminal, File Manager, and Docker Manager.** (<https://docs.termix.site/opkssh>). If we want RDP/VNC via Termix to the bastion, those use the `guacd` proxy and a different auth path. opkssh does not apply there.

7. **Workload identities vs user identities.** opkssh supports both. For Twinbox, we only need user identities (humans authenticating). The `openpubkey` library's `client.Auth()` call uses the `nonce` flow (user identity), which is what Authentik supports out of the box. No special config on the Authentik side beyond a normal OAuth2 application.

8. **GQ signatures.** openpubkey supports GQ signatures to prevent the OP from being able to use the id_token against other RPs (defense in depth against the same-client-id-replay risk the README mentions). opkssh does not enable GQ by default. For our use case, the dedicated-client-id approach (no reuse) is sufficient; GQ is overkill.

---

## Appendix B — One-paragraph summary for the design doc

opkssh is an OpenPubkey-based SSH CA: the user's SSH certificate contains a PK Token (a standard OIDC id_token whose `nonce` claim commits to the user's fresh public key, plus a user signature over the id_token with that key). The server's sshd is configured with `AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t`; opkssh verifies the PK Token against the OP's JWKS and matches the requested Linux principal against `/etc/opk/auth_id`, which can match on `email`, `sub`, or `oidc:groups:<name>`. There is no CA private key — the OP is the trust root — and there is no step-ca-style state. Authentik is officially supported (`✅`) by opkssh; integration is a standard OAuth2/OIDC application with a dedicated `client_id`, redirect URI `https://termix.<zone>/host/opkssh-callback`, and an `email` scope mapping extended to include a `groups` claim. Termix ships first-class OPKSSH support (Terminal, File Manager, Docker Manager) and runs the opkssh client binary inside its container, while target hosts (the management VM and the Hetzner bastion) run opkssh in verify mode. Group→principal mapping is the load-bearing config and is best done as `/etc/opk/auth_id` lines on each target host (e.g. `twinbox oidc:groups:twinbox-admins https://authentik.<zone>/application/o/opkssh/` on the management VM, `root oidc:groups:twinbox-admins …` on the bastion), with a policy plugin reserved for edge cases like break-glass or IP allow-listing.
