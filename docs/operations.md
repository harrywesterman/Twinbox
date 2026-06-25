# Operations: break-glass SSH access

Twinbox's normal SSH path to the Management VM and the NetBird bastion is through Termix with short-lived, Authentik-MFA-gated certificates issued by [opkssh](https://github.com/openpubkey/opkssh). If that path is unavailable (for example, because Authentik is down, the opkssh verifier is misconfigured, or an admin has lost their Authentik credentials), static break-glass credentials remain on the hosts.

## Management VM break-glass

The Management VM's `twinbox` user password is stored in:

```
/opt/twinbox/bootstrap/secrets/global/twinbox-login.json
```

Use it to SSH directly over the NetBird overlay:

```bash
ssh twinbox@<management-vm-netbird-ip>
```

The NetBird IP can be found from the management VM peer name (`twinbox-mgmt-<cluster_slug>`) or from step state under `/opt/twinbox/manager-data/step-state/`.

## Bastion break-glass

The Hetzner bastion's root SSH key is stored in:

```
/opt/twinbox/manager-data/ssh/netbird-<cluster_id>/id_ed25519
```

Use it to SSH directly over the public internet or the NetBird overlay:

```bash
ssh -i /opt/twinbox/manager-data/ssh/netbird-<cluster_id>/id_ed25519 root@<bastion-ip>
```

The bastion IP is in `/opt/twinbox/bootstrap/secrets/global/netbird-bastion-<cluster_id>.json` under `NETBIRD_IP`.

## Disabling opkssh

If opkssh is causing lockouts, remove the sshd drop-in on the affected host and restart sshd:

```bash
rm -f /etc/ssh/sshd_config.d/60-opk-ssh.conf
systemctl restart sshd
```

This leaves the existing password/key authentication intact.

## Rotating break-glass credentials

- Management VM password: change it with `passwd twinbox` and update `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`.
- Bastion SSH key: generate a new key pair, update the Hetzner server, and replace the key file in `/opt/twinbox/manager-data/ssh/netbird-<cluster_id>/`.

## When to use break-glass

Only use these credentials when the normal opkssh/Termix path is not working. They are intentionally not exposed in Termix after Phase 2/3.
