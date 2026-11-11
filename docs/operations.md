# Operations: break-glass SSH access

## NetBird client DNS and internet exits

The manager worker reconciles human NetBird users every 30 seconds. It preserves
their roles and existing groups, adds the cluster's AdGuard DNS and exit-node-user
auto-groups, and enables user group propagation. Existing devices inherit the
groups; future devices inherit them when their owner enrolls them. A newly created
user receives these defaults within one reconciliation interval. Blocked users,
users awaiting approval, and service users are excluded. Infrastructure enrolled
with setup keys keeps its separate group assignments.

AdGuard is the primary resolver through the Management VM's NetBird DNS forwarder.
DNS filtering applies while NetBird DNS management is enabled on the client;
applications using their own encrypted DNS can bypass it.

Clients can select `twinbox-<cluster-id>-bastion-exit` or
`twinbox-<cluster-id>-home-exit` in NetBird. Both advertise the internet default
route with masquerading and Auto Apply disabled. The home exit runs through the
Management VM routing peer and its discovered local gateway. The LAN route remains
available separately. The exits use distinct route network identifiers so clients
present them as independent choices instead of treating them as HA routing peers.

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
