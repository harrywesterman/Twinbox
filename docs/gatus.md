# Gatus on the bastion

Twinbox runs the open-source Gatus image as a separate Docker Compose project in
`/opt/twinbox/gatus` on the NetBird bastion. The public page is
`https://status.<public-zone>`. Neither Gatus nor its HTTPS route depends on
Kubernetes, Authentik or the Portal. A complete bastion outage cannot generate an
alert; an external heartbeat is deliberately outside this version.

## Installation and notifications

1. Complete **Provision NetBird bastion** in the wizard.
2. Run **Install Gatus Status**. The installer checks the Twinbox ownership marker,
   discovers the existing Traefik network, entrypoint and certificate resolver,
   validates configuration with the pinned image, and checks public HTTPS.
3. Open **Configure Gatus notifications**, enable Telegram, ntfy and/or Pushover,
   enter the corresponding credentials, then save the settings.
4. Select a channel and click **Testmelding sturen** to test the saved settings
   from the bastion. Each channel is tested separately. No notification account
   is created automatically.

Empty secret fields retain their saved values. Disabling a channel stops its
alerts without deleting the credentials. The wizard shows which credential fields
are configured, never their contents. Use an external ntfy HTTPS server: using
`ntfy.<public-zone>` in this cluster prevents delivery during some cluster outages.

Credentials are stored through the existing cluster secret store in the
`gatus-notifications` item. The bastion keeps a private `notifications.json` and
private rendered configuration; directory permissions are `0700`, files `0600`.
Do not publish these files, logs or backups. Gatus has no Docker socket or cluster
credentials. Its HTTP port is available only on the discovered Docker network.

## Automatic monitors

The worker reads catalog `dashy.items` and cluster-scoped step state without
depending on Portal installation. Successful installs add monitors, successful
uninstalls remove them, and temporary pending/running/failed reinstall states
retain previously installed monitors. Multiple clusters sharing one bastion are
rendered together, with notification overrides per endpoint group.

An optional catalog item can specify:

```yaml
monitoring:
  path: /health
  status_codes: [200]
  body_contains: healthy
```

Without explicit metadata, a check verifies public ingress reachability, accepting
HTTP 200 or standard login redirects without following the redirect. This is not
proof that an application behind a login works. Hostnames, URLs, errors and
conditions are hidden in public results using Gatus' endpoint privacy settings.

The defaults are a 60-second interval, 10-second timeout, three consecutive
failures before alerting, two consecutive successes before a recovery message,
and a minimum reminder interval of 60 minutes. SQLite persists history in `data/`.

The Management VM check discovers its NetBird address from the existing host
client, falling back to configured management addresses. For an explicit reachable
health URL set `GATUS_MANAGEMENT_HEALTH_URL` in the Management VM environment, or
`MANAGEMENT_HEALTH_URL` in its existing bastion secret. No IP ranges, routes or
public management ports are created. Missing discovery is reported as incomplete
coverage; a discovered but inaccessible endpoint is shown as down.

The worker reconciles after completed installation/configuration/removal jobs and
every five minutes while idle. A reconciliation failure produces a wizard warning
on **Install Gatus Status**, retains the last successful timestamp, and is retried.
It does not undo a successful app installation.

## Updates and recovery

The Gatus version is pinned in `config/pinned-defaults.sh`. Runtime updates must
follow the normal Twinbox sequence: commit/push `main`, wait for **Publish Docker
Images**, update the Management VM's `TWINBOX_IMAGE_TAG`, then pull and recreate its
Compose services. Run the Gatus install step again to reconcile the bastion.

Each changed deployment is validated with the exact image in a network-isolated
temporary container before activation. Updates are serialized by a bastion lock.
Configuration and an online SQLite backup are kept in `backups/<timestamp>/`.
Failed activation restores the previous routing, configuration and database and
recreates the previous service when one existed. No-op reconciliation does not
restart the service. Backups contain credentials; protect them and remove older
copies according to the operator's retention policy.

For manual recovery, stop Gatus, restore the chosen Compose/configuration files
and `gatus.db` backup, remove stale SQLite `-wal`/`-shm` sidecars, restore the matching
NetBird Compose file if routing changed, then start both projects with
`docker compose up -d`. Do not remove the data directory or use `down --volumes`.

The status hostname is explicitly excluded from NetBird TCP passthrough and
handled by an exact local HTTPS router. Bootstrap reads `hosts.json` to preserve
that exclusion when the bastion is configured again. Do not add an HTTP wildcard
router or route the status page through Kubernetes.
