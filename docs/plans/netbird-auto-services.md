# Plan: NetBird services auto-aanmaken bij installatie

## Huidige situatie (manual)

1. **`provision-netbird-bastion`** (step 1) — Maakt Hetzner VPS, bootstrap NetBird server, DNS records voor `netbird.<zone>` + `proxy.<zone>`
2. **`configure-netbird-ingress`** (later step) — Groups, routes, en **alle services tegelijk** via `infra/opentofu/netbird-proxy-services/` (Terraform)
3. **Wizard flow** (`question-flow.js:436-440`) — User optional `proxy_services_json` als JSON array
4. **Geen per-app NetBird integratie** — elke `install-*` stap maakt alleen Traefik IngressRoutes

## Doel (auto)

Elke `install-*` stap die een app exposeert via Traefik kan **during installatie** een NetBird service aanmaken. `configure-netbird-ingress` wordt simpeler: enkel groups, routes, setup keys.

## DNS-shape (greenfield)

Voor een nieuwe cluster zet provisioning dit model neer:

- `netbird.<zone>` → bastion IP voor NetBird management UI/API
- `*.<zone>` → bastion IP voor alle app services
- **Geen apart `proxy.<zone>` record**
- **Geen apex/root A record** tenzij je bewust `bierineenweek.nl` zelf wilt laten lopen

## Veranderingen

### 1. `scripts/manager/ensure-netbird-service.sh` (NEW)

Helper script dat de NetBird Management API aanroept om een reverse proxy service te maken. **Leest credentials centraal** uit bekende secrets/state — apps hoeven geen token, URL of Traefik info door te geven.

Per app volstaat: `service name`, `full service domain`, `optional path`.

```bash
ensure-netbird-service.sh \
  --service-name <name> \
  --service-domain <domain> \
  [--service-path /]
```

Helper vindt zelf:
- NetBird token → `netbird-bastion-<cluster>.json` (`NETBIRD_SETUP_TOKEN`)
- Management URL → `NETBIRD_URL`
- Proxy domain → `NETBIRD_PROXY_DOMAIN`
- Traefik resource → `netbird-network-<cluster>.json` (`TRAEFIK_RESOURCE_ID`, `TRAEFIK_RESOURCE_ADDRESS`)

API calls:
- `GET /api/reverse-proxy/clusters` → proxy cluster vinden
- `GET /api/reverse-proxy/services?domain=<domain>&name=<name>` → check of bestaat
- `POST` / `PUT` → aanmaken/updaten met payload:
  - `pass_host_header=true`, `rewrite_redirects=true`, `auth disabled`
  - Target: Traefik resource, port 8082, protocol http

### 2. `categories/talos-cluster/steps/provision-netbird-bastion/run.sh` (line 234)

```bash
# Before:
netbird_proxy_domain="proxy.${public_zone_name}"
# After:
netbird_proxy_domain="${public_zone_name}"
```

Cascadeert naar:
- DNS records: `bierineenweek.nl` (A) in plaats van `proxy.bierineenweek.nl`
- `proxy.env` patching (line 466): `NB_PROXY_DOMAIN='bierineenweek.nl'`

### 3. Install steps

Elke app install step die een `webnetbird` IngressRoute maakt, roept de helper aan:

```bash
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "$app_slug" \
  --service-domain "$app_hostname" \
  [--service-path /]
```

**Apps die moeten worden bijgewerkt** (allemaal die in interne traefik staan):
- `install-grafana` (grafana.example.com)
- `install-prometheus` (prometheus.example.com)
- `install-headlamp` (headlamp.example.com)
- `install-ntfy` (ntfy.example.com)
- `install-pgadmin4` (pgadmin.example.com)
- `install-twinbox-portal` (portal.example.com)
- `install-authentik-idp` (authentik.example.com)
- `install-argocd` (argocd.example.com)
- `longhorn` (longhorn.example.com)
- `proxmox` (proxmox.example.com)
- `seaweedfs` (app.seaweedfs.example.com)
- `seaweedfs-admin` (admin.seaweedfs.example.com)
- `twinboxwizard` (twinboxwizard.example.com)

### 4. `configure-netbird-ingress/run.sh`

- **Verwijder lijnen 600-613** (Terraform services block)
- **Verwijder ook** `PROXY_SERVICE_IDS` uit `netbird-network-<cluster>.json` (niet meer nodig)
- **Vervang** by alleen de basis NetBird network resources: groups, routes, setup keys, Traefik resource
- **Authentik service** → aangemaakt door `install-authentik-idp` (niet meer door `configure-netbird-ingress`)

### 5. Wizard flow (`question-flow.js:436-440`)

Bijwerken van help text: "These services will be created automatically during app installation. This form is for initial setup."

### 6. Documentatie

- `docs/netbird.md` — proxy domain references updaten, auto-creation uitleggen
- `AGENTS.md` — management URL references updaten

## Files

| File | Action |
|------|--------|
| `scripts/manager/ensure-netbird-service.sh` | **NEW** |
| `categories/talos-cluster/steps/provision-netbird-bastion/run.sh` | Edit line 234 |
| `categories/talos-cluster/steps/configure-netbird-ingress/run.sh` | Lines 600-613: replace services block |
| `categories/talos-cluster/steps/install-*/run.sh` | Add optional NetBird service call (alle apps) |
| `manager-web/src/question-flow.js` | Update help text (line 440) |
| `docs/netbird.md` | Update proxy domain references |
| `AGENTS.md` | Update management URLs |

## Volgorde van uitvoering

1. Schrijf `ensure-netbird-service.sh`
2. Update `provision-netbird-bastion` (proxy domain)
3. Refactor `configure-netbird-ingress`
4. Update alle install steps
5. Update wizard flow
6. Update docs

## Notes

- NetBird Terraform provider (`netbird_reverse_proxy_service`) doet hetzelfde via de API — onze helper script doet exact hetzelfde (payload, targets, auth flags)
- De helper is idempotent: create of update op basis van name+domain
- `traefik-resource-id` staat in `netbird-network-<cluster>.json` na `configure-netbird-ingress`
- `proxy.<zone>` → `<zone>` betekent alle services hun domain updaten naar `example.com/app` (geen `proxy.<zone>/app` meer)
- De helper leest alle NetBird config uit centrale secrets — apps hoeven niets door te geven
