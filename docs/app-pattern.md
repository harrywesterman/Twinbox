# App Pattern

Twinbox standardizes how applications are deployed on the Kubernetes cluster. Every app follows the same pattern built around four platform components: **Longhorn** for storage, **Traefik** for ingress, **CloudNativePG** for PostgreSQL, and **Authentik** for authentication and authorization.

## Component Overview

### Longhorn — Storage

Longhorn is the default StorageClass for all stateful workloads. It provides:
- Distributed block storage across all nodes
- Snapshot and backup support
- Automatic replica placement

Stateless apps (Headlamp, Grafana with external storage) do not need a PVC. Stateful apps define a PVC in their Helm values:

```yaml
persistence:
  enabled: true
  storageClass: longhorn
  size: 10Gi
```

CloudNativePG Clusters use Longhorn via `storageClass: longhorn` in the Cluster spec.

### Traefik — Ingress

Apps are exposed via **IngressRoute CRDs**, not via pod labels or annotations. Each app gets its own `IngressRoute` resource in `gitops/platform/<app>/ingressroute.yaml`.

Twinbox supports four ingress strategies, chosen by the user during setup:

**Wiredoor** — A self-hosted WireGuard-based tunnel to an external server (e.g. Hetzner VM). All traffic flows through the `webwiredoor` entryPoint (port 8081). Let's Encrypt certificates are managed by the Wiredoor server. No third party sees your traffic, and there are no upload limits.

**Cloudflare Tunnel** — An outbound tunnel from the cluster to Cloudflare's edge using `cloudflared`. All traffic flows through the `websecure` entryPoint. Cloudflare handles TLS termination and DDoS protection, but can see HTTP traffic. The free plan has a 100MB upload limit.

**MetalLB + Port Forwarding** — MetalLB assigns a real IP on the local network to Traefik. The user configures port forwarding on their router (80/443). Traefik manages Let's Encrypt certificates directly via HTTP-01 challenge. Full control, zero external dependencies, no third party sees traffic.

**Tailscale** — The cluster joins a Tailscale tailnet. Users connect by enabling Tailscale on their device. No port forwarding, no external VM, no public DNS needed. Access control via Tailscale ACLs. Can be self-hosted with Headscale for full control.

All strategies use the same IngressRoute structure — only the `entryPoints` and `tls` fields differ. Domain names are rendered from the `cluster-config` ConfigMap into the final Traefik match expressions.

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
| 4 | `gitops/platform/<app>/ingressroute.yaml` | Traefik IngressRoute for public and Wiredoor routes |
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

**poolers.yaml** — rw and ro poolers:
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

**scheduled-backup.yaml** — Daily backup:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: <app>-db-backup
  namespace: databases
spec:
  schedule: "0 2 * * *"
  backupOwnerReference: self
  cluster:
    name: <app>-db
```

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
  name: <app>-wiredoor
  namespace: <app-namespace>
spec:
  entryPoints:
    - webwiredoor
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

1. **Provider** — OIDC/OAuth2 Provider for the app:
   - Authorization URL: `https://authentik.domain.com/application/o/authorize/`
   - Token URL: `https://authentik.domain.com/application/o/token/`
   - Redirect URI: `https://app.domain.com/` (forwardAuth does not use a callback, the outpost handles this)

2. **Application** — Link the Provider to an Application:
   - Back-ends: `http://<app>.<namespace>.svc.cluster.local:<port>` (for forwardAuth)
   - Policy Engine: Attach a Group Policy that only allows the `admins` group

3. **Policy Binding** — Group restriction:
   - Create a `Group Policy` that checks if the user is a member of `admins`
   - Bind this policy to the Application
   - Users outside the group receive a 403 from Authentik

## Headlamp Example

Headlamp is the blueprint for all subsequent apps. Here is the complete implementation:

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
      targetRevision: "0.29.1"
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
```

Headlamp is stateless and does not need a database.

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
      match: Host(`headlamp.<selected-domain>`)
      middlewares:
        - name: authentik-forwardauth
          namespace: authentik
      services:
        - kind: Service
          name: my-headlamp
          port: 80
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp-wiredoor
  namespace: kube-system
spec:
  entryPoints:
    - webwiredoor
  routes:
    - kind: Rule
      match: Host(`headlamp.<selected-domain>`)
      middlewares:
        - name: authentik-forwardauth
          namespace: authentik
      services:
        - kind: Service
          name: my-headlamp
          port: 80
```

## Authentik forwardAuth Integration

### How forwardAuth Works

1. User visits `headlamp.domain.com`
2. Traefik intercepts the request and sends a sub-request to:
   ```
   http://authentik-server.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik
   ```
3. Authentik checks:
   - Does a valid session cookie exist?
   - Is the user a member of the required group (e.g. `admins`)?
4. On success:
   - Authentik returns HTTP 200
   - Headers are added: `X-authentik-username`, `X-authentik-groups`, `X-authentik-email`
   - Traefik forwards the original request to Headlamp
5. On failure:
   - Authentik returns HTTP 401 or 403
   - Traefik redirects the user to the Authentik login page

### Headers

The forwardAuth configuration passes these headers to the app:

| Header | Contents |
|--------|----------|
| `X-authentik-username` | Username |
| `X-authentik-groups` | Comma-separated list of groups |
| `X-authentik-email` | Email address |
| `X-authentik-name` | Full name |
| `X-authentik-uid` | Unique user ID |

Apps can use these headers for audit logging or personalized greetings, but **not** for authorization — Authentik already handles that.

### Group Filtering

Group restriction happens **in Authentik**, not in Traefik:

1. Create a **Policy** in Authentik: `Group is admins`
2. Bind this policy to the Headlamp Application
3. Users outside the `admins` group receive a 403 directly from Authentik

This keeps the Traefik configuration simple and the authorization logic centrally managed in Authentik.

## Database Template Structure

The template in `gitops/databases/_template/` contains four files that together define a complete database infrastructure:

### cluster.yaml

Defines a 3-node PostgreSQL 16.4 Cluster with:
- Longhorn storage (10Gi)
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

### scheduled-backup.yaml

Daily backup at 02:00 UTC:
- Backup owner reference: `self` (deleted with the Cluster)
- Storage via the default Velero/Longhorn backup location

## Volume Resize and Capacity Management

### Initial Sizing

The `size` field in a PVC or CloudNativePG Cluster spec defines the **initial capacity**. Start conservative — you can always grow later.

```yaml
storage:
  size: 10Gi
  storageClass: longhorn
```

### Online Resize (No Downtime)

Longhorn supports online volume expansion. You can resize a PVC while the pod is running:

```bash
# Resize an app PVC
kubectl patch pvc <app>-data -n <namespace> \
  --type merge -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# Resize a CloudNativePG volume
kubectl patch cluster <app>-db -n databases \
  --type merge -p '{"spec":{"storage":{"size":"20Gi"}}}'
```

Longhorn automatically expands the underlying volume and the filesystem grows to fill the new space. No pod restart is needed.

### Capacity Monitoring

Prometheus and Grafana (already deployed) track PVC usage. Set up alerts for:

- **Warning**: PVC usage > 70%
- **Critical**: PVC usage > 85%
- **Emergency**: PVC usage > 95%

This gives you time to resize before the volume fills up.

### Sizing Guidelines

| App Type | Initial Size | Growth Pattern |
|----------|-------------|----------------|
| Stateless (Headlamp) | No PVC needed | N/A |
| Light state (Ntfy) | 5Gi | Slow, predictable |
| Monitoring data (Loki) | 20Gi | Steady, depends on retention |
| Database (CloudNativePG) | 10Gi+ | Depends on app, monitor closely |
| File storage (Grafana dashboards) | 5Gi | Very slow |

## Volume Resize and Capacity Management

### Initial Sizing

The `size` field in a PVC or CloudNativePG Cluster spec defines the **initial capacity**. Start conservative — you can always grow later.

```yaml
storage:
  size: 10Gi
  storageClass: longhorn
```

### Online Resize (No Downtime)

Longhorn supports online volume expansion. You can resize a PVC while the pod is running:

```bash
# Resize an app PVC
kubectl patch pvc <app>-data -n <namespace> \
  --type merge -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# Resize a CloudNativePG volume
kubectl patch cluster <app>-db -n databases \
  --type merge -p '{"spec":{"storage":{"size":"20Gi"}}}'
```

Longhorn automatically expands the underlying volume and the filesystem grows to fill the new space. No pod restart is needed.

### Capacity Monitoring

Prometheus and Grafana (already deployed) track PVC usage. Set up alerts for:

- **Warning**: PVC usage > 70%
- **Critical**: PVC usage > 85%
- **Emergency**: PVC usage > 95%

This gives you time to resize before the volume fills up.

### Sizing Guidelines

| App Type | Initial Size | Growth Pattern |
|----------|-------------|----------------|
| Stateless (Headlamp) | No PVC needed | N/A |
| Light state (Ntfy) | 5Gi | Slow, predictable |
| Monitoring data (Loki) | 20Gi | Steady, depends on retention |
| Database (CloudNativePG) | 10Gi+ | Depends on app, monitor closely |
| File storage (Grafana dashboards) | 5Gi | Very slow |

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
- The rendered route strings were missing or stale in `cluster-config`
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
     size: 20Gi
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
