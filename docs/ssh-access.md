# SSH Access

Twinbox provides SSH access to the **Management VM** and **NetBird bastion** through two paths:

1. **Termix** — browser-based SSH at `https://termix.<zone>` (recommended).
2. **Direct SSH** — from your laptop using [opkssh](https://github.com/openpubkey/opkssh).

Both paths require:

- NetBird connectivity (you must be an admin peer).
- Authentik authentication with MFA.
- Membership in the Authentik `admins` group.

## Install opkssh on your laptop

Download the release for your platform:

```bash
# macOS (Homebrew not yet available; use the GitHub release)
curl -fsSL https://github.com/openpubkey/opkssh/releases/download/v0.14.0/opkssh-darwin-amd64 -o /usr/local/bin/opkssh
chmod +x /usr/local/bin/opkssh

# Linux
curl -fsSL https://github.com/openpubkey/opkssh/releases/download/v0.14.0/opkssh-linux-amd64 -o /usr/local/bin/opkssh
chmod +x /usr/local/bin/opkssh
```

## Configure the Authentik provider

Create `~/.opk/config.yml`:

```yaml
default_provider: authentik
providers:
  - alias: authentik
    issuer: https://authentik.<zone>/application/o/opkssh/
    client_id: <your-opkssh-client-id>
    client_secret: <your-opkssh-client-secret>
    scopes: openid profile email groups
    access_type: offline
    prompt: consent
    redirect_uris:
      - http://localhost:3000/login-callback
      - http://localhost:10001/login-callback
      - http://localhost:11110/login-callback
    send_access_token: false
```

The `client_id` and `client_secret` are stored in OpenBao at `twinbox/global/opkssh`.

## Log in and get a certificate

```bash
opkssh login
```

This opens your browser to Authentik. Complete MFA. The SSH certificate is written to `~/.ssh/id_ecdsa-cert.pub` and loaded into `ssh-agent`.

## SSH to the Management VM

```bash
ssh twinbox@<management-vm-netbird-ip>
```

The NetBird IP is the peer IP for `twinbox-mgmt-<cluster_slug>`.

## SSH to the bastion

```bash
ssh root@<bastion-netbird-ip>
```

The NetBird IP is the peer IP for `twinbox-<cluster_id>-proxy`.

## ~/.ssh/config snippet

```
Host twinbox-mgmt
  HostName <management-vm-netbird-ip>
  User twinbox
  IdentityFile ~/.ssh/id_ecdsa
  IdentitiesOnly yes

Host twinbox-bastion
  HostName <bastion-netbird-ip>
  User root
  IdentityFile ~/.ssh/id_ecdsa
  IdentitiesOnly yes
```

`IdentitiesOnly yes` prevents ssh from offering other keys if the certificate fails.

## Certificate renewal

Certificates expire after 16 hours. Run `opkssh login` again to renew.

## Break-glass

If Authentik or opkssh is unavailable, break-glass credentials remain on the hosts. See `docs/operations.md`.
