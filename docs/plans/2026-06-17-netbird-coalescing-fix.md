# NetBird Coalescing Fix Without Extra IP

## Diagnosis

The HTTP/2 coalescing diagnosis is real. A browser can first open an HTTP/2
connection to `authentik.<zone>` through the wildcard app certificate and then
reuse that same connection for `netbird.<zone>` because both names resolve to
the same public bastion IP and the wildcard certificate is valid for
`netbird.<zone>`.

That reused request reaches the bastion Traefik TCP passthrough router with the
original SNI from the wildcard connection, not with `netbird.<zone>`. Traefik
therefore forwards the connection to `netbird-proxy`, which is correct for app
domains but wrong for the NetBird dashboard/API unless NetBird Reverse Proxy
has an explicit service for `netbird.<zone>`.

This is the HTTP/2 connection reuse shape described by RFC 9113 section 9.1.1:
an existing TLS connection can be reused for another origin when DNS, TLS
certificate validity, and authority checks allow it.

## Why NetBird Is The Exception

Most Twinbox apps are backends behind NetBird Reverse Proxy, so the
coalesced-path destination is exactly where they are meant to land.

NetBird itself is different because its control plane and reverse-proxy
controller run on the bastion. Direct visits to `netbird.<zone>` are handled by
the bastion Traefik route and exact NetBird certificate. Coalesced visits enter
through the app-domain wildcard path and therefore land at `netbird-proxy`.

Moving NetBird into Kubernetes would add bootstrap and recovery coupling and
does not by itself remove same-IP, wildcard-certificate HTTP/2 coalescing. The
bug is at the edge-routing boundary, not in the location of the NetBird server.

## Rejected Options

### Extra Bastion IP

Putting `netbird.<zone>` on a separate public IP would prevent browser
coalescing across the two origins, but it adds another public IP to provision,
route, secure, and pay for. We do not want this.

### Separate Domain

Moving NetBird to a separate parent domain would also prevent coalescing, but it
changes public identity and would require NetBird client/server reconfiguration.

### Mesh Loop

Routing coalesced `netbird.<zone>` requests through NetBird Reverse Proxy into
Kubernetes and then back to the bastion would work, but the path is ugly:

```
browser -> bastion Traefik passthrough -> netbird-proxy
  -> NetBird mesh -> Kubernetes Traefik -> bastion Traefik -> NetBird server
```

That adds latency, more moving parts, and a recovery dependency for a control
plane that should stay independently reachable.

## Chosen Fix

When `netbird-proxy` accidentally sees `netbird.<zone>`, make it route directly
to the bastion Traefik over the local Docker network.

This needs two pieces:

1. Give the bastion Traefik container a Docker network alias named
   `netbird.<zone>` on the existing NetBird Docker network.
2. Create a NetBird Reverse Proxy service for `netbird.<zone>` with a
   `cluster` target, `direct_upstream=true`, `host=netbird.<zone>`,
   `target_id=netbird.<zone>`, `port=443`, `protocol=https`, and
   `skip_tls_verify=false`.

The resulting coalesced flow is:

```
browser -> bastion Traefik TCP passthrough -> netbird-proxy
  -> Docker DNS netbird.<zone> -> local bastion Traefik:443
  -> exact NetBird Traefik route -> NetBird dashboard/API
```

Direct, non-coalesced NetBird traffic is unchanged:

```
browser/client -> bastion Traefik:443 with SNI netbird.<zone>
  -> exact NetBird certificate and route -> NetBird dashboard/API
```

## Implementation

- `scripts/manager/ensure-netbird-service.sh` supports optional target
  overrides:
  `--target-type`, `--target-id`, `--target-host`, `--target-port`,
  `--target-protocol`, `--target-direct-upstream`, and
  `--target-skip-tls-verify`.
- `infra/opentofu/netbird/cloud-init/netbird.yaml.tftpl` adds the
  `netbird.<zone>` alias to the Traefik service for new bastions.
- `categories/talos-cluster/steps/configure-netbird-ingress/run.sh` patches the
  alias idempotently on existing bastions and verifies that `netbird-proxy` can
  resolve it.
- The same step creates the special NetBird Reverse Proxy service with
  `direct_upstream=true`, avoiding Kubernetes and avoiding any extra public IP.

## Fallback

Returning `421 Misdirected Request` from the wildcard/app-domain path for
`netbird.<zone>` can be considered as a secondary fallback, but it is not the
primary fix. Clients may retry on a fresh connection after `421`; they are not
required to.

## Verification

- `docker exec netbird-proxy getent hosts netbird.<zone>` resolves to the local
  bastion Traefik container.
- A real HTTP/2 coalescing simulation with SNI `authentik.<zone>` and
  `:authority netbird.<zone>` returns NetBird dashboard/API output instead of
  the NetBird proxy 404.
- Browser flow works after visiting `authentik.<zone>` first and then
  `netbird.<zone>`.
- Direct NetBird access and NetBird clients keep using the existing bastion
  Traefik route and exact certificate.
