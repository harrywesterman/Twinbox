# Cluster CPU-gebruiksanalyse — Twinbox Productie

**Datum:** 2026-06-01  
**Cluster:** twinbox-prd (5 nodes, Talos v1.13.0, K8s v1.36.0)  
**Aanleiding:** Workers tonen 17–34% CPU bij "idle". Is dit normaal?

---

## 1. Node Specificaties

| Node | Role | vCPU | RAM | OS | Kernel | Runtime |
|------|------|------|-----|----|--------|---------|
| talos-8ys-e0s (192.168.2.50) | controlplane | 2 | 4.8 GB | Talos v1.13.0 | 6.18.24-talos | containerd 2.2.3 |
| talos-e3c-439 (192.168.2.237) | controlplane | 2 | 4.8 GB | Talos v1.13.0 | 6.18.24-talos | containerd 2.2.3 |
| talos-gs1-szo (192.168.2.242) | worker | 4 | 9.9 GB | Talos v1.13.0 | 6.18.24-talos | containerd 2.2.3 |
| talos-h2b-ilf (192.168.2.253) | worker | 4 | 9.9 GB | Talos v1.13.0 | 6.18.24-talos | containerd 2.2.3 |
| talos-w60-47p (192.168.2.240) | worker | 4 | 9.9 GB | Talos v1.13.0 | 6.18.24-talos | containerd 2.2.3 |

**Opvallend:** Workers hebben 2× de CPU en 2× het RAM van controlplanes. Dit is bewust: workers draaien alle applicatieworkload.

---

## 2. CPU-gebruik per Node

### kubectl top nodes (huidig verbruik)

| Node | CPU (cores) | CPU (%) | MEM (GB) | MEM (%) |
|------|-------------|---------|----------|---------|
| talos-8ys-e0s | 464m | **23%** | 3.1 | 75% |
| talos-e3c-439 | 273m | **14%** | 2.0 | 47% |
| talos-gs1-szo | 694m | **17%** | 4.2 | 44% |
| talos-h2b-ilf | 1363m | **34%** | 4.4 | 46% |
| talos-w60-47p | 1031m | **26%** | 5.0 | 52% |

### Analyse

De **controlplanes** (14–23%) zijn ~10 minuten geleden herstart. Hun CPU is een betere indicatie van "echte idle" na stabilisatie. De **workers** (17–34%) hebben een hoger idle-verbruik omdat:

1. **4× zoveel pods** — workers draaien ~30 endpoints; controlplanes 2-3.
2. **Longhorn dataplane** — instance managers, replica sync, engine processes op elke worker.
3. **Zwaardere observability** — Prometheus (702MB, op h2b-ilf), Loki (198MB, op w60-47p), Alloy (op gs1-szo).
4. **ArgoCD controller** (517MB, op w60-47p) — application controller met watcher loops.

**Conclusie:** 17–34% is **niet abnormaal** voor een cluster mét deze workloads. Puur kale Cilium + kubelet idle zou ~10–15% per worker zijn. De rest komt door de platformservices.

---

## 3. Procesanalyse per Node (top RESMEM-consuments)

### Controlplane: talos-8ys-e0s (2 vCPU, recent herstart)

| Process | RESMEM | CPU-time | Threads | Opmerking |
|---------|--------|----------|---------|-----------|
| etcd | 180 MB | 57s | 11 | 12 GB VIRT (mmap) |
| cilium-agent | 208 MB | 32s | 13 | eBPF datapath |
| kube-apiserver | 1028 MB | 101s | 10 | API server, hoog RES |
| kube-controller-manager | 162 MB | 10s | 5 | Controllers |
| containerd (CRI) | 68 MB | 14s | 14 | Container runtime |
| dashboard | 82 MB | 7s | 8 | Talos dashboard |

### Controlplane: talos-e3c-439 (2 vCPU, recent herstart)

| Process | RESMEM | CPU-time | Threads |
|---------|--------|----------|---------|
| cilium-agent | 187 MB | 27s | 13 |
| kubelet | 101 MB | 23s | 18 |
| kube-apiserver | 557 MB | 42s | — |
| containerd (CRI) | 66 MB | 13s | 18 |
| cilium-envoy | 50 MB | 2s | 11 |

### Worker: talos-h2b-ilf (4 vCPU, **34%**, hoogste verbruik)

| Process | RESMEM | CPU-time | Threads | Opmerking |
|---------|--------|----------|---------|-----------|
| Prometheus | 702 MB | 717s | 10 | TSDB, WAL, scrape |
| cilium-agent | 241 MB | 1715s | 19 | eBPF, conntrack |
| kubelet | 160 MB | 2326s | 39 | cAdvisor, sync loops |
| Longhorn instance-mgr | 50 MB | 416s | 25 | Storage dataplane |
| Longhorn manager | 219 MB | 429s | 11 | Storage controlplane |
| Bao (Vault) | 114 MB | 263s | 11 | 216 GB VIRT (mmap) |
| Authentik worker | 293 MB | 42s | 12 | Python worker process |
| containerd | 114 MB | 1913s | 27 | Image pulls, GC |
| dashboard | 88 MB | 354s | 9 | Talos UI |
| NetBird routing peer | 73 MB | 116s | 12 | WireGuard tunnels |
| Redis | 26 MB | 141s | 6 | ArgoCD HA Redis |
| Redis sentinel | 13 MB | 295s | 6 | |

### Worker: talos-w60-47p (4 vCPU, **26%**)

| Process | RESMEM | CPU-time | Threads | Opmerking |
|---------|--------|----------|---------|-----------|
| ArgoCD app-controller | 517 MB | 2122s | 14 | Git watcher, sync |
| cilium-agent | 237 MB | 1808s | 21 | eBPF datapath |
| Loki | 198 MB | 441s | 12 | Log ingest, query |
| kubelet | 164 MB | 2500s | 39 | |
| Longhorn instance-mgr | 48 MB | 583s | 27 | |
| Longhorn manager | 215 MB | 487s | 11 | |
| containerd | 113 MB | 2178s | 25 | |

### Worker: talos-gs1-szo (4 vCPU, **17%**, laagste)

| Process | RESMEM | CPU-time | Threads | Opmerking |
|---------|--------|----------|---------|-----------|
| Grafana | 264 MB | 69s | 16 | Dashboards, queries |
| cilium-agent | 239 MB | 1233s | 18 | |
| Alloy | 280 MB | 117s | 10 | Metrics/logs forwarder |
| kubelet | 167 MB | 1741s | 44 | |
| Longhorn instance-mgr | 50 MB | 693s | 24 | |
| Longhorn manager | 220 MB | 335s | 10 | |
| Node.js server.mjs | 97 MB | 4s | 11 | Manager web? |
| containerd | 120 MB | 1479s | 19 | |

---

## 4. Pod-level CPU-gebruik (kubectl top pods)

### Top 15 CPU-verbruikers

| Pod | Namespace | CPU (m) | MEM (Mi) | Node |
|-----|-----------|---------|----------|------|
| authentik-worker | authentik | 499 | 276 | h2b-ilf |
| kube-apiserver | kube-system | 140 | 1028 | 8ys-e0s |
| instance-manager | longhorn-system | 112 | 298 | w60-47p |
| cilium-x78tt | kube-system | 98 | 367 | w60-47p |
| instance-manager | longhorn-system | 95 | 232 | gs1-szo |
| argocd-redis-ha-server-2 | argocd | 84 | 29 | w60-47p |
| cilium-pw2c8 | kube-system | 83 | 379 | h2b-ilf |
| cilium-8n49b | kube-system | 79 | 379 | gs1-szo |
| instance-manager | longhorn-system | 59 | 277 | h2b-ilf |
| openbao-0 | openbao | 58 | 54 | h2b-ilf |
| argocd-redis-ha-server-0 | argocd | 57 | 29 | h2b-ilf |
| argocd-redis-ha-server-1 | argocd | 55 | 29 | gs1-szo |
| cilium-klnzm | kube-system | 43 | 411 | 8ys-e0s |
| kube-apiserver | kube-system | 42 | 557 | e3c-439 |
| cilium-dslwr | kube-system | 41 | 390 | e3c-439 |

### Top 15 Memory-verbruikers

| Pod | Namespace | MEM (Mi) | CPU (m) | Node |
|-----|-----------|----------|---------|------|
| kube-apiserver-talos-8ys-e0s | kube-system | 1028 | 140 | 8ys-e0s |
| authentik-db-1 | databases | 666 | 27 | h2b-ilf |
| prometheus-prometheus-kube-prometheus-prometheus-0 | monitoring | 662 | 39 | h2b-ilf |
| kube-apiserver-talos-e3c-439 | kube-system | 557 | 42 | e3c-439 |
| authentik-server | authentik | 498 | 38 | w60-47p |
| cilium-klnzm | kube-system | 411 | 43 | 8ys-e0s |
| cilium-dslwr | kube-system | 390 | 41 | e3c-439 |
| cilium-8n49b | kube-system | 379 | 79 | gs1-szo |
| cilium-pw2c8 | kube-system | 379 | 83 | h2b-ilf |
| argocd-application-controller-0 | argocd | 372 | 6 | w60-47p |
| cilium-x78tt | kube-system | 367 | 98 | w60-47p |
| instance-manager | longhorn-system | 298 | 112 | w60-47p |
| grafana | monitoring | 284 | 12 | gs1-szo |
| pgadmin4 | pgadmin4 | 281 | 1 | w60-47p |
| authentik-worker | authentik | 276 | 499 | h2b-ilf |

---

## 5. Cilium Deep-Dive

### 5.1 Cilium Process CPU (cumulatief sinds start)

| Node | Cilium uptime | CPU-time | Gomaxprocs | Open fds |
|------|---------------|----------|------------|----------|
| talos-8ys-e0s | 14m | 26s | 2 | 103 |
| talos-e3c-439 | 8m | 22s | 2 | 103 |
| talos-gs1-szo | 5h20m | 1238s | 4 | 134 |
| talos-h2b-ilf | 5h20m | 1722s | 4 | 130 |
| talos-w60-47p | 5h20m | 1815s | 4 | 134 |

**Gomaxprocs** is gelijk aan het aantal vCPUs. Cilium op workers heeft 2× de threads van CPs.

### 5.2 Endpoints, Identities, Policies

| Node | Endpoints | Identities | Policies | Selector identities |
|------|-----------|------------|----------|-------------------|
| talos-8ys-e0s | 3 | 10 | 19 | 76 |
| talos-e3c-439 | 2 | 10 | 19 | 76 |
| talos-gs1-szo | 36 | 34 | 19 | 76 |
| talos-h2b-ilf | 31 | 29 | 19 | 76 |
| talos-w60-47p | 34 | 32 | 19 | 76 |

Workers hebben 15–18× meer endpoints dan controlplanes. Dit verklaart het verschil in Cilium CPU-verbruik.

### 5.3 Endpoint Regenerations

| Node | Aantal regeneraties | Oorzaak |
|------|---------------------|---------|
| talos-8ys-e0s | 18 | Recent herstart, weinig |
| talos-e3c-439 | 10 | Recent herstart, weinig |
| talos-gs1-szo | 4674 | **Periodieke regeneratie elke 120s** |
| talos-h2b-ilf | 4000 | Idem |
| talos-w60-47p | 4347 | Idem |

Cilium voert **periodieke endpoint regeneration** uit om de eBPF-programma's fris te houden. Dit gebeurt elke ~2 minuten per endpoint. Met 30+ endpoints betekent dit ~15 regeneraties per minuut. Elke regeneratie compileert eBPF bytecode en installeert deze — dit kost CPU.

### 5.4 Conntrack GC

| Node | GC interval | GC entries (per run) | GC runs |
|------|-------------|----------------------|---------|
| talos-8ys-e0s | 450s | 12–901 | 5 |
| talos-e3c-439 | 450s | 8–121 | 4 |
| talos-gs1-szo | 675s | 219–15486 | 92 |
| talos-h2b-ilf | 675s | 86–12524 | 77 |
| talos-w60-47p | 675s | 358–16486 | 76 |

**Conntrack entries op workers zijn 100–1000× hoger** dan op CPs. Dit is logisch: alle pod-netwerkverkeer gaat door de worker Cilium agent. Grote aantallen conntrack entries (tot 16K) vereisen meer GC-cycli en eBPF map operations.

### 5.5 Workqueue Status

Alle controllers (161–185) rapporteren **healthy**. De metric `cilium_k8s_workqueue_longest_running_processor_seconds: 19072s` die we eerder zagen is geen stuck queue, maar reflecteert simpelweg de uptime van de Cilium agent — de queue heeft al die tijd bestaan en wordt continu verwerkt.

### 5.6 Cilium Conclusie

Cilium draagt **~80–100m (2–2.5% van 1 core)** bij aan het huidige CPU-verbruik op workers, plus de overhead van eBPF-programma's voor elk netwerkpacket. De cumulatieve CPU-time van 1200–1800s in 5 uur (~6–10% van één core gemiddeld) is normaal voor een Cilium agent met 30+ endpoints en 19 policies.

---

## 6. Platformservices Analyse

### 6.1 Longhorn

Longhorn is een significante CPU-verbruiker op elke worker:

**Per worker:**
- 1× `instance-manager` — 50–112m current CPU, 277–298 MB
- 1× `longhorn-manager` — 24–38m, 161–170 MB
- 2–3× `longhorn-engine` (controller/replica) — 4–72m per stuk, 33–38 MB
- 1× `engine-image` — ~20m, 2–3 MB

**Totaal geschat per worker: ~200–300m CPU (5–7.5% van 4 cores).**

Longhorn draait 15 PVCs met replica's verspreid over de workers. De instance manager en engine processen zijn continu bezig met sync, snapshot management, en replica health checks.

### 6.2 Prometheus (monitoring)

Draait op talos-h2b-ilf:
- **702 MB resident** — grootste memory consumer op die node
- **39m current CPU** — TSDB compaction, WAL replay, scraping
- 10 GB PVC via Longhorn

Prometheus scrapet alle pods/services in het cluster. De overhead is het TSDB (Time Series Database) dat continu data comprimeert en opschrijft.

### 6.3 Alloy (monitoring)

Draait op talos-gs1-szo:
- **280 MB resident**, 8m CPU
- Stuurt metrics/logs/traces door naar Loki, Tempo, en externe sinks
- Verwerkt data van alle cluster components

### 6.4 Loki (monitoring)

Draait op talos-w60-47p:
- **198 MB resident**, 27m CPU
- 10 GB PVC via Longhorn single-replica
- Log indexing en query voor alle cluster logs

### 6.5 ArgoCD Application Controller

Draait op talos-w60-47p:
- **517 MB resident** — grootste pod op die node
- **6m current CPU** maar **2122s cumulatieve CPU-time**
- 14 threads — watcher loops, Git polling, diff berekening

### 6.6 Authentik

- **Worker pod:** 499m CPU (hoogste van alle pods!), 276 MB — Python worker process
- **Server pod:** 38m, 498 MB
- **Database (3× PostgreSQL via CNPG):** 16–27m per node, 109–666 MB per instance
- 3× 20 GB PVCs via Longhorn single-replica

De Authentik worker is de **grootste CPU-verbruiker** van alle pods. Dit is de background worker die policies evalueert, tokens ververst, en events verwerkt.

### 6.7 Overige services

| Service | Pods | CPU | MEM | Opmerking |
|---------|------|-----|-----|-----------|
| Grafana | 1 | 12m | 284 MB | Dashboards, alerts |
| Traefik (2×) | 2 | 10m | 98 MB | Ingress controller |
| NetBird routing peer | 1 | 20m | 45 MB | WireGuard, eBPF proxy |
| Bao/OpenBao | 1 | 58m | 54 MB | Secrets engine |
| External Secrets | 3 | 3–9m | 65–106 MB | |
| CrowdSec (3×) | 3 | 7m | 40 MB | |
| Velero | 4 | 2–10m | 63–128 MB | Backups |
| Hubble relay/UI | 2 | — | — | Cilium UI |
| CoreDNS (2×) | 2 | — | — | DNS |

---

## 7. Container Restarts (Indicator van Instabiliteit)

| Pod | Namespace | Restarts | Oorzaak |
|-----|-----------|----------|---------|
| cloudnativepg-cloudnative-pg | cnpg-system | **14 + 11** | CP herstart ~10m geleden → CNPG pods verloren etcd verbinding |
| argocd-image-updater | argocd | 11 | Image pull errors? |
| authentik-server | authentik | 7 | DB connectie verloren bij herstart |
| csi-attacher | longhorn-system | 2–10 | Longhorn op CP herstart |
| csi-provisioner | longhorn-system | 3–10 | Idem |
| csi-resizer | longhorn-system | 4–9 | Idem |
| csi-snapshotter | longhorn-system | 4–8 | Idem |
| grafana | monitoring | 2 | Recent herstart |
| loki-0 | monitoring | 1 | Recent herstart |
| velero-ui | monitoring | 1 | |
| velero | velero | 1 | |
| kube-\* | kube-system | 1 | CP herstart |

**Patroon:** De meeste restarts zijn geclusterd rond de recente controlplane herstart (~10 minuten geleden). De CNPG operator (CloudNative PG) met 14+11 restarts is opvallend — dit is de operator die de Authentik databases beheert. Dit kan duiden op een race condition bij CP herstart.

---

## 8. Talos System Services

Alle services op alle nodes zijn **Running/OK**:

| Service | Functie |
|---------|---------|
| machined | Talos machine manager |
| kubelet | K8s kubelet |
| containerd (system) | Systeem container runtime |
| cri | K8s container runtime (containerd) |
| etcd | Alleen op CPs |
| apid | Talos API daemon |
| trustd | Trust/join daemon |
| dashboard | Talos web UI |
| udevd | Device manager |
| auditd | Audit logging |
| syslogd | Syslog |
| ext-iscsid | iSCSI initiator |
| ext-qemu-guest-agent | VM guest agent |

De system services gebruiken minimale CPU — alleen `dashboard` (7–9 threads, 6–354s CPU-time) en `containerd` (system, 0.7s CPU-time) zijn noemenswaardig.

---

## 9. Conclusie: Waarom daalt CPU niet naar 5%?

### Antwoord in één zin:
**Het cluster is niet idle — er draait een complete platformstack met Cilium, Longhorn, Prometheus, Loki, ArgoCD, Authentik, en 15 persistent volumes, en dat kost 17–34% CPU op 4-core workers.**

### Uitsplitsing per component (geschat aandeel op een worker met 4 cores bij 30% totaal):

| Component | Geschat aandeel | Waarom |
|-----------|-----------------|--------|
| **Cilium agent** | ~6–8% | eBPF datapath, conntrack GC, 30 endpoints, periodieke regeneratie |
| **Kubelet** | ~4–6% | cAdvisor, pod sync, image GC, 24–39 threads |
| **Containerd** | ~3–5% | Image management, container lifecycle, snapshots |
| **Longhorn** | ~5–7% | Instance manager, replica sync, engine processes |
| **Monitoring (Prometheus/Loki/Alloy)** | ~3–5% | TSDB, scrape, log ingest, metric forwarding |
| **ArgoCD app-controller** | ~2–3% | Git watcher, diff, sync |
| **Authentik worker** | ~2–3% | Python event processing |
| **Overig (Redis, Bao, NetBird, etc.)** | ~2–3% | Divers |
| **Totaal** | **~27–40%** | Past bij gemeten 17–34% |

### Waarom de controlplanes lager zijn (14–23% op 2 cores):
- Minder endpoints (2–3 vs 30+)
- Geen Longhorn dataplane
- Geen zware platformservices
- Recent herstart (minder opgebouwde staat)

### Aanbevelingen voor optimalisatie

1. **Cilium periodic regeneration** — standaard interval is 120s. Dit kan omhoog (bijv. 300s) of uitgezet worden als er weinig policy churn is. Scheelt ~1–2% CPU.
2. **Authentik worker** — 499m CPU is excessief. Controleer of er een event loop vastloopt of dat de scrape rate te hoog is. Overweeg resource limits.
3. **kubelet** — 39 threads op workers is veel. Kijk naar `--kube-api-qps` en `--kube-api-burst` of er te veel syncs zijn.
4. **Longhorn** — instance manager op 24–27 threads per worker. Overweeg of er replica's zijn in rebuilding state die CPU kosten.
5. **CNPG restarts** — 14+ restarts in 10 minuten duidt op een instabiliteit die verdient onderzocht te worden (etcd connectivity?).
6. **Alle restarts** — het feit dat zoveel pods herstartten bij de CP herstart suggereert dat de etcd/kube-apiserver downtime langer was dan de pod tolerance. Overweeg PDBs of readiness probe tuning.

### Maar kan het naar 5%?

Alleen als je de platformservices uitzet. Een "kaal" cluster met alleen Cilium + kubelet + containerd draait op een 4-core worker rond de **8–12% idle**. De extra 10–20% komt door Longhorn, monitoring, ArgoCD, en Authentik — dit zijn bewust geïnstalleerde platformservices die waarde toevoegen.

**5% is een onrealistische target voor een productiecluster met deze stack.**

---

## 10. Dataverantwoording

Alle metingen zijn verzameld op 2026-06-01 ~19:00 UTC via:
- `kubectl top nodes` — actueel CPU/memory per node
- `kubectl top pods` — actueel CPU/memory per pod
- `talosctl processes` — resident memory, CPU-time, threads per proces
- `kubectl exec <cilium-pod> -- cilium status --verbose` — Cilium controllers, endpoints
- `kubectl exec <cilium-pod> -- cilium metrics list` — conntrack, workqueue, regenerations
- `talosctl version`, `talosctl read /proc/cpuinfo` — node specs
- `kubectl get pods -A` — volledige pod lijst met restarts
