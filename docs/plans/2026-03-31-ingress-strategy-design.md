# Ingress Strategy

## Overview

Twinbox supports four ingress strategies for exposing cluster applications. The user chooses during the web wizard setup.

| | Wiredoor | Cloudflare Tunnel | MetalLB + Port Forwarding | Tailscale |
|---|---|---|---|---|
| Open source | ✅ Apache-2.0 | ❌ Proprietary | ✅ | ❌ (client) / ✅ (Headscale) |
| Privacy | ✅ No third party | ❌ Cloudflare sees traffic | ✅ Full control | ❌ Tailscale sees metadata |
| Upload limit | None | 100MB (free) | None | None |
| External server required | Yes (€3/mo) | No | No | No (Tailscale SaaS) |
| DDoS protection | Hetzner basic | Cloudflare full | None | Tailscale ACL |
| DNS provider | Any | Cloudflare only | Any | Tailscale MagicDNS |
| Port forwarding required | No | No | Yes (80/443) | No |
| Protocol support | HTTP, HTTPS, TCP, WS | HTTP, HTTPS only | HTTP, HTTPS, TCP, UDP | HTTP, HTTPS, TCP, UDP |
| Access control | Wiredoor OAuth | Cloudflare WAF | Firewall rules | Tailscale ACL |
| Best for | Privacy + control | Convenience | Full control, zero cost | Remote access, zero config |

## Architecture

### 1. Wiredoor

```
Internet → Cloudflare DNS (lookup only) → Wiredoor VM (Hetzner)
                                              │
                                              │ WireGuard tunnel
                                              ▼
                                         Twinbox cluster
                                              │
                                              ▼
                                         Traefik → App
```

- Wiredoor server runs on a Hetzner VM (or any publicly reachable host)
- WireGuard tunnel connects the Twinbox cluster to the Wiredoor server
- Let's Encrypt certificates are managed by Wiredoor on the server
- Cloudflare is used for DNS only (grey cloud, no proxy)
- No upload limits, no traffic inspection by third parties

**Traefik entryPoint**: `webwiredoor` (port 8081)

### 2. Cloudflare Tunnel

```
Internet → Cloudflare Edge (DDoS, WAF, TLS termination)
                │
                │ Cloudflare Tunnel (cloudflared)
                ▼
           Twinbox cluster
                │
                ▼
           Traefik → App
```

- `cloudflared` daemon runs inside the cluster
- Tunnel connects outbound to Cloudflare's edge
- No open ports required on the user's network
- No external VM needed
- Cloudflare sees all HTTP/HTTPS traffic
- 100MB upload limit on free plan

**Traefik entryPoint**: `websecure` (port 443)

### 3. MetalLB + Port Forwarding

```
Internet → Router (port forward 80/443) → MetalLB IP → Traefik → App
                          │
                          │ Let's Encrypt (HTTP-01)
                          ▼
                     Traefik cert resolver
```

- MetalLB assigns a real IP on the local network to Traefik
- User configures port forwarding on their router (80 → Traefik, 443 → Traefik)
- Traefik manages Let's Encrypt certificates directly via HTTP-01 challenge
- Dynamic DNS updates the public DNS record when the home IP changes
- Full control, zero external dependencies, no third party sees traffic
- Requires port forwarding and a DynDNS client

**Traefik entryPoint**: `websecure` (port 443) with Let's Encrypt certResolver

### 4. Tailscale

```
Tailscale devices (laptop, phone)
                │
                │ Tailscale tailnet (WireGuard mesh)
                ▼
           Twinbox cluster (tailscale DaemonSet)
                │
                ▼
           Traefik → App
```

- `tailscale` daemon runs as a DaemonSet in the cluster
- Each app gets a Tailscale Funnel or HTTPS endpoint on the tailnet
- Users connect by enabling Tailscale on their device
- No port forwarding, no external VM, no public DNS needed
- Access control via Tailscale ACLs (device identity, user identity)
- Tailscale's coordination servers see metadata (who connects to what), but traffic is end-to-end encrypted via WireGuard
- Can be self-hosted with Headscale for full control

**Traefik entryPoint**: `webtailscale` (internal, via Tailscale IP)

## Wizard Choice

During the **"Configure Ingress"** step in the web wizard, the user selects their ingress strategy:

```
┌─────────────────────────────────────────────────────────────┐
│  How should your cluster be accessible?                     │
│                                                             │
│  ○ Wiredoor (recommended)                                   │
│    Self-hosted tunnel, full privacy, no upload limits       │
│    Requires a small external server (€3/mo Hetzner)         │
│                                                             │
│  ○ Cloudflare Tunnel                                        │
│    No external server, built-in DDoS protection             │
│    Requires Cloudflare account, 100MB upload limit          │
│                                                             │
│  ○ MetalLB + Port Forwarding                                │
│    Direct access, zero cost, full control                   │
│    Requires port forwarding on your router                  │
│                                                             │
│  ○ Tailscale                                                │
│    Zero config, access from anywhere via tailnet            │
│    Requires Tailscale on all client devices                 │
└─────────────────────────────────────────────────────────────┘
```

### Wiredoor Path

If Wiredoor is selected, the wizard collects:

1. **Wiredoor Server URL** — `https://wg.example.com`
2. **Wiredoor Admin Token** — API token from the Wiredoor server
3. **Wiredoor Node Name** — defaults to cluster slug

The wizard then:
- Seeds the Wiredoor gateway credentials into OpenBao at `twinbox/global/wiredoor-gateway`
- Deploys the `wiredoor-gateway` Argo CD application
- Configures each app's IngressRoute to use the `webwiredoor` entryPoint only

### Cloudflare Tunnel Path

If Cloudflare Tunnel is selected, the wizard collects:

1. **Cloudflare API Token** — with Tunnel permissions
2. **Cloudflare Account ID**
3. **Cloudflare Zone ID** — the domain zone

The wizard then:
- Creates a Cloudflare Tunnel via the API
- Deploys `cloudflared` as a DaemonSet in the cluster
- Configures DNS CNAME records pointing to the tunnel
- Configures each app's IngressRoute to use the `websecure` entryPoint only

### MetalLB + Port Forwarding Path

If MetalLB + Port Forwarding is selected, the wizard collects:

1. **Public IP or DynDNS hostname** — the external address of the user's network
2. **MetalLB IP range** — the local IP range MetalLB can assign (e.g. `192.168.1.200-192.168.1.210`)
3. **DynDNS provider** — optional, for automatic IP updates (Cloudflare API, DuckDNS, etc.)

The wizard then:
- Deploys MetalLB with the specified IP pool
- Assigns an IP to Traefik's LoadBalancer service
- Configures Traefik with Let's Encrypt certResolver (HTTP-01)
- Displays port forwarding instructions (forward 80 and 443 to the MetalLB IP)
- Optionally configures a DynDNS update script

### Tailscale Path

If Tailscale is selected, the wizard collects:

1. **Tailscale Auth Key** — pre-authorized key from the Tailscale admin console
2. **Tailscale ACL tag** — optional, for ACL-based access control (e.g. `tag:twinbox`)
3. **Headscale URL** — optional, if using self-hosted Headscale instead of Tailscale SaaS

The wizard then:
- Seeds the Tailscale auth key into OpenBao at `twinbox/global/tailscale`
- Deploys `tailscale` as a DaemonSet in the cluster
- Configures Tailscale Funnel or HTTPS endpoints for each app
- Configures each app's IngressRoute to use the `webtailscale` entryPoint

## Impact on IngressRoute

Every app's IngressRoute is generated based on the chosen strategy:

### Wiredoor mode

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp
  namespace: kube-system
spec:
  entryPoints:
    - webwiredoor
  routes:
    - kind: Rule
      match: Host(`headlamp.example.com`)
      services:
        - kind: Service
          name: my-headlamp
          port: 80
```

### Cloudflare Tunnel mode

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp
  namespace: kube-system
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`headlamp.example.com`)
      services:
        - kind: Service
          name: my-headlamp
          port: 80
  tls: {}
```

### MetalLB + Port Forwarding mode

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp
  namespace: kube-system
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`headlamp.example.com`)
      services:
        - kind: Service
          name: my-headlamp
          port: 80
  tls:
    certResolver: letsencrypt
```

Note the `certResolver: letsencrypt` — Traefik manages certificates directly.

### Tailscale mode

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp
  namespace: kube-system
spec:
  entryPoints:
    - webtailscale
  routes:
    - kind: Rule
      match: Host(`headlamp.example.com`)
      services:
        - kind: Service
          name: my-headlamp
          port: 80
  tls: {}
```

Tailscale provides its own TLS certificates for tailnet endpoints. Traefik can use HTTP internally.

## Secret Contracts

### Wiredoor

OpenBao path: `twinbox/global/wiredoor-gateway`

| Property | Description |
|----------|-------------|
| `WIREDOOR_URL` | Wiredoor server URL |
| `TOKEN` | Wiredoor API token |

### Cloudflare Tunnel

OpenBao path: `twinbox/global/cloudflare-tunnel`

| Property | Description |
|----------|-------------|
| `CF_API_TOKEN` | Cloudflare API token with Tunnel permissions |
| `CF_ACCOUNT_ID` | Cloudflare account ID |
| `CF_ZONE_ID` | Cloudflare zone ID |
| `CF_TUNNEL_ID` | Created tunnel ID |
| `CF_TUNNEL_TOKEN` | Created tunnel token |

### MetalLB + Port Forwarding

OpenBao path: `twinbox/global/metallb`

| Property | Description |
|----------|-------------|
| `PUBLIC_HOST` | Public hostname or DynDNS hostname |
| `METALLB_IP` | Assigned MetalLB IP for Traefik |
| `DYNDNS_PROVIDER` | DynDNS provider (optional) |
| `DYNDNS_TOKEN` | DynDNS API token (optional) |

### Tailscale

OpenBao path: `twinbox/global/tailscale`

| Property | Description |
|----------|-------------|
| `TS_AUTHKEY` | Tailscale pre-authorized auth key |
| `TS_TAG` | Tailscale ACL tag (optional) |
| `TS_HEADSCALE_URL` | Headscale URL (optional, for self-hosted) |
| `TS_HEADSCALE_KEY` | Headscale API key (optional) |

## Traefik entryPoints

Each strategy uses a dedicated entryPoint:

| Strategy | entryPoint | Port | TLS |
|----------|-----------|------|-----|
| Wiredoor | `webwiredoor` | 8081 | Managed by Wiredoor |
| Cloudflare Tunnel | `websecure` | 443 | Terminated by Cloudflare |
| MetalLB + Port Forwarding | `websecure` | 443 | Let's Encrypt via Traefik |
| Tailscale | `webtailscale` | 8090 | Tailscale certificates |

## Implementation Plan

### Phase 1: Infrastructure decision

- [ ] Add `INGRESS_STRATEGY` to `.env` (values: `wiredoor`, `cloudflare-tunnel`, `metallb`, `tailscale`)
- [ ] Add ingress strategy selection to the web wizard
- [ ] Store choice in cluster state JSON

### Phase 2: Wiredoor path (already partially implemented)

- [ ] The `wiredoor-gateway` Argo CD application already exists
- [ ] The `wiredoor-gateway-secret` ExternalSecret already exists
- [ ] Wire up the wizard to seed Wiredoor credentials into OpenBao
- [ ] Ensure all IngressRoutes use `webwiredoor` when Wiredoor is selected

### Phase 3: Cloudflare Tunnel path (new)

- [ ] Create `gitops/apps/cloudflare-tunnel.yaml` — Argo CD Application for cloudflared Helm chart
- [ ] Create `gitops/values/cloudflare-tunnel.yaml` — Helm values with token from ExternalSecret
- [ ] Create `gitops/platform/cloudflare-tunnel/externalsecret.yaml` — pulls tunnel token from OpenBao
- [ ] Create `scripts/manager/create-cloudflare-tunnel.sh` — creates tunnel via Cloudflare API
- [ ] Wire up the wizard to call the tunnel creation script

### Phase 4: MetalLB + Port Forwarding path (new)

- [ ] Create `gitops/apps/metallb.yaml` — Argo CD Application for MetalLB Helm chart
- [ ] Create `gitops/values/metallb.yaml` — IP pool configuration
- [ ] Update Traefik service to use `LoadBalancer` type when MetalLB is selected
- [ ] Configure Traefik certResolver for Let's Encrypt (HTTP-01)
- [ ] Create `scripts/manager/setup-metallb.sh` — deploys MetalLB and assigns IP
- [ ] Create `scripts/manager/setup-dyndns.sh` — optional DynDNS update script
- [ ] Wire up the wizard to collect and seed MetalLB/DynDNS credentials

### Phase 5: Tailscale path (new)

- [ ] Create `gitops/apps/tailscale.yaml` — Argo CD Application for Tailscale Helm chart
- [ ] Create `gitops/values/tailscale.yaml` — auth key, ACL tag, Headscale config
- [ ] Create `gitops/platform/tailscale/externalsecret.yaml` — pulls auth key from OpenBao
- [ ] Add `webtailscale` entryPoint to Traefik configuration
- [ ] Create `scripts/manager/setup-tailscale.sh` — configures Tailscale ACL and Funnel
- [ ] Wire up the wizard to collect and seed Tailscale credentials

### Phase 6: Conditional IngressRoute generation

- [ ] Update `gitops/platform/*/ingressroute.yaml` files to be conditional based on ingress strategy
- [ ] Use Kustomize or Argo CD application-set to deploy the right entryPoint
- [ ] Alternatively: generate both IngressRoutes but only wire up the relevant entryPoint in Traefik values

### Phase 7: Traefik configuration

- [ ] When Wiredoor: enable `webwiredoor` entryPoint only
- [ ] When Cloudflare Tunnel: enable `websecure` entryPoint only
- [ ] When MetalLB: enable `websecure` with Let's Encrypt certResolver
- [ ] When Tailscale: enable `webtailscale` entryPoint
- [ ] All entryPoints can coexist; only the active one is used per cluster
