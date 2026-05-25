# Authentik

Authentik is Twinbox's identity provider. It runs in the Kubernetes cluster and
serves OIDC, OAuth2, and forwardAuth flows for the portal, management consoles,
NetBird, and user applications.

## NetBird Login Flow

When NetBird ingress is selected, NetBird itself runs on the Hetzner bastion at:

```text
https://netbird.<public-zone>
```

Authentik remains an in-cluster application exposed through NetBird Reverse
Proxy at:

```text
https://authentik.<public-zone>
```

A healthy NetBird dashboard login follows this browser path:

1. Browser opens `https://netbird.<public-zone>`.
2. Bastion Traefik terminates TLS for the exact NetBird hostname.
3. NetBird redirects the browser to `https://authentik.<public-zone>/application/o/authorize/?...`.
4. Bastion Traefik must not terminate Authentik as HTTP. It should match the TCP
   passthrough router and forward the original TLS stream to NetBird Reverse
   Proxy.
5. NetBird Reverse Proxy terminates the Authentik TLS connection, routes through
   the NetBird network to the in-cluster Traefik `webnetbird` entrypoint, and
   reaches Authentik.
6. Authentik authenticates the user and redirects back to
   `https://netbird.<public-zone>/oauth2/callback`.
7. NetBird exchanges the code and the dashboard loads authenticated API data.

## HTTP/2 Coalescing Failure Mode

The NetBird bastion must prevent the browser from reusing the NetBird TLS
connection for Authentik. Browsers are allowed to coalesce HTTP/2 requests across
origins when DNS and certificate validation make it safe. If bastion Traefik
serves a wildcard certificate for `netbird.<public-zone>`, that same connection
is also valid for `authentik.<public-zone>`.

That is the broken shape:

```text
browser -> bastion Traefik TLS for netbird.<zone>
browser -> reuses same HTTP/2 connection for authentik.<zone>
bastion Traefik sees an HTTP Host authentik.<zone>
no intended HTTP router exists
Traefik returns 404 page not found, router "-"
```

The fix is to make `netbird.<public-zone>` an exception to the wildcard model:

- Bastion Traefik serves an exact certificate for `netbird.<public-zone>` only.
- Bastion Traefik does not load a wildcard `*.public-zone` certificate.
- Bastion Traefik does not define an HTTP wildcard router for app hostnames.
- The proxy container keeps the TCP passthrough router for every non-NetBird SNI.
- NetBird Reverse Proxy owns certificates and routing for `authentik.<zone>` and
  the other app hostnames.

## Verification

From the bastion, the NetBird certificate must be exact:

```bash
openssl s_client -connect 127.0.0.1:443 -servername netbird.<public-zone> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

Expected:

```text
DNS:netbird.<public-zone>
```

Unexpected and broken for NetBird login:

```text
DNS:*.public-zone
```

The Authentik authorize endpoint should redirect into the login flow:

```bash
curl -sS -D - -o /dev/null \
  --get \
  --data-urlencode "client_id=<netbird-client-id>" \
  --data-urlencode "code_challenge=<pkce-challenge>" \
  --data-urlencode "code_challenge_method=S256" \
  --data-urlencode "redirect_uri=https://netbird.<public-zone>/oauth2/callback" \
  --data-urlencode "response_type=code" \
  --data-urlencode "scope=openid profile email" \
  --data-urlencode "state=<random-state>" \
  "https://authentik.<public-zone>/application/o/authorize/"
```

Expected:

```text
HTTP/2 302
Location: /if/flow/default-authentication-flow/...
```

The browser is the final authority for this bug class. A fresh `curl` request
usually opens a new TLS connection and does not reproduce HTTP/2 connection
coalescing from `netbird.<public-zone>` to `authentik.<public-zone>`.

## Expected Logs

Healthy NetBird login in bastion Traefik logs:

```text
GET /oauth2/auth...              200 netbird-backend@docker
GET /oauth2/auth/<id>...         302 netbird-backend@docker
GET /oauth2/callback?...         303 netbird-backend@docker
POST /oauth2/token               200 netbird-backend@docker
GET /api/users/current           200 netbird-backend@docker
```

Broken coalesced login:

```text
GET /application/o/authorize?... 404 19 "-" "-"
```

Broken attempts to fix coalescing with a bastion HTTP router to NetBird Reverse
Proxy can show:

```text
authentik-cluster@docker "https://<proxy-ip>:8443" 502
read tcp ...-><proxy-ip>:8443: read: connection reset by peer
```

Do not use that pattern. The durable fix is certificate separation plus TCP
passthrough.
