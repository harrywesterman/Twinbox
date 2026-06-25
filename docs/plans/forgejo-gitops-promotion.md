# Forgejo GitOps Promotion on the Management VM

## Overzicht

Voeg Forgejo toe aan de Twinbox Management VM als lokale GitOps-goedkeuringspoort.

Het doel van v1 is niet om Twinbox volledig offline of volledig lokaal te maken. Het doel is:

- GitHub blijft upstream voor Twinbox ontwikkeling.
- GHCR blijft de image registry voor Twinbox images.
- Forgejo draait vroeg op de Management VM.
- Argo CD kan naar Forgejo `main` kijken in plaats van direct naar GitHub `main`.
- Een cluster-admin beslist wanneer commits uit GitHub worden gepromoveerd naar Forgejo `main`.
- Automatische Twinbox-owned image updates mogen de review-poort niet omzeilen.

Dit houdt het ontwerp bewust kleiner dan "Forgejo + Actions + lokale registry + release bundles". Die onderdelen kunnen later als v2 komen. In v1 is Forgejo alleen de GitOps promotion gate.

## Ontwerpkeuzes

### Wel doen in v1

- Forgejo als Docker Compose service op de Management VM.
- Persistent Forgejo data onder `/opt/twinbox/forgejo`.
- Eerste-start bootstrap die een lokale Twinbox repo in Forgejo aanmaakt of importeert vanaf GitHub.
- Configuratie waarmee Argo CD applicaties `TWINBOX_GIT_REPO_URL` naar Forgejo kunnen gebruiken.
- Een handmatige of scriptbare upstream-promotieflow:
  - fetch GitHub `main`;
  - maak/update een Forgejo branch;
  - open een Forgejo PR naar Forgejo `main`;
  - admin reviewed en merged;
  - Argo CD sync't vanuit Forgejo `main`.
- Documenteer fallback naar GitHub als Forgejo tijdelijk stuk is.

### Niet doen in v1

- Geen lokale OCI registry.
- Geen Forgejo Actions runner.
- Geen lokale image builds.
- Geen release bundle manifesten.
- Geen Talos registry mirror/fallback configuratie.
- Geen wijziging aan de GitHub Actions image publish pipeline, behalve eventueel documentatie over de relatie met Forgejo.

### Waarom deze knip

De Management VM is permanent Twinbox-infrastructuur, maar is niet HA. Als de Management VM ook de enige image registry wordt, kunnen nieuwe pods of node rebuilds vastlopen als die VM niet beschikbaar is. Door in v1 alleen GitOps approval lokaal te maken, krijgt de admin controle over wijzigingen zonder de image supply chain kwetsbaarder te maken.

## Gewenst eindbeeld

```text
GitHub main
  |
  | fetch/sync upstream branch
  v
Forgejo branch: upstream/main
  |
  | Forgejo PR + admin review
  v
Forgejo main
  |
  | Argo CD repoURL
  v
Talos Kubernetes cluster

Images blijven uit GHCR komen.
```

Als Forgejo down is:

- bestaande workloads blijven draaien;
- Argo CD kan geen nieuwe GitOps sync uit Forgejo doen;
- operators kunnen tijdelijk terugvallen naar GitHub door `TWINBOX_GIT_REPO_URL` terug te zetten en applicaties opnieuw toe te passen.

## Bestanden

| Bestand | Actie |
|---------|-------|
| `docker-compose.yml` | WIJZIG - voeg Forgejo service toe |
| `.env.example` | WIJZIG - voeg Forgejo en GitOps source variabelen toe |
| `config/pinned-defaults.sh` | WIJZIG - voeg pinned Forgejo versie en optionele Git defaults toe |
| `scripts/start-manager.sh` | WIJZIG - bootstrap Forgejo na `docker compose up -d` |
| `scripts/manager/bootstrap-forgejo.sh` | NIEUW - idempotente Forgejo bootstrap |
| `scripts/manager/forgejo-promote-upstream.sh` | NIEUW - helper voor upstream fetch/promotiebranch |
| `scripts/manager/apply-argocd-application.sh` | CONTROLEER - bestaande `TWINBOX_GIT_REPO_URL` rendering blijft leidend |
| `gitops/apps/twinbox-portal.yaml` | WIJZIG - verwijder of neutraliseer Twinbox-owned image-updater annotaties |
| `docs/configuration.md` | WIJZIG - documenteer GitOps source selection |
| `docs/architecture.md` | WIJZIG - documenteer Forgejo als local promotion gate |
| `docs/argocd-image-updater.md` | WIJZIG - leg uit dat Twinbox-owned images niet automatisch gepromoveerd worden |
| `docs/plans/forgejo-gitops-promotion.md` | NIEUW - dit plan |

## Fase 1 - Configuratie en Compose

### `config/pinned-defaults.sh`

Voeg een pinned Forgejo versie toe.

Aanbevolen:

```bash
PINNED_FORGEJO_VERSION=13.0.2
```

Laat bestaande defaults voor GitHub staan:

```bash
TWINBOX_GIT_REPO_URL=https://github.com/harrywesterman/Twinbox.git
TWINBOX_GIT_TARGET_REVISION=main
```

Voeg geen harde Forgejo default toe in `pinned-defaults.sh`, omdat nieuwe installaties zonder Forgejo-bootstrap anders te vroeg naar een nog-niet-bestaande repo kunnen wijzen.

### `.env.example`

Voeg optionele Forgejo instellingen toe:

```dotenv
# Optional local GitOps promotion gate.
FORGEJO_VERSION=13.0.2
FORGEJO_HTTP_PORT=3001
FORGEJO_SSH_PORT=2222
FORGEJO_ROOT_URL=http://192.168.1.50:3001/
FORGEJO_ADMIN_USER=twinbox-admin
FORGEJO_ADMIN_EMAIL=admin@twinbox.local

# Leave empty to generate/store during bootstrap.
FORGEJO_ADMIN_PASSWORD=

# GitHub remains upstream. Forgejo may become Argo CD's source after bootstrap.
TWINBOX_UPSTREAM_GIT_REPO_URL=https://github.com/harrywesterman/Twinbox.git
TWINBOX_FORGEJO_REPO_OWNER=twinbox
TWINBOX_FORGEJO_REPO_NAME=Twinbox
TWINBOX_FORGEJO_REPO_URL=http://192.168.1.50:3001/twinbox/Twinbox.git
```

Do not put real secrets in `.env.example`.

### `docker-compose.yml`

Add a `forgejo` service. Keep it independent of manager services so an unhealthy Forgejo does not stop the wizard UI/API.

Recommended service shape:

```yaml
  forgejo:
    image: codeberg.org/forgejo/forgejo:${FORGEJO_VERSION:-13.0.2}
    container_name: twinbox-forgejo
    restart: unless-stopped
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - FORGEJO__server__DOMAIN=${MANAGEMENT_VM_IP:-localhost}
      - FORGEJO__server__ROOT_URL=${FORGEJO_ROOT_URL:-http://${MANAGEMENT_VM_IP:-localhost}:3001/}
      - FORGEJO__server__HTTP_PORT=3000
      - FORGEJO__server__SSH_PORT=22
      - FORGEJO__service__DISABLE_REGISTRATION=true
      - FORGEJO__repository__DEFAULT_BRANCH=main
      - FORGEJO__actions__ENABLED=false
    volumes:
      - /opt/twinbox/forgejo:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${FORGEJO_HTTP_PORT:-3001}:3000"
      - "${FORGEJO_SSH_PORT:-2222}:22"
```

Notes for implementer:

- Use port `3001` because manager-web already uses host port `3000`.
- Keep Actions disabled in v1.
- Do not mount the host Docker socket.
- Do not introduce a database container in v1 unless Forgejo requires it for the chosen deployment. SQLite under `/data` is acceptable for this first local-control-plane feature.

## Fase 2 - Forgejo bootstrap

Create `scripts/manager/bootstrap-forgejo.sh`.

The script must be idempotent and safe to run on every `start-manager.sh`.

### Inputs

Read these env vars:

```bash
FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-http://127.0.0.1:${FORGEJO_HTTP_PORT:-3001}}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-twinbox-admin}"
FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-admin@twinbox.local}"
FORGEJO_ADMIN_PASSWORD="${FORGEJO_ADMIN_PASSWORD:-}"
TWINBOX_UPSTREAM_GIT_REPO_URL="${TWINBOX_UPSTREAM_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
TWINBOX_FORGEJO_REPO_OWNER="${TWINBOX_FORGEJO_REPO_OWNER:-twinbox}"
TWINBOX_FORGEJO_REPO_NAME="${TWINBOX_FORGEJO_REPO_NAME:-Twinbox}"
TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
```

### Secret storage

If `FORGEJO_ADMIN_PASSWORD` is empty:

- generate a strong password with `openssl rand -base64 32`;
- store it in `/opt/twinbox/bootstrap/secrets/global/forgejo.json`;
- file mode `0600`;
- owner root if running via sudo/root, otherwise current user;
- never print the password.

Suggested JSON shape:

```json
{
  "FORGEJO_ADMIN_USER": "twinbox-admin",
  "FORGEJO_ADMIN_EMAIL": "admin@twinbox.local",
  "FORGEJO_ADMIN_PASSWORD": "generated-secret",
  "FORGEJO_BASE_URL": "http://127.0.0.1:3001"
}
```

If the JSON already exists, read/reuse the existing password.

### Wait for Forgejo

Wait up to 120 seconds for Forgejo to respond:

```bash
curl -fsS "${FORGEJO_BASE_URL}/api/healthz"
```

If that endpoint is unavailable in the selected Forgejo version, fall back to checking the root URL with `curl -fsS`.

Failure behavior:

- log a clear warning;
- exit non-zero only when the script is run explicitly;
- when called from `start-manager.sh`, it should not prevent manager-web/API/worker from starting.

### Create admin user

Use `docker exec twinbox-forgejo forgejo admin user create ...`.

Expected behavior:

- If the user already exists, do nothing.
- If the user does not exist, create it as admin.
- Do not print the password.

Pseudo-flow:

```bash
if ! docker exec twinbox-forgejo forgejo admin user list | awk '{print $1}' | grep -qx "$FORGEJO_ADMIN_USER"; then
  docker exec twinbox-forgejo forgejo admin user create \
    --admin \
    --username "$FORGEJO_ADMIN_USER" \
    --password "$FORGEJO_ADMIN_PASSWORD" \
    --email "$FORGEJO_ADMIN_EMAIL"
fi
```

Adjust parsing if `forgejo admin user list` output differs.

### Create organization

Use Forgejo API with the admin credentials.

Create org:

```http
POST /api/v1/orgs
```

Body:

```json
{
  "username": "twinbox",
  "full_name": "Twinbox",
  "description": "Local Twinbox GitOps promotion namespace"
}
```

If org already exists, continue.

### Create or import repository

Preferred implementation:

1. Create empty repo `twinbox/Twinbox` if missing.
2. Clone GitHub upstream into a temporary directory.
3. Add Forgejo as a remote.
4. Push all branches/tags needed for v1.

Use HTTPS with admin credentials for the initial push.

Pseudo-flow:

```bash
tmp="$(mktemp -d)"
git clone --mirror "$TWINBOX_UPSTREAM_GIT_REPO_URL" "$tmp/Twinbox.git"
git -C "$tmp/Twinbox.git" remote set-url --push origin "$forgejo_push_url"
git -C "$tmp/Twinbox.git" push --mirror "$forgejo_push_url"
```

If `main` already exists in Forgejo, do not force-push it during normal bootstrap. A bootstrap script must not overwrite local admin changes.

Rules:

- First bootstrap may push `main`.
- Later bootstraps may fetch metadata but must not rewrite Forgejo `main`.
- If the repo exists, skip mirror push unless an explicit env flag is set, for example `FORGEJO_BOOTSTRAP_FORCE_IMPORT=true`.

### Record upstream

Create a marker file:

```text
/opt/twinbox/forgejo/bootstrap/upstream-url
```

Contents:

```text
https://github.com/harrywesterman/Twinbox.git
```

This is not canonical source code state. It is runtime bookkeeping.

## Fase 3 - Wire bootstrap into `start-manager.sh`

In `scripts/start-manager.sh`, after:

```bash
docker compose pull
docker compose up -d
ensure_seaweedfs_bootstrap
```

call:

```bash
if [[ "${TWINBOX_ENABLE_FORGEJO:-true}" == "true" ]]; then
  if [[ -x "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh" ]]; then
    "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh" || log "Forgejo bootstrap failed; continuing manager startup"
  elif [[ -x "./scripts/manager/bootstrap-forgejo.sh" ]]; then
    "./scripts/manager/bootstrap-forgejo.sh" || log "Forgejo bootstrap failed; continuing manager startup"
  else
    log "Forgejo bootstrap script not found; skipping"
  fi
fi
```

Also update `ensure_bootstrap_material` so the bootstrap script is downloaded into the bootstrap tree when running from the runtime-only Management VM.

Required remote files to fetch from `TWINBOX_RAW_BASE_URL`:

- `scripts/manager/bootstrap-forgejo.sh`
- `scripts/manager/forgejo-promote-upstream.sh`

## Fase 4 - Configure Argo CD source selection

The existing `scripts/manager/apply-argocd-application.sh` already renders:

```bash
repo_url="${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
target_rev="${TWINBOX_GIT_TARGET_REVISION:-main}"
```

Do not duplicate that logic in every step. The implementation should keep this script as the central source rendering point.

### Runtime switch to Forgejo

After Forgejo bootstrap succeeds, operators can set in `/opt/twinbox/.env`:

```dotenv
TWINBOX_GIT_REPO_URL=http://<management-vm-ip>:3001/twinbox/Twinbox.git
TWINBOX_GIT_TARGET_REVISION=main
```

Then refresh the manager stack:

```bash
cd /opt/twinbox
sudo -n docker compose up -d
```

New Argo CD Applications applied after this point should point to Forgejo.

### Existing Argo CD Applications

For already-created Applications, add a helper or documentation step that reapplies all Twinbox-managed Argo CD Applications after switching `TWINBOX_GIT_REPO_URL`.

Minimum v1 approach:

- document that each install step/apply script must be rerun or that applications must be re-applied;
- no mass migration script required in v1.

Better v1 approach if simple:

- add `scripts/manager/reapply-argocd-applications.sh`;
- it loops over `gitops/apps/*.yaml`;
- for each manifest, extracts `metadata.name`;
- runs `apply-argocd-application.sh --manifest ... --application ... --no-wait`;
- excludes app manifests that require runtime templating beyond `__REPO_URL__`/`__TARGET_REVISION__` unless explicitly supported.

If implementing the helper, keep it conservative. Do not guess values for manifests that require app-specific rendering such as zone placeholders.

## Fase 5 - Disable Twinbox-owned automatic image promotion

### Problem

`gitops/apps/twinbox-portal.yaml` currently allows Argo CD Image Updater to advance the portal image directly from GHCR. That bypasses the Forgejo review gate because the live app can move without a reviewed Forgejo Git change.

### Required v1 change

Remove these annotations from `gitops/apps/twinbox-portal.yaml`:

```yaml
argocd-image-updater.argoproj.io/image-list
argocd-image-updater.argoproj.io/portal.kustomize.image-name
argocd-image-updater.argoproj.io/portal.update-strategy
argocd-image-updater.argoproj.io/portal.allow-tags
argocd-image-updater.argoproj.io/write-back-method
```

Keep the image controlled by `gitops/platform-apps/twinbox-portal/kustomization.yaml`.

### Other Twinbox-owned images to audit

Search:

```bash
rg -n "ghcr.io/harrywesterman|argocd-image-updater" gitops
```

Review any Twinbox-owned image references:

- `twinbox-portal`
- `twinbox-manager-worker` helper images, such as Jitsi OIDC or Dashy helpers
- any future `twinbox-*` app image

Rule:

- third-party image automation may remain as-is;
- Twinbox-owned images must be changed through Git review.

## Fase 6 - Promotion helper

Create `scripts/manager/forgejo-promote-upstream.sh`.

This script prepares a branch in Forgejo for review. It should not merge anything.

### Inputs

```bash
FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-http://127.0.0.1:${FORGEJO_HTTP_PORT:-3001}}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-twinbox-admin}"
TWINBOX_UPSTREAM_GIT_REPO_URL="${TWINBOX_UPSTREAM_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
TWINBOX_FORGEJO_REPO_OWNER="${TWINBOX_FORGEJO_REPO_OWNER:-twinbox}"
TWINBOX_FORGEJO_REPO_NAME="${TWINBOX_FORGEJO_REPO_NAME:-Twinbox}"
PROMOTE_BRANCH="${PROMOTE_BRANCH:-promote/github-main}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
```

Read Forgejo password from `/opt/twinbox/bootstrap/secrets/global/forgejo.json`.

### Behavior

1. Create temp workdir.
2. Clone Forgejo repo.
3. Add GitHub upstream remote.
4. Fetch upstream.
5. Create/update branch `promote/github-main` from `upstream/main`.
6. Push branch to Forgejo.
7. Print the Forgejo compare/PR URL.
8. Do not create or merge PR unless this is easy via the API.

Minimum output:

```text
Promotion branch pushed:
  promote/github-main

Open a Forgejo PR:
  http://<management-vm-ip>:3001/twinbox/Twinbox/compare/main...promote/github-main
```

If using the API to create PR:

- PR title: `Promote GitHub main into Twinbox local main`
- PR body includes:
  - upstream repo URL;
  - upstream ref;
  - timestamp;
  - short instructions to review GitOps and image tag changes.

### Safety

- Never force-push `main`.
- Force-pushing `promote/github-main` is acceptable because it is a generated review branch.
- If local Forgejo `main` has diverged from GitHub, the PR should show the merge conflict/diff normally.

## Fase 7 - Documentation updates

### `docs/architecture.md`

Add a Management VM GitOps subsection:

- Management VM can run Forgejo.
- Forgejo is a local promotion gate, not the global upstream.
- GitHub remains upstream.
- GHCR remains image source in v1.
- Existing workloads do not require Forgejo to keep running.

### `docs/configuration.md`

Document:

```dotenv
TWINBOX_GIT_REPO_URL=
TWINBOX_GIT_TARGET_REVISION=
TWINBOX_UPSTREAM_GIT_REPO_URL=
TWINBOX_FORGEJO_REPO_URL=
```

Add examples:

GitHub direct mode:

```dotenv
TWINBOX_GIT_REPO_URL=https://github.com/harrywesterman/Twinbox.git
TWINBOX_GIT_TARGET_REVISION=main
```

Forgejo promotion mode:

```dotenv
TWINBOX_GIT_REPO_URL=http://192.168.1.50:3001/twinbox/Twinbox.git
TWINBOX_GIT_TARGET_REVISION=main
```

### `docs/argocd-image-updater.md`

Add a section:

```markdown
## Twinbox-owned images

When Forgejo promotion mode is enabled, Twinbox-owned images are not automatically advanced by Argo CD Image Updater. Image tag updates must land through reviewed Git changes in Forgejo.
```

## Fase 8 - Tests and verification

### Static checks

Run:

```bash
bash -n scripts/manager/bootstrap-forgejo.sh
bash -n scripts/manager/forgejo-promote-upstream.sh
bash -n scripts/start-manager.sh
```

Run compose validation:

```bash
cp .env.example .env
docker compose config >/dev/null
rm .env
```

If `.env` already exists in the local repo, do not overwrite it. Use a temp directory or backup-safe command instead.

### Functional checks on Management VM

From the Management VM:

```bash
cd /opt/twinbox
sudo -n docker compose pull
sudo -n docker compose up -d
sudo -n docker compose ps forgejo
curl -fsS http://127.0.0.1:3001/api/healthz
```

Check bootstrap secret exists:

```bash
sudo -n test -s /opt/twinbox/bootstrap/secrets/global/forgejo.json
```

Check local repo exists:

```bash
git ls-remote http://127.0.0.1:3001/twinbox/Twinbox.git refs/heads/main
```

### Promotion check

Run:

```bash
cd /opt/twinbox
sudo -n ./scripts/manager/forgejo-promote-upstream.sh
```

Expected:

- branch `promote/github-main` exists in Forgejo;
- PR URL is printed;
- no automatic merge happens.

### Argo CD source check

Set:

```dotenv
TWINBOX_GIT_REPO_URL=http://<management-vm-ip>:3001/twinbox/Twinbox.git
TWINBOX_GIT_TARGET_REVISION=main
```

Re-apply a simple app manifest using the existing manager script.

Verify:

```bash
kubectl -n argocd get application <app> -o jsonpath='{.spec.source.repoURL}'
```

or for multi-source apps:

```bash
kubectl -n argocd get application <app> -o json | jq -r '.spec.sources[]?.repoURL'
```

Expected:

- Twinbox repo references point to Forgejo;
- third-party Helm repo references remain unchanged.

### Image updater check

Verify portal no longer has Twinbox-owned image-updater annotations:

```bash
rg -n "argocd-image-updater.*portal|twinbox-portal" gitops/apps/twinbox-portal.yaml
```

Expected:

- no image-updater annotations for `twinbox-portal`;
- the application still deploys through its kustomization image tag.

## Rollback and recovery

### Disable Forgejo startup

Set:

```dotenv
TWINBOX_ENABLE_FORGEJO=false
```

Then:

```bash
cd /opt/twinbox
sudo -n docker compose up -d
```

### Return Argo CD to GitHub

Set:

```dotenv
TWINBOX_GIT_REPO_URL=https://github.com/harrywesterman/Twinbox.git
TWINBOX_GIT_TARGET_REVISION=main
```

Then re-apply affected Argo CD Applications through the existing manager scripts.

### Preserve Forgejo data

Do not delete `/opt/twinbox/forgejo` during rollback unless explicitly decommissioning Forgejo.

Back up:

```bash
sudo -n tar -C /opt/twinbox -czf /opt/twinbox/bootstrap/forgejo-backup.tgz forgejo
```

Later backup integration can copy this into SeaweedFS, but that is outside v1.

## Acceptance criteria

- A fresh Management VM starts the existing manager stack and Forgejo.
- Forgejo bootstrap is idempotent and does not overwrite local `main`.
- Forgejo contains `twinbox/Twinbox` with `main` from GitHub on first bootstrap.
- Operators can switch `TWINBOX_GIT_REPO_URL` from GitHub to Forgejo without editing every app manifest.
- A promotion helper can push a review branch from GitHub upstream into Forgejo.
- Argo CD Applications can render with Forgejo as their Twinbox repo source.
- Twinbox-owned images are no longer advanced by Argo CD Image Updater outside Git review.
- Forgejo failure does not prevent manager-web/API/worker from starting.
- A documented fallback to GitHub exists and works.

## Later v2 ideas

Do not implement these in v1:

- Forgejo Actions runner.
- Local OCI registry.
- Release bundle manifests.
- Image signing and digest pinning.
- GHCR/local registry dual-push.
- Talos registry mirror/fallback config.
- Automated mass migration of all existing Argo CD Applications.

These deserve a separate design because they change the image supply chain and the failure model of the Management VM.
