# App Pattern

Twinbox standardizes how applications are deployed on the Kubernetes cluster. Every app follows the same pattern built around four platform components: **Longhorn** for storage, **Traefik** for ingress, **CloudNativePG** for PostgreSQL, and **Authentik** for authentication and authorization.

## Component Overview

### Longhorn — Storage

Longhorn is the default StorageClass for all stateful workloads. It provides:
- Distributed block storage across all nodes
- Snapshot and backup support
- Automatic replica placement

Stateless apps (Headlamp, Grafana with external storage) do not need a PVC.
Stateful apps define a PVC in their Helm values and should size it from the
cluster's Longhorn budget, not from a guess about the app's eventual lifetime.

```yaml
persistence:
  enabled: true
  storageClass: longhorn
  size: 10Gi
```

CloudNativePG clusters use Longhorn via `storageClass: longhorn` or
`storageClass: longhorn-single` in the Cluster spec.

#### Cluster Budget Sizing

Use the worker disks that Longhorn can actually schedule on as the budget input.
Then keep a cluster-wide free-space buffer, and pick the smallest band that fits
the workload's current state.

| Band | Rule of thumb | Typical use |
|------|---------------|-------------|
| Small | `1-2%` of cluster budget | Portal state, dashboards, admin helpers |
| Medium | `2-5%` of cluster budget | App metadata, caches, small queues |
| Large | `5-10%` of cluster budget | Normal app data and modest databases |
| Heavy/media | `10%+` of cluster budget | User files, photos, logs, traces |

Replica-aware footprint matters:

- `longhorn` requests cost roughly `requested size × 3`
- `longhorn-single` requests cost roughly `requested size × 1`

That means a `10Gi` volume on `longhorn` claims about `30Gi` of schedulable
space, even if the filesystem is still mostly empty.

### Practical Default Sizes

| App class | Default size | Notes |
|-----------|--------------|-------|
| Small | `5Gi` | Portal, Dashy, pgAdmin, FreshRSS, other light metadata |
| Medium | `10Gi` | OpenCloud config/apps, OpenBao, Zulip, Tempo, light queues |
| Large | `20Gi` | Databases, observability, general app state |
| Heavy/media | `50Gi+` | Immich libraries, Nextcloud user data, bulky app data |

Start at the low end of the band and resize when the PVC usage alerts fire.

### Traefik — Ingress

Apps are exposed via **IngressRoute CRDs**, not via pod labels or annotations. Each app gets its own `IngressRoute` resource in `gitops/platform/<app>/ingressroute.yaml`.

Twinbox supports two ingress strategies, chosen by the user during setup:

**Cloudflare Tunnel** — An outbound tunnel from the cluster to Cloudflare's edge using `cloudflared`. All traffic flows through the `websecure` entryPoint. Cloudflare handles TLS termination and DDoS protection, but can see HTTP traffic. The free plan has a 100MB upload limit.
On Cloudflare Free, Twinbox only offers this route for `prd` clusters. See [`docs/ingress-policy.md`](./ingress-policy.md) for the canonical ingress and hostname rules.

**NetBird** — A self-hosted WireGuard VPN with Authentik SSO. Routing peers in Kubernetes forward traffic to Traefik through the NetBird reverse proxy path on the `webnetbird` entryPoint.

Public apps generally define two matching `IngressRoute` resources: `<app>` on `websecure` with `tls: {}` for Cloudflare Tunnel or direct HTTPS origin traffic, and `<app>-netbird` on `webnetbird` without `tls` for NetBird Reverse Proxy traffic to Traefik port `8082/http`. Domain names are projected at Argo render time from the local cluster secret annotation into the final Traefik match expressions, and Argo host patches should cover both route names.

### CloudNativePG — PostgreSQL

Apps that need a database do **not** run their own PostgreSQL instance. Instead they use the shared CloudNativePG platform:

1. Copy `gitops/databases/_template/` to `gitops/databases/<app>/`
2. Replace `CHANGEME` with the app name
3. Store credentials in OpenBao under `twinbox/global/<app>`
4. The app connects to `<app>-db-pooler-rw.databases.svc.cluster.local:5432`

Each database gets:
- A 3-node PostgreSQL Cluster with Longhorn storage
- A read-write PgBouncer pooler
- A read-only PgBouncer pooler
- A Barman Cloud Plugin ObjectStore backed by SeaweedFS
- A ScheduledBackup for daily backups
- An ExternalSecret that pulls credentials from OpenBao

### Authentik — Authentication and Authorization

Authentik is the central identity provider. Apps use **Traefik forwardAuth** to handle authentication and authorization before the request reaches the app.

The pattern:
1. User visits `app.domain.com`
2. Traefik sends the request to Authentik's forwardAuth endpoint first
3. Authentik checks if the user is logged in and a member of the required group
4. On success, Authentik adds headers (`X-authentik-username`, `X-authentik-groups`, etc.)
5. Traefik forwards the request to the app

Group filtering happens **in Authentik** via Policy Bindings on the Application, not in Traefik. This keeps the middleware simple and the authorization logic centrally managed.

## Step-by-Step Pattern for New Apps

| Step | Location | Purpose |
|------|----------|---------|
| 1 | `gitops/apps/<app>.yaml` | Argo CD Application with Helm chart and values reference |
| 2 | `gitops/values/<app>.yaml` | Helm values: replicas, tolerations, PVC, app-specific config |
| 3 | `gitops/databases/<app>/` | CloudNativePG Cluster + Pooler + ExternalSecret (optional, only for apps with Postgres) |
| 4 | `gitops/platform/<app>/ingressroute.yaml` | Traefik IngressRoute for public routes |
| 5 | `gitops/platform/<app>/middleware.yaml` | forwardAuth Middleware (optional, only for apps with Authentik) |
| 6 | Authentik UI/API | Configure Application + Provider + Group Policy |

### Step 1: Argo CD Application

Create `gitops/apps/<app>.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: <helm-repo-url>
      chart: <chart-name>
      targetRevision: "<version>"
      helm:
        valueFiles:
          - $values/gitops/values/<app>.yaml
    - repoURL: __REPO_URL__
      targetRevision: __TARGET_REVISION__
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: <app-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Step 2: Helm Values

Create `gitops/values/<app>.yaml`:

```yaml
replicaCount: 1

tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule

service:
  type: ClusterIP

# Optional: Longhorn PVC for stateful apps
persistence:
  enabled: true
  storageClass: longhorn
  size: 10Gi

# Optional: OIDC config if the app supports it natively
# OIDC is primarily handled by Traefik forwardAuth
```

### Step 3: Database (Optional)

Copy the template and customize:

```bash
cp -r gitops/databases/_template gitops/databases/<app>
```

Customize the four files:

**cluster.yaml** — Replace `CHANGEME` with the app name:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <app>-db
  namespace: databases
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  bootstrap:
    initdb:
      database: <app>
      owner: <app>
      secret:
        name: <app>-db-credentials
  storage:
    size: 10Gi
    storageClass: longhorn
```

**externalsecret.yaml** — Link to OpenBao:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-db-credentials
  namespace: databases
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: <app>-db-credentials
    creationPolicy: Owner
    deletionPolicy: Delete
  data:
    - secretKey: username
      remoteRef:
        key: twinbox/global/<app>
        property: <APP>_POSTGRESQL__USERNAME
    - secretKey: password
      remoteRef:
        key: twinbox/global/<app>
        property: <APP>_POSTGRESQL__PASSWORD
```

**poolers.yaml** — rw, optional rw-session, and ro poolers:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: <app>-db-pooler-rw
  namespace: databases
spec:
  cluster:
    name: <app>-db
  instances: 2
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "200"
      default_pool_size: "20"
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: <app>-db-pooler-rw-session
  namespace: databases
spec:
  cluster:
    name: <app>-db
  instances: 2
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "200"
      default_pool_size: "20"
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: <app>-db-pooler-ro
  namespace: databases
spec:
  cluster:
    name: <app>-db
  instances: 2
  type: ro
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "200"
      default_pool_size: "20"
```

Use the `-rw-session` service only for apps that depend on session-bound PostgreSQL behavior such as advisory locks or long-lived server-side coordination. Authentik is the first cluster app that needs this exception.

**scheduled-backup.yaml** — Weekly base backup:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: <app>-db-backup
  namespace: databases
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  schedule: "0 0 2 * * 1"
  backupOwnerReference: self
  cluster:
    name: <app>-db
```

Base backups are weekly and spread across the week (one or two databases per day) so they never all run at once against the local SeaweedFS bucket. The schedule is a six-field cron (`second minute hour day-of-month month day-of-week`) with weekdays 1-7, so `"0 0 2 * * 1"` means 02:00:00 on Monday. Continuous WAL archiving (`isWALArchiver: true` on the Cluster) already provides point-in-time recovery with minute-level RPO, so the base backup only sets the recovery baseline; the ObjectStore `retentionPolicy: "14d"` covers several base backups plus the WAL replay window.

### Step 4: IngressRoute

Create `gitops/platform/<app>/ingressroute.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>
  namespace: <app-namespace>
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`<app>.<selected-domain>`)
      middlewares:
        - name: authentik-forwardauth
          namespace: authentik
      services:
        - kind: Service
          name: <app-service-name>
          port: 80
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>-netbird
  namespace: <app-namespace>
spec:
  entryPoints:
    - webnetbird
  routes:
    - kind: Rule
      match: Host(`<app>.<selected-domain>`)
      middlewares:
        - name: authentik-forwardauth
          namespace: authentik
      services:
        - kind: Service
          name: <app-service-name>
          port: 80
```

### Step 5: forwardAuth Middleware

The forwardAuth Middleware is shared once across all apps. Create `gitops/platform/authentik/forwardauth-middleware.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forwardauth
  namespace: authentik
spec:
  forwardAuth:
    address: "http://authentik-server.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik"
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
```

This Middleware is referenced in every IngressRoute via:
```yaml
middlewares:
  - name: authentik-forwardauth
    namespace: authentik
```

### Step 6: Authentik Configuration

Configure in the Authentik UI:

1. **Bootstrap user** — Run the Twinbox `create-users-and-groups` step first:
   - Create the first Authentik user with your name and login name
   - Reuse the Management VM cluster login password as that user's password
   - Place the user in the `admins` group so later applications can authorize against it

2. **Provider** — OIDC/OAuth2 Provider for the app:
   - Authorization URL: `https://authentik.domain.com/application/o/authorize/`
   - Token URL: `https://authentik.domain.com/application/o/token/`
   - Redirect URI: `https://app.domain.com/` (forwardAuth does not use a callback, the outpost handles this)

3. **Application** — Link the Provider to an Application:
   - Back-ends: `http://<app>.<namespace>.svc.cluster.local:<port>` (for forwardAuth)
   - Policy Engine: Attach a Group Policy that only allows the `admins` group

4. **Policy Binding** — Group restriction:
   - Create a `Group Policy` that checks if the user is a member of `admins`
   - Bind this policy to the Application
   - Users outside the group receive a 403 from Authentik

## Headlamp Example

Headlamp uses native OIDC login with Authentik rather than Traefik forwardAuth. The Helm chart reads its OIDC settings from an OpenBao-backed secret, and Headlamp handles the browser redirect itself.

### Argo CD Application

`gitops/apps/headlamp.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: headlamp
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://kubernetes-sigs.github.io/headlamp/
      chart: headlamp
      targetRevision: "0.41.0"
      helm:
        valueFiles:
          - $values/gitops/values/headlamp.yaml
    - repoURL: __REPO_URL__
      targetRevision: __TARGET_REVISION__
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Helm Values

`gitops/values/headlamp.yaml`:
```yaml
replicaCount: 1

tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule

service:
  type: ClusterIP

config:
  inCluster: true
  oidc:
    secret:
      create: false
    externalSecret:
      enabled: true
      name: headlamp-oidc
```

Headlamp is stateless and does not need a database.

### OpenBao Secret

`gitops/platform/headlamp/externalsecret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: headlamp-oidc
  namespace: kube-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: headlamp-oidc
    creationPolicy: Owner
    deletionPolicy: Delete
```

### IngressRoute

`gitops/platform/headlamp/ingressroute.yaml`:
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
      match: Host(`headlamp.<public-zone-name>`)
      services:
        - kind: Service
          name: headlamp
          port: 80
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp-netbird
  namespace: kube-system
spec:
  entryPoints:
    - webnetbird
  routes:
    - kind: Rule
      match: Host(`headlamp.<public-zone-name>`)
      services:
        - kind: Service
          name: headlamp
          port: 80
```

## Authentik OIDC Integration

### How Headlamp Login Works

1. User visits `headlamp.<public-zone-name>` such as `headlamp.tst.example.com`
2. Headlamp reads `HEADLAMP_CONFIG_OIDC_CLIENT_ID`, `HEADLAMP_CONFIG_OIDC_CLIENT_SECRET`, `HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL`, and `HEADLAMP_CONFIG_OIDC_SCOPES` from the mounted secret
3. Headlamp sends the browser to Authentik's OIDC authorization endpoint
4. Authentik validates the user session and returns the browser to `https://headlamp.<public-zone-name>/oidc-callback`
5. Headlamp exchanges the authorization code for tokens and opens the dashboard

### Authentik Provider

Twinbox creates a dedicated Authentik OAuth2/OIDC application for Headlamp using OpenTofu:

1. `authentik_provider_oauth2.headlamp` creates a confidential OIDC client
2. `authentik_application.headlamp` binds the provider to the Headlamp application entry
3. The provider uses the redirect URI `https://headlamp.<public-zone-name>/oidc-callback`
4. The issuer URL is `https://authentik.<public-zone-name>/application/o/headlamp/`
5. Headlamp requests the default `openid profile email` scopes

Because Headlamp uses its own OIDC flow, it does not need the shared Traefik forwardAuth middleware that other apps use.

## Database Template Structure

The template in `gitops/databases/_template/` contains five files that together define a complete database infrastructure:

### cluster.yaml

Defines a 3-node PostgreSQL 16.4 Cluster with:
- Longhorn storage (10Gi)
- Barman Cloud Plugin WAL archiving through the matching ObjectStore
- Resource limits (1 CPU, 2Gi memory per pod)
- Pod anti-affinity for spreading across nodes
- 100 max connections
- Monitoring via PodMonitor

### externalsecret.yaml

Pulls database credentials from OpenBao:
- Path: `twinbox/global/<app>`
- Properties: `<APP>_POSTGRESQL__USERNAME` and `<APP>_POSTGRESQL__PASSWORD`
- Refresh interval: 1 hour
- Creates a Kubernetes Secret in the `databases` namespace

### poolers.yaml

Two PgBouncer poolers:
- **rw pooler** — Read-write connections for the app
- **ro pooler** — Read-only connections for reporting/analytics
- Both: 2 instances, transaction pool mode, 200 max clients, 20 default pool size

### objectstore.yaml

Configures the Barman Cloud Plugin backup target:
- Destination path: `s3://twinbox-velero/<app>-db/`
- Endpoint: SeaweedFS on the Management VM
- Credentials: `seaweedfs-backup-credentials`
- Retention: 14 days

### scheduled-backup.yaml

Daily backup at 02:00 UTC:
- Method: Barman Cloud Plugin
- Backup owner reference: `self` (deleted with the Cluster)
- Storage via the app's ObjectStore backed by SeaweedFS on the Management VM

## Volume Resize and Capacity Management

The `size` field in a PVC or CloudNativePG Cluster spec defines the **initial
capacity**. Start at the lower end of the band, then grow when the PVC usage
alerts fire.

```bash
# Resize an app PVC
kubectl patch pvc <app>-data -n <namespace> \
  --type merge -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# Resize a CloudNativePG volume
kubectl patch cluster <app>-db -n databases \
  --type merge -p '{"spec":{"storage":{"size":"20Gi"}}}'
```

Longhorn expands the underlying volume online, so this is a normal operational
change rather than a migration.

Prometheus and Grafana already track PVC usage:

- **Warning**: PVC usage > 70%
- **Critical**: PVC usage > 85%
- **Emergency**: PVC usage > 95%

Those alerts are the resize trigger, not the point where you start planning.

## Troubleshooting

### forwardAuth fails with 500

**Symptom**: Users get a 500 error when visiting an app.

**Causes**:
- Authentik server is not reachable from the Traefik namespace
- The outpost URL is incorrect
- Authentik Application is not configured correctly

**Resolution**:
```bash
# Check if Authentik server is running
kubectl get pods -n authentik

# Test the forwardAuth endpoint from the Traefik namespace
kubectl exec -n traefik deploy/traefik -- wget -qO- http://authentik-server.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik

# Check Authentik logs
kubectl logs -n authentik deploy/authentik-server
```

### PVC stays pending

**Symptom**: Pod stays in Pending state with volume binding errors.

**Causes**:
- StorageClass `longhorn` does not exist
- Longhorn is not installed correctly
- Insufficient storage capacity

**Resolution**:
```bash
# Check StorageClasses
kubectl get storageclass

# Check Longhorn pods
kubectl get pods -n longhorn-system

# Check Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

### Database connection fails

**Symptom**: App cannot connect to PostgreSQL.

**Causes**:
- Wrong pooler service name or namespace
- Credentials not coming from OpenBao
- CloudNativePG Cluster is not ready yet

**Resolution**:
```bash
# Check Cluster status
kubectl get cluster -n databases

# Check if the pooler exists
kubectl get pooler -n databases

# Test connectivity
kubectl run -it --rm test-pg --image=postgres:16 --restart=Never -- psql "postgresql://user:pass@<app>-db-pooler-rw.databases.svc:5432/<app>"

# Check ExternalSecret status
kubectl get externalsecret -n databases
```

### IngressRoute returns 404

**Symptom**: Visiting `app.domain.com` returns 404.

**Causes**:
- The local Argo cluster secret annotation was missing or stale
- DNS record does not point to the cluster
- Service name does not match the Helm chart output

**Resolution**:
```bash
# Check if the IngressRoute exists
kubectl get ingressroute -A

# Check the generated IngressRoute
kubectl get ingressroute <app> -n <namespace> -o yaml

# Check if the Service exists
kubectl get svc -n <namespace>

# Check DNS
dig <app>.<domain>
```

### Authentik session expires quickly

**Symptom**: Users have to log in frequently.

**Causes**:
- Session timeout is set too short in Authentik
- Cookie settings are not correct

**Resolution**:
- Go to Authentik UI → Applications → Policies → Session settings
- Increase `Session expiry` to e.g. 24 hours
- Ensure `Remember me` is enabled

## Migration Guide

Existing apps that do not yet follow this pattern can be migrated in phases.

### Apps with embedded PostgreSQL

**Example**: An app using the Bitnami PostgreSQL subchart.

**Migration**:
1. Create a CloudNativePG Cluster in `gitops/databases/<app>/`
2. Migrate data with `pg_dump` and `pg_restore`:
   ```bash
   kubectl exec -n <app> deploy/<app>-postgresql -- pg_dump -U <user> <db> > dump.sql
   kubectl exec -n databases -it <app>-db-1 -- psql -U <user> <db> < dump.sql
   ```
3. Update the Helm values to disable the embedded Postgres:
   ```yaml
   postgresql:
     enabled: false
   ```
4. Add the pooler connection string to the app config:
   ```yaml
   env:
     - name: DATABASE_URL
       value: "postgresql://user:pass@<app>-db-pooler-rw.databases.svc:5432/<app>"
   ```
5. Remove the old PVC after verification

### Apps with their own user management

**Example**: An app with its own login page and user database.

**Migration**:
1. Create an OIDC Provider and Application in Authentik
2. Add a forwardAuth Middleware to the IngressRoute
3. Migrate users to Authentik (via CSV import or LDAP sync)
4. Disable the built-in login in the app config
5. Use the `X-authentik-*` headers for user identification in the app

### Apps with hostPath volumes

**Example**: An app storing data in `/data` on the host node.

**Migration**:
1. Create a PVC with Longhorn StorageClass:
   ```yaml
   persistence:
     enabled: true
     storageClass: longhorn
     size: 10Gi
     accessMode: ReadWriteOnce
   ```
2. Migrate data from hostPath to the PVC:
   ```bash
   kubectl cp /host/path/data <namespace>/<pod>:/data
   ```
3. Update the Helm values to replace hostPath with PVC
4. Remove the hostPath configuration

### Apps without an IngressRoute

**Example**: An app only accessible via `kubectl port-forward`.

**Migration**:
1. Create an IngressRoute in `gitops/platform/<app>/ingressroute.yaml`
2. Add a DNS record for `<app>.<domain>`
3. Add forwardAuth Middleware if the app needs to be protected
4. Test the public route before disabling the port-forward
