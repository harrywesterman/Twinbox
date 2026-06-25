# Termix Browser SSH

Termix is Twinbox's in-cluster browser SSH terminal. It runs as an Argo CD-managed application in the `termix` namespace and provides web-based SSH access to the **Management VM** and the **NetBird bastion**.

## Access

Visit:

```
https://termix.<zone>
```

Authentication is through Authentik OIDC. Only members of the Authentik `admins` group can log in.

## OPKSSH certificate authentication

Starting with the `install-opkssh` step, Termix uses [opkssh](https://github.com/openpubkey/opkssh) for SSH authentication:

- Termix stores an `~/.opk/config.yml` mounted from OpenBao via an ExternalSecret.
- When you open a host, Termix runs `opkssh login` inside its container.
- You complete Authentik authentication (including MFA) in your browser.
- Authentik returns an OIDC `id_token`; opkssh wraps it in an OpenPubkey PK Token and mints a short-lived SSH certificate.
- The certificate is valid for **16 hours** by default.
- The target host's sshd runs `opkssh verify` via `AuthorizedKeysCommand` and verifies the certificate against Authentik's JWKS endpoint.

The `/etc/opk/auth_id` file on each host maps Authentik group membership to Linux principals:

- Management VM: `twinbox oidc:groups:admins <issuer>`
- Bastion: `root oidc:groups:admins <issuer>`

## Hosts

Two hosts are configured by default:

| Host | Linux user | Auth type |
| --- | --- | --- |
| Management VM | `twinbox` | OPKSSH |
| Bastion VM | `root` | OPKSSH |

Static password/key credentials are removed from Termix after opkssh is validated, but remain on the hosts as break-glass credentials (see `docs/operations.md`).

## Troubleshooting

### "Could not get SSH certificate" / MFA not completed

Make sure you complete the Authentik MFA step in the browser. opkssh cannot mint a certificate without a valid `id_token`.

### "User not authorized" / groups claim missing

Check that the Authentik user is in the `admins` group and that the `groups` scope mapping is attached to the `opkssh` OAuth2 provider. The mapping expression should be:

```python
groups = [group.name for group in request.user.ak_groups.all()]
if request.user.is_superuser and "admins" not in groups:
    groups.append("admins")
return {"groups": groups}
```

### Certificate expired

Certificates are valid for 16 hours. Re-open the host in Termix to trigger a new `opkssh login`.

### Termix pod issues

```bash
kubectl -n termix logs deployment/termix -c termix
kubectl -n termix get secret termix-opkssh-config -o jsonpath='{.data.config\.yml}' | base64 -d
```

## Direct SSH from a laptop

You can also use `opkssh login` directly from your laptop. See `docs/ssh-access.md`.
