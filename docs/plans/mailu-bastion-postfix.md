# Twinbox Mail: Mailu on Kubernetes with Bastion Postfix Edge

Twinbox Mail v1 installs Mailu on the Kubernetes cluster and uses the existing
NetBird bastion as the public SMTP edge. The first version deliberately supports
one mail domain, the cluster `public_zone_name`, with `mail.<public-zone>` as
the public mail hostname.

## Runtime Shape

- Mailu runs in namespace `mailu` through the official Mailu Helm chart.
- The chart is pinned to `mailu` chart `2.7.1` and Mailu app version
  `2024.06.51`.
- Mailu UI traffic is exposed through Traefik at `https://mail.<zone>`.
- Mailu SMTP/IMAP/submission ports stay internal to Kubernetes.
- The NetBird bastion runs Postfix and exposes only public inbound SMTP on
  `25/tcp`.
- Mailu sends outbound mail to the in-cluster
  `mailu-relay-egress.netbird.svc.cluster.local:2525` service.
- The `mailu-relay-egress` pod runs a dedicated NetBird client and HAProxy TCP
  forwarder to the bastion's existing NetBird overlay address on port `2525`.
- The installer verifies the existing `netbird-client` peer on the bastion
  before publishing DNS records.

## GitOps Resources

- `gitops/optional-apps/mailu.yaml` is the opt-in ApplicationSet used by the app
  installer.
- `gitops/apps/mailu.yaml` is a direct/manual Application manifest for
  consistency with existing app patterns. The installer uses
  `gitops/optional-apps/mailu.yaml`, which is the canonical path.
- `gitops/values/mailu.yaml` contains Mailu defaults, disables host ports and
  chart ingress, enables Roundcube webmail, and sets explicit resource requests
  and limits.
- `gitops/platform-apps/mailu/` contains the Mailu namespace,
  Mailu ExternalSecrets, Traefik IngressRoutes, and explicitly namespaced
  Mailu relay egress resources in the privileged `netbird` namespace.

The installer annotates the local Argo CD cluster secret before enabling the
optional app. The ApplicationSet reads these annotations:

- `twinbox.io/mailu-relay-host`
- `twinbox.io/mailu-admin-localpart`
- `twinbox.io/mailu-storage-size`
- `twinbox.io/mailu-dmarc-rua-localpart`

`twinbox.io/mailu-relay-host` patches the relay egress HAProxy target. Mailu
itself always relays to the in-cluster `mailu-relay-egress` service.

## Secrets

OpenBao paths:

- `twinbox/global/mailu-runtime`
  - `secret-key`
  - `api-token`
  - `initial-admin-password`
- `twinbox/global/mailu-relay`
  - `relay-username`
  - `relay-password`
- `twinbox/global/mailu-dns`
  - `mail_domain`
  - `mail_hostname`
  - `dkim_selector`
  - `dkim_txt_name`
  - `dkim_txt_value`
  - `spf_txt_name`
  - `spf_txt_value`
  - `dmarc_txt_name`
  - `dmarc_txt_value`
  - `mx_name`
  - `mx_value`
- `twinbox/global/netbird-mailu-relay-egress`
  - `NB_SETUP_KEY`
  - `NB_MANAGEMENT_URL`
  - `NB_HOSTNAME`

Bootstrap JSON files may be written temporarily under
`/opt/twinbox/bootstrap/secrets/global/` and are removed by the installer.

## DNS

The installer creates a `DNSEndpoint` named `mailu-mail-dns` in the
`external-dns` namespace after Mailu has generated DKIM material.

Records:

- `A mail.<zone> -> <bastion IPv4>`
- `MX <zone> -> 10 mail.<zone>.`
- `TXT <zone> -> v=spf1 mx -all`
- `TXT _dmarc.<zone> -> v=DMARC1; p=<policy>; rua=mailto:<rua>@<zone>; adkim=s; aspf=s`
- `TXT <Mailu selector>._domainkey.<zone> -> <Mailu exported DKIM value>`

`external-dns` is configured to manage MX records. PTR/rDNS is not automated and
must be configured at the IP owner as:

```text
<bastion IPv4> -> mail.<zone>
```

## Bastion Postfix

`scripts/manager/configure-bastion-mailu-postfix.sh` installs and configures
Postfix on the NetBird bastion over SSH.

It writes Twinbox-owned files under `/etc/postfix/twinbox-mailu/`, sets relay
domains and transport maps for the Mailu domain, enables a SASL-protected relay
listener on the bastion NetBird overlay address on port `2525`, runs
`postfix check`, and restarts Postfix only after validation.

Open relay guardrails:

- `mynetworks` is limited to localhost.
- public inbound SMTP accepts mail only for the configured Mailu domain.
- outbound relay on `2525` requires SASL authentication over TLS.
- `2525` is bound to the NetBird/private address, not `0.0.0.0`.
- the Hetzner firewall only opens `25/tcp`; it does not open `2525/tcp`.
- relay credentials are passed through a root-only temporary file, never as
  process arguments.

NetBird guardrails:

- A dedicated `mailu-relay-egress` NetBird group and setup key are created by
  the NetBird network OpenTofu module.
- NetBird policy permits the Mailu egress peer to reach the bastion proxy peer
  on TCP `2525`.
- The setup key is synced to OpenBao and exposed to Kubernetes with an
  ExternalSecret.

## Installer Flow

`categories/apps/steps/install-mailu/run.sh`:

1. Derives `public_zone_name`, `mail_domain`, and `mail_hostname`.
2. Loads the NetBird bastion secret and SSH key.
3. Discovers or validates the bastion NetBird overlay IP for the Mailu relay.
4. Generates or reuses Mailu runtime and relay secrets.
5. Syncs secrets to OpenBao.
6. Annotates the Argo CD cluster secret with Mailu render values.
7. Applies the Mailu Argo CD application.
8. Waits for ExternalSecrets, deployments, and statefulsets.
9. Discovers the `mailu-front` ClusterIP.
10. Configures bastion Postfix.
11. Verifies the bastion NetBird route and TCP connectivity to
    `mailu-front:25`.
12. Verifies the in-cluster relay service and the egress pod's NetBird path to
    the bastion relay on `2525`.
13. Exports Mailu DNS records and generates DKIM only when no existing DKIM
    record is present.
14. Creates `DNSEndpoint` records.
15. Writes step outputs, including the relay host and PTR action required.

DNS is intentionally created after the NetBird route, relay egress, and Postfix
checks. A failed install should not publish MX records that point production
mail at an unverified edge.

## Verification

Small useful checks:

```bash
bash -n categories/apps/steps/install-mailu/run.sh
bash -n scripts/manager/configure-bastion-mailu-postfix.sh
python3 -m pytest -q tests/test_mailu_gitops.py
helm template mailu mailu/mailu --version 2.7.1 --namespace mailu \
  -f gitops/values/mailu.yaml \
  --set domain=example.com \
  --set hostnames[0]=mail.example.com \
  --set initialAccount.domain=example.com \
  --set externalRelay.host='[mailu-relay-egress.netbird.svc.cluster.local]:2525'
```

Live production validation must also include public DNS checks, PTR/rDNS,
Postfix `postfix check` on the bastion, and an external open-relay test.
