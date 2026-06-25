# opkssh SSH Access Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace static SSH credentials for the Twinbox Management VM and Bastion with short-lived, Authentik-MFA-gated certificates issued by opkssh, fully integrated into Termix.

**Architecture:** Authentik acts as the OIDC IdP. opkssh wraps the Authentik `id_token` in an OpenPubkey PK Token and mints an SSH user certificate. The Termix pod runs `opkssh login` in its container, and target hosts (Management VM + Bastion) run `opkssh verify` via sshd's `AuthorizedKeysCommand`. Group membership in Authentik's `admins` group maps to Linux principals via `/etc/opk/auth_id`. Existing static keys/passwords remain on the hosts as break-glass but are removed from Termix after validation.

**Tech Stack:** Bash, Ansible, Authentik OIDC API, opkssh (Go binary), OpenBao, Kubernetes ExternalSecrets, Argo CD, Termix (Node/TypeScript), NetBird, OpenSSH.

---

## Phase 0: Foundation — Authentik app, secrets, and Termix config

### Task 0.1: Create shared Authentik OIDC helper functions

**Files:**
- Create: `scripts/manager/setup-opkssh-authentik.sh`
- Modify: `scripts/manager/setup-termix-authentik.sh`
- Test: `tests/scripts/test_setup_termix_authentik.py` (extend existing)

**Step 1: Read `scripts/manager/setup-termix-authentik.sh`** to understand existing helper functions and Authentik API patterns.

Run: `read scripts/manager/setup-termix-authentik.sh`

**Step 2: Extract generic OIDC application creation helpers from `setup-termix-authentik.sh`** into `scripts/manager/authentik-oauth-app.sh`.

Create `scripts/manager/authentik-oauth-app.sh` with these functions:
- `authentik_ensure_authorization_flow()`
- `authentik_ensure_invalidation_flow()`
- `authentik_ensure_signing_key()`
- `authentik_ensure_scope_mapping(name, scope_name, description, expression)`
- `authentik_create_or_update_application(name, slug, provider_id, group_ids)`
- `authentik_create_or_update_oauth_provider(payload)`
- `authentik_ensure_group_binding(application_uuid, group_id)`
- `authentik_generate_client_credentials()`

The file must be sourceable by other scripts and must not execute anything when sourced.

```bash
#!/usr/bin/env bash
# scripts/manager/authentik-oauth-app.sh
# Shared helpers for creating Authentik OAuth2 applications.
set -euo pipefail

authentik_ensure_authorization_flow() {
  # ... (extracted from setup-termix-authentik.sh)
}
# etc.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This script is a library; source it from another script." >&2
  exit 1
fi
```

**Step 3: Refactor `setup-termix-authentik.sh` to source `authentik-oauth-app.sh`.**

Replace the inline helper definitions with:
```bash
# shellcheck source=scripts/manager/authentik-oauth-app.sh
source "${WORKSPACE_ROOT}/scripts/manager/authentik-oauth-app.sh"
```

Keep Termix-specific logic (redirect URI, secret payload shape, property mappings that append `admins` for superusers) in `setup-termix-authentik.sh`.

**Step 4: Validate syntax.**

Run: `bash -n scripts/manager/authentik-oauth-app.sh && bash -n scripts/manager/setup-termix-authentik.sh`
Expected: No output (success).

**Step 5: Run existing tests.**

Run: `python3 -m pytest -q tests/scripts/test_setup_termix_authentik.py`
Expected: PASS.

**Step 6: Commit.**

```bash
git add scripts/manager/authentik-oauth-app.sh scripts/manager/setup-termix-authentik.sh tests/scripts/test_setup_termix_authentik.py
git commit -m "refactor: extract Authentik OAuth2 helpers for reuse"
```

---

### Task 0.2: Create `setup-opkssh-authentik.sh`

**Files:**
- Create: `scripts/manager/setup-opkssh-authentik.sh`
- Modify: `scripts/manager/setup-termix-authentik.sh` (add shared credential/secret helpers)
- Test: `tests/scripts/test_setup_opkssh_authentik.py` (new)

**Step 1: Write the script to create the `opkssh` Authentik application.**

Create `scripts/manager/setup-opkssh-authentik.sh`:

```bash
#!/usr/bin/env bash
# scripts/manager/setup-opkssh-authentik.sh
# Creates the Authentik OAuth2 application for opkssh and stores secrets in OpenBao.
set -euo pipefail

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT must be set}"

# shellcheck source=scripts/manager/authentik-oauth-app.sh
source "${WORKSPACE_ROOT}/scripts/manager/authentik-oauth-app.sh"
# shellcheck source=scripts/manager/secrets-lib.sh
source "${WORKSPACE_ROOT}/scripts/manager/secrets-lib.sh" || true

setup_opkssh_authentik() {
  local cluster_id public_zone_name
  cluster_id="${TWINBOX_CLUSTER_ID:-$(jq -r '.cluster_id // empty' /opt/twinbox/bootstrap/secrets/global/netbird-bastion-*.json 2>/dev/null | head -n1)}"
  public_zone_name="${TWINBOX_PUBLIC_ZONE_NAME:-$(jq -r '.zone // empty' /opt/twinbox/bootstrap/secrets/global/twinbox-zone.json 2>/dev/null)}"

  if [[ -z "$public_zone_name" ]]; then
    echo "ERROR: TWINBOX_PUBLIC_ZONE_NAME not set and no twinbox-zone.json found" >&2
    return 1
  fi

  local issuer_url redirect_uri
  issuer_url="https://authentik.${public_zone_name}/application/o/opkssh/"
  redirect_uri="https://termix.${public_zone_name}/host/opkssh-callback"

  # Reuse existing flows and signing key from Termix or create new ones.
  local authorization_flow_id invalidation_flow_id signing_key_id
  authorization_flow_id="$(authentik_ensure_authorization_flow)"
  invalidation_flow_id="$(authentik_ensure_invalidation_flow)"
  signing_key_id="$(authentik_ensure_signing_key)"

  # Scope mapping for groups claim.
  local groups_mapping_id
  groups_mapping_id="$(authentik_ensure_scope_mapping \
    "OPKSSH groups" \
    "groups" \
    "Expose Authentik group membership for opkssh" \
    'groups = [group.name for group in request.user.ak_groups.all()]
return {"groups": groups}')"

  local client_id client_secret
  client_id="OPKSSH_$(openssl rand -hex 16)"
  client_secret="$(openssl rand -hex 32)"

  local property_mapping_ids_json
  property_mapping_ids_json="$(jq -n --arg groups "$groups_mapping_id" '[$groups]')"

  local provider_payload
  provider_payload="$(jq -n \
    --arg name "OPKSSH" \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$redirect_uri" \
    --argjson property_mappings "$property_mapping_ids_json" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      redirect_uris: [{matching_mode: "strict", url: $redirect_uri}],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      grant_types: ["authorization_code"],
      issuer_mode: "per_provider",
      sub_mode: "hashed_user_id"
    }')"

  local provider_id
  provider_id="$(authentik_create_or_update_oauth_provider "$provider_payload")"

  local admins_group_id application_uuid
  admins_group_id="$(authentik_find_group_id "admins")"
  application_uuid="$(authentik_create_or_update_application "opkssh" "opkssh" "$provider_id" "[$admins_group_id]")"

  # Store secrets in OpenBao.
  local opkssh_secret_payload opkssh_secret_file
  opkssh_secret_file="$(mktemp)"
  opkssh_secret_payload="$(jq -n \
    --arg client_id "$client_id" \
    --arg client_secret "$client_secret" \
    --arg issuer_url "$issuer_url" \
    --arg redirect_uri "$redirect_uri" \
    '{
      OIDC_CLIENT_ID: $client_id,
      OIDC_CLIENT_SECRET: $client_secret,
      OIDC_ISSUER_URL: $issuer_url,
      OIDC_REDIRECT_URI: $redirect_uri
    }')"
  echo "$opkssh_secret_payload" >"$opkssh_secret_file"

  bash "${WORKSPACE_ROOT}/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "opkssh" \
    --json-file "$opkssh_secret_file" \
    --required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL,OIDC_REDIRECT_URI"
  rm -f "$opkssh_secret_file"

  echo "opkssh Authentik application created: ${issuer_url}"
  echo "Application UUID: ${application_uuid}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_opkssh_authentik "$@"
fi
```

**Step 2: Make the script executable.**

Run: `chmod +x scripts/manager/setup-opkssh-authentik.sh`

**Step 3: Validate syntax.**

Run: `bash -n scripts/manager/setup-opkssh-authentik.sh`
Expected: No output.

**Step 4: Write a unit test.**

Create `tests/scripts/test_setup_opkssh_authentik.py`:

```python
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]


class TestSetupOpksshAuthentik(unittest.TestCase):
    def test_script_syntax(self):
        script = WORKSPACE_ROOT / "scripts" / "manager" / "setup-opkssh-authentik.sh"
        result = subprocess.run(
            ["bash", "-n", str(script)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)

    def test_authentik_oauth_app_helper_syntax(self):
        helper = WORKSPACE_ROOT / "scripts" / "manager" / "authentik-oauth-app.sh"
        result = subprocess.run(
            ["bash", "-n", str(helper)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)


if __name__ == "__main__":
    unittest.main()
```

**Step 5: Run the test.**

Run: `python3 -m pytest -q tests/scripts/test_setup_opkssh_authentik.py`
Expected: PASS.

**Step 6: Commit.**

```bash
git add scripts/manager/setup-opkssh-authentik.sh tests/scripts/test_setup_opkssh_authentik.py
git commit -m "feat: add setup-opkssh-authentik script to create Authentik OAuth2 app"
```

---

### Task 0.3: Render opkssh client config in the Termix container

**Files:**
- Create: `gitops/platform-apps/termix/opkssh-config-template.yaml`
- Modify: `gitops/platform-apps/termix/externalsecret.yaml`
- Modify: `gitops/platform-apps/termix/deployment.yaml`
- Test: `gitops/platform-apps/termix/test/render-opkssh-config.mjs` (new) or extend existing tests

**Step 1: Add opkssh secret fields to `externalsecret.yaml`.**

Modify `gitops/platform-apps/termix/externalsecret.yaml` to also pull `twinbox/global/opkssh` secrets and write them to `opkssh-config`:

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: termix-opkssh-config
  namespace: termix
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao-backend
  target:
    name: termix-opkssh-config
    creationPolicy: Owner
    template:
      type: Opaque
      data:
        config.yml: |
          default_provider: authentik
          providers:
            - alias: authentik
              issuer: {{ .issuer_url }}
              client_id: {{ .client_id }}
              client_secret: {{ .client_secret }}
              scopes: openid profile email groups
              access_type: offline
              prompt: consent
              redirect_uris:
                - http://localhost:3000/login-callback
                - http://localhost:10001/login-callback
                - http://localhost:11110/login-callback
              send_access_token: false
  data:
    - secretKey: issuer_url
      remoteRef:
        key: twinbox/global/opkssh
        property: OIDC_ISSUER_URL
    - secretKey: client_id
      remoteRef:
        key: twinbox/global/opkssh
        property: OIDC_CLIENT_ID
    - secretKey: client_secret
      remoteRef:
        key: twinbox/global/opkssh
        property: OIDC_CLIENT_SECRET
```

**Step 2: Mount the secret in `deployment.yaml`.**

Add to the `termix` container `volumeMounts`:
```yaml
- name: opkssh-config
  mountPath: /app/data/.opk
  readOnly: true
```

Add to the pod `volumes`:
```yaml
- name: opkssh-config
  secret:
    secretName: termix-opkssh-config
    items:
      - key: config.yml
        path: config.yml
```

**Step 3: Update `kustomization.yaml` if needed.**

Verify `gitops/platform-apps/termix/kustomization.yaml` lists `externalsecret.yaml` (it already does). No change needed.

**Step 4: Validate YAML and Kustomize build.**

Run: `kubectl apply --dry-run=client -f gitops/platform-apps/termix/externalsecret.yaml`
Expected: `externalsecret.external-secrets.io/termix-opkssh-config created (dry run)`.

Run: `kubectl kustomize gitops/platform-apps/termix/ > /tmp/termix-kustomize.yaml`
Expected: Renders without error.

**Step 5: Commit.**

```bash
git add gitops/platform-apps/termix/externalsecret.yaml gitops/platform-apps/termix/deployment.yaml
git commit -m "feat(termix): mount opkssh client config from OpenBao"
```

---

### Task 0.4: Update install-browser-ssh step to call setup-opkssh-authentik

**Files:**
- Modify: `categories/talos-cluster/steps/install-browser-ssh/run.sh`
- Modify: `categories/talos-cluster/steps/install-browser-ssh/step.yaml`
- Test: `tests/scripts/test_manager_scripts_args.py` (extend existing; validate new run.sh args)

**Step 1: Update `run.sh`.**

At the top of `categories/talos-cluster/steps/install-browser-ssh/run.sh`, add:
```bash
# Ensure opkssh Authentik application exists before configuring Termix.
bash "${WORKSPACE_ROOT}/scripts/manager/setup-opkssh-authentik.sh"
```

**Step 2: Update `step.yaml` summary/explanation.**

Change `summary` to mention opkssh, e.g.:
> "Deploys Termix browser SSH and provisions the opkssh Authentik application for MFA-gated SSH certificates to the Management VM and bastion."

**Step 3: Validate syntax.**

Run: `bash -n categories/talos-cluster/steps/install-browser-ssh/run.sh`
Expected: No output.

**Step 4: Commit.**

```bash
git add categories/talos-cluster/steps/install-browser-ssh/run.sh categories/talos-cluster/steps/install-browser-ssh/step.yaml
git commit -m "feat(browser-ssh): create opkssh Authentik app before configuring Termix"
```

---

## Phase 1: Management VM opkssh support

### Task 1.1: Create Ansible task file to install opkssh on the management VM

**Files:**
- Create: `ansible/tasks/install-opkssh.yml`
- Modify: `ansible/management-vm-maintenance.yml`
- Test: `tests/ansible/test_management_vm_maintenance.py` (new or extend existing)

**Step 1: Create `ansible/tasks/install-opkssh.yml`.**

```yaml
---
- name: Ensure opkssh group exists
  ansible.builtin.group:
    name: opksshuser
    system: true
    state: present

- name: Ensure opkssh user exists
  ansible.builtin.user:
    name: opksshuser
    group: opksshuser
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/opksshuser
    createhome: true
    state: present

- name: Download pinned opkssh binary
  ansible.builtin.get_url:
    url: "https://github.com/openpubkey/opkssh/releases/download/v0.14.0/opkssh-linux-amd64"
    dest: /usr/local/bin/opkssh
    mode: "0755"
    owner: root
    group: root
    checksum: "sha256:PLACEHOLDER_REPLACE_WITH_REAL_HASH"
  notify: Restart ssh

- name: Ensure /etc/opk directory exists
  ansible.builtin.file:
    path: /etc/opk
    state: directory
    owner: root
    group: opksshuser
    mode: "0750"

- name: Render /etc/opk/providers
  ansible.builtin.template:
    src: opk_providers.j2
    dest: /etc/opk/providers
    owner: root
    group: opksshuser
    mode: "0640"
  notify: Restart ssh

- name: Render /etc/opk/auth_id
  ansible.builtin.template:
    src: opk_auth_id_mgmt.j2
    dest: /etc/opk/auth_id
    owner: root
    group: opksshuser
    mode: "0640"
  notify: Restart ssh

- name: Render opkssh sshd drop-in
  ansible.builtin.template:
    src: 60-opk-ssh.conf.j2
    dest: /etc/ssh/sshd_config.d/60-opk-ssh.conf
    owner: root
    group: root
    mode: "0644"
  notify: Restart ssh

- name: Run opkssh verify smoke test
  ansible.builtin.command:
    cmd: /usr/local/bin/opkssh verify --help
  changed_when: false
  register: opkssh_verify_help
  failed_when: opkssh_verify_help.rc != 0

- name: Run opkssh audit
  ansible.builtin.command:
    cmd: /usr/local/bin/opkssh audit
  changed_when: false
  register: opkssh_audit
  failed_when: opkssh_audit.rc != 0
```

**Step 2: Create templates.**

Create `ansible/templates/opk_providers.j2`:
```
{{ opkssh_issuer_url }} {{ opkssh_client_id }} 16h
```

Create `ansible/templates/opk_auth_id_mgmt.j2`:
```
# Allow Authentik admins group to SSH as twinbox
twinbox oidc:groups:admins {{ opkssh_issuer_url }}
```

Create `ansible/templates/60-opk-ssh.conf.j2`:
```
# opkssh integration
AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
AuthorizedKeysCommandUser opksshuser
```

**Step 3: Update `ansible/management-vm-maintenance.yml`.**

Add variables under `vars:`:
```yaml
opkssh_version: "0.14.0"
opkssh_binary_checksum: "sha256:PLACEHOLDER_REPLACE_WITH_REAL_HASH"
opkssh_issuer_url: "{{ lookup('env', 'OPKSSH_ISSUER_URL') | default('https://authentik.' + lookup('env', 'TWINBOX_PUBLIC_ZONE_NAME') | default('example.com', true) + '/application/o/opkssh/', true) }}"
opkssh_client_id: "{{ lookup('env', 'OPKSSH_CLIENT_ID') | default('', true) }}"
```

Add a task near the end (after the sshd drop-in task):
```yaml
- name: Install opkssh for Authentik-gated SSH
  ansible.builtin.import_tasks: tasks/install-opkssh.yml
  when: opkssh_client_id | length > 0
```

**Step 4: Replace the existing sshd password-auth drop-in with the additive Phase 1 version.**

In `ansible/management-vm-maintenance.yml`, the existing task at lines 108-120 should be updated to keep password auth enabled in Phase 1:

```yaml
- name: Configure SSH for opkssh Phase 1 (cert + password fallback)
  ansible.builtin.copy:
    dest: /etc/ssh/sshd_config.d/99-twinbox-management.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      PubkeyAuthentication yes
      X11Forwarding no
      AllowAgentForwarding yes
      AuthenticationMethods publickey password
  notify: Restart ssh
```

**Step 5: Validate syntax.**

Run: `ansible-playbook --syntax-check -i localhost, ansible/management-vm-maintenance.yml`
Expected: No syntax errors.

**Step 6: Commit.**

```bash
git add ansible/tasks/install-opkssh.yml ansible/templates/opk_providers.j2 ansible/templates/opk_auth_id_mgmt.j2 ansible/templates/60-opk-ssh.conf.j2 ansible/management-vm-maintenance.yml
git commit -m "feat(ansible): install opkssh on management VM with admins group mapping"
```

---

### Task 1.2: Update `setup-termix.sh` to create OPKSSH host entries

**Files:**
- Modify: `scripts/manager/setup-termix.sh`
- Test: `tests/scripts/test_setup_termix.py` (new or extend existing)

**Step 1: Add new helper functions.**

Add to `scripts/manager/setup-termix.sh`:

```bash
ensure_termix_opkssh_host() {
  local host_name="$1"
  local host_ip="$2"
  local username="$3"
  local hosts_payload="$4"

  local host_payload host_id
  host_payload="$(jq -n \
    --arg name "$host_name" \
    --arg ip "$host_ip" \
    --arg username "$username" \
    '{
      connectionType: "ssh",
      name: $name,
      ip: $ip,
      port: 22,
      username: $username,
      authType: "OPKSSH",
      enableTerminal: true,
      showTerminalInSidebar: true,
      enableSsh: true
    }')"

  host_id="$(jq -r \
    --arg host_name "$host_name" \
    '.hosts[]? | select((.name // "") == $host_name) | .id // empty' <<<"$hosts_payload" | head -n1)"

  if [[ -n "$host_id" ]]; then
    termix_api_request PUT "/host/db/host/${host_id}" "$host_payload" >/dev/null
    printf '%s\n' "$host_id"
    return 0
  fi

  host_id="$(termix_api_request POST "/host/db/host" "$host_payload" | jq -r '.id // empty')"
  printf '%s\n' "$host_id"
}

delete_termix_credential_by_name() {
  local credential_name="$1"
  local credentials_payload
  credentials_payload="$(termix_api_request GET "/credentials")"
  local credential_id
  credential_id="$(jq -r \
    --arg name "$credential_name" \
    '.credentials[]? | select((.name // "") == $name) | .id // empty' <<<"$credentials_payload" | head -n1)"
  if [[ -n "$credential_id" ]]; then
    termix_api_request DELETE "/credentials/${credential_id}" >/dev/null
    log "Deleted Termix credential: ${credential_name}"
  fi
}
```

**Step 2: Replace the host/credential creation block.**

Find the block in `scripts/manager/setup-termix.sh` at lines 644-666:
```bash
log "Ensuring Termix credentials exist"
credentials_payload="$(termix_api_request GET "/credentials")"
mgmt_credential_id="$(...)
bastion_credential_id="$(...)"

log "Ensuring Termix SSH hosts exist"
hosts_payload="$(termix_api_request GET "/host/db/host")"
mgmt_host_id="$(ensure_termix_host "Management VM" ... "credential")"
bastion_host_id="$(ensure_termix_host "Bastion VM" ... "credential")"
```

Replace with:
```bash
log "Ensuring Termix OPKSSH hosts exist"
hosts_payload="$(termix_api_request GET "/host/db/host")"
mgmt_host_id="$(ensure_termix_opkssh_host "Management VM" "$mgmt_netbird_ip" "$MGMT_VM_USER" "$hosts_payload")"
bastion_host_id="$(ensure_termix_opkssh_host "Bastion VM" "$bastion_netbird_ip" "root" "$hosts_payload")"

# Phase 2+ : remove legacy static credentials from Termix.
# In Phase 1 these lines are commented out; enable after opkssh is validated.
# delete_termix_credential_by_name "Management VM Password"
# delete_termix_credential_by_name "Bastion VM SSH Key"
```

**Step 3: Validate syntax.**

Run: `bash -n scripts/manager/setup-termix.sh`
Expected: No output.

**Step 4: Commit.**

```bash
git add scripts/manager/setup-termix.sh
git commit -m "feat(termix): add OPKSSH host helpers and switch default hosts to OPKSSH"
```

---

### Task 1.3: Create `install-opkssh` wizard step

**Files:**
- Create: `categories/talos-cluster/steps/install-opkssh/step.yaml`
- Create: `categories/talos-cluster/steps/install-opkssh/run.sh`
- Modify: `manager-web/src/journey.js` (add step to journey order)
- Test: `manager-web/test/journey-state.test.mjs` (extend existing)

**Step 1: Create `step.yaml`.**

```yaml
id: install-opkssh
title: Install opkssh SSH Certificate Auth
type: action
journey_stage: setup
summary: Configure opkssh on the Management VM and bastion for Authentik-MFA-gated SSH certificates.
explanation: >
  This step installs opkssh on the Management VM and, after verification, on the NetBird bastion.
  It writes the Authentik OAuth2 provider configuration and group-to-principal mapping so that
  users in the 'admins' group receive short-lived SSH certificates via Termix.
side_help: >
  Requires the opkssh Authentik application created by the browser-ssh step.
  The Management VM must be reachable via SSH and NetBird.
inputs: []
secrets:
  files:
    NETBIRD_BASTION_SECRET:
      scope: global
      item: netbird-bastion
      format: json
runner:
  kind: script
  script: categories/talos-cluster/steps/install-opkssh/run.sh
```

**Step 2: Create `run.sh`.**

```bash
#!/usr/bin/env bash
# categories/talos-cluster/steps/install-opkssh/run.sh
set -euo pipefail

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT must be set}"
: "${STEP_SECRETS_DIR:?STEP_SECRETS_DIR must be set}"

# shellcheck source=scripts/manager/logging.sh
source "${WORKSPACE_ROOT}/scripts/manager/logging.sh"

cluster_id="${TWINBOX_CLUSTER_ID:?TWINBOX_CLUSTER_ID must be set}"
cluster_slug="${TWINBOX_CLUSTER_SLUG:?TWINBOX_CLUSTER_SLUG must be set}"

netbird_bastion_secret="${STEP_SECRETS_DIR}/NETBIRD_BASTION_SECRET"
bastion_ip="$(jq -r '.NETBIRD_IP // empty' "$netbird_bastion_secret")"
bastion_ssh_private_key="$(jq -r '.SSH_PRIVATE_KEY // empty' "$netbird_bastion_secret")"

mgmt_vm_ip="${MANAGEMENT_VM_IP:-$("${WORKSPACE_ROOT}/scripts/manager/management-ip.sh" resolve_management_vm_ip)}"
mgmt_vm_user="${MGMT_VM_USER:-twinbox}"

install_opkssh_on_host() {
  local target_host="$1"
  local target_user="$2"
  local ssh_key_file="${3:-}"

  local ssh_args=("-o" "StrictHostKeyChecking=accept-new" "-o" "UserKnownHostsFile=/dev/null" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10")
  if [[ -n "$ssh_key_file" ]]; then
    ssh_args+=("-i" "$ssh_key_file")
  fi

  local opkssh_version="0.14.0"
  local opkssh_checksum="sha256:PLACEHOLDER_REPLACE_WITH_REAL_HASH"

  ssh "${ssh_args[@]}" "${target_user}@${target_host}" bash -s <<REMOTE
set -euo pipefail

OPKSSH_VERSION="${opkssh_version}"
OPKSSH_SHA256="${opkssh_checksum#sha256:}"

if [[ -x /usr/local/bin/opkssh ]]; then
  echo "opkssh already installed"
else
  echo "Installing opkssh v\${OPKSSH_VERSION}..."
  curl -fsSL "https://github.com/openpubkey/opkssh/releases/download/v\${OPKSSH_VERSION}/opkssh-linux-amd64" -o /tmp/opkssh
  echo "\${OPKSSH_SHA256}  /tmp/opkssh" | sha256sum -c -
  install -o root -g root -m 0755 /tmp/opkssh /usr/local/bin/opkssh
  rm -f /tmp/opkssh
fi

if ! id -u opksshuser >/dev/null 2>&1; then
  groupadd -r opksshuser || true
  useradd -r -g opksshuser -s /usr/sbin/nologin -d /var/lib/opksshuser -m opksshuser || true
fi

mkdir -p /etc/opk
chown root:opksshuser /etc/opk
chmod 0750 /etc/opk

cat > /etc/opk/providers <<'PROVIDERS'
${OPKSSH_ISSUER_URL:?} ${OPKSSH_CLIENT_ID:?} 16h
PROVIDERS
chown root:opksshuser /etc/opk/providers
chmod 0640 /etc/opk/providers

cat > /etc/opk/auth_id <<'AUTHID'
${target_user} oidc:groups:admins ${OPKSSH_ISSUER_URL:?}
AUTHID
chown root:opksshuser /etc/opk/auth_id
chmod 0640 /etc/opk/auth_id

cat > /etc/ssh/sshd_config.d/60-opk-ssh.conf <<'SSHD'
AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
AuthorizedKeysCommandUser opksshuser
SSHD
chmod 0644 /etc/ssh/sshd_config.d/60-opk-ssh.conf

if systemctl is-active sshd >/dev/null 2>&1; then
  systemctl restart sshd || true
fi

/usr/local/bin/opkssh verify --help >/dev/null
/usr/local/bin/opkssh audit
REMOTE
}

log "Installing opkssh on Management VM (${mgmt_vm_ip})"
install_opkssh_on_host "$mgmt_vm_ip" "$mgmt_vm_user"

log "Installing opkssh on Bastion (${bastion_ip})"
if [[ -n "$bastion_ssh_private_key" ]]; then
  key_file="$(mktemp)"
  printf '%s\n' "$bastion_ssh_private_key" >"$key_file"
  chmod 600 "$key_file"
  install_opkssh_on_host "$bastion_ip" "root" "$key_file"
  rm -f "$key_file"
else
  log "WARNING: no bastion SSH private key found; skipping bastion opkssh install"
fi

log "opkssh installation complete"
```

**Step 3: Make executable and validate syntax.**

Run:
```bash
chmod +x categories/talos-cluster/steps/install-opkssh/run.sh
bash -n categories/talos-cluster/steps/install-opkssh/run.sh
```
Expected: No output.

**Step 4: Add to journey.**

Modify `manager-web/src/journey.js` to add `install-opkssh` immediately after `install-browser-ssh`.

**Step 5: Commit.**

```bash
git add categories/talos-cluster/steps/install-opkssh/step.yaml categories/talos-cluster/steps/install-opkssh/run.sh manager-web/src/journey.js manager-web/test/journey-state.test.mjs
git commit -m "feat(steps): add install-opkssh wizard step"
```

---

### Task 1.4: Update journey ordering and docs for Phase 1

**Files:**
- Modify: `categories/talos-cluster/README.md`
- Modify: `docs/talos-integration.md`
- Modify: `docs/getting-started.md`
- Test: `node --test manager-web/test/*.mjs`

**Step 1: Update `categories/talos-cluster/README.md`.**

Add `install-opkssh` to the step table after `install-browser-ssh`.

**Step 2: Update `docs/talos-integration.md` step 32.**

Change step 32 from:
> "`install-browser-ssh` deploys Termix browser SSH access to the Management VM and bastion for admins."

To:
> "`install-browser-ssh` deploys Termix browser SSH access and the opkssh Authentik OAuth2 application. `install-opkssh` installs opkssh on the Management VM and bastion so admins authenticate with Authentik + MFA."

**Step 3: Run web tests.**

Run: `node --test manager-web/test/*.mjs`
Expected: PASS.

**Step 4: Commit.**

```bash
git add categories/talos-cluster/README.md docs/talos-integration.md docs/getting-started.md
git commit -m "docs: add install-opkssh to journey and talos integration docs"
```

---

## Phase 2: Remove static Termix credentials for Management VM

### Task 2.1: Enable deletion of legacy Termix credentials

**Files:**
- Modify: `scripts/manager/setup-termix.sh`
- Test: `bash -n scripts/manager/setup-termix.sh`

**Step 1: Uncomment the delete calls for Phase 2.**

Change:
```bash
# delete_termix_credential_by_name "Management VM Password"
# delete_termix_credential_by_name "Bastion VM SSH Key"
```

To:
```bash
delete_termix_credential_by_name "Management VM Password"
# delete_termix_credential_by_name "Bastion VM SSH Key"  # Phase 3
```

**Step 2: Validate and commit.**

Run: `bash -n scripts/manager/setup-termix.sh`

```bash
git add scripts/manager/setup-termix.sh
git commit -m "feat(termix): remove Management VM Password credential (Phase 2)"
```

---

### Task 2.2: Document break-glass Management VM password

**Files:**
- Create: `docs/operations.md`
- Modify: `AGENTS.md`

**Step 1: Create `docs/operations.md`.**

Include:
- Location of the break-glass management VM password: `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`.
- How to use it: `ssh twinbox@<mgmt-vm-netbird-ip>` and enter the password.
- How to rotate it.
- Warning that this is a break-glass path only.

**Step 2: Update `AGENTS.md` "Debug" section.**

Add a note that normal access is via opkssh through Termix; break-glass password is documented in `docs/operations.md`.

**Step 3: Commit.**

```bash
git add docs/operations.md AGENTS.md
git commit -m "docs: add break-glass SSH operations guide"
```

---

## Phase 3: Bastion opkssh support and removal of static key

### Task 3.1: Update bastion provisioning to install opkssh via cloud-init

**Files:**
- Modify: `infra/opentofu/netbird/cloud-init/netbird.yaml.tftpl`
- Modify: `infra/opentofu/netbird/main.tf` (keep `ssh_keys` for now)
- Test: `tofu validate` in `infra/opentofu/netbird/`

**Step 1: Add opkssh install to cloud-init template.**

In the `runcmd:` section of `infra/opentofu/netbird/cloud-init/netbird.yaml.tftpl`, add:
```yaml
  - |
    # Install opkssh
    curl -fsSL https://github.com/openpubkey/opkssh/releases/download/v0.14.0/opkssh-linux-amd64 -o /tmp/opkssh
    echo "PLACEHOLDER_HASH  /tmp/opkssh" | sha256sum -c -
    install -o root -g root -m 0755 /tmp/opkssh /usr/local/bin/opkssh
    rm -f /tmp/opkssh
    groupadd -r opksshuser || true
    useradd -r -g opksshuser -s /usr/sbin/nologin -d /var/lib/opksshuser -m opksshuser || true
    mkdir -p /etc/opk
    cat > /etc/opk/providers <<EOF
    ${opkssh_issuer_url} ${opkssh_client_id} 16h
    EOF
    cat > /etc/opk/auth_id <<EOF
    root oidc:groups:admins ${opkssh_issuer_url}
    EOF
    chown -R root:opksshuser /etc/opk
    chmod 0750 /etc/opk
    chmod 0640 /etc/opk/providers /etc/opk/auth_id
    cat > /etc/ssh/sshd_config.d/60-opk-ssh.conf <<EOF
    AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
    AuthorizedKeysCommandUser opksshuser
    EOF
    systemctl restart sshd || true
    /usr/local/bin/opkssh audit
```

Add template variables `opkssh_issuer_url` and `opkssh_client_id` to the `user_data` block in `infra/opentofu/netbird/main.tf`.

**Step 2: Validate OpenTofu.**

Run: `cd infra/opentofu/netbird && tofu init -no-color -input=false && tofu validate`
Expected: Success.

**Step 3: Commit.**

```bash
git add infra/opentofu/netbird/cloud-init/netbird.yaml.tftpl infra/opentofu/netbird/main.tf
git commit -m "feat(bastion): install opkssh via cloud-init"
```

---

### Task 3.2: Remove static bastion credential from Termix

**Files:**
- Modify: `scripts/manager/setup-termix.sh`
- Test: `bash -n scripts/manager/setup-termix.sh`

**Step 1: Uncomment the bastion delete call.**

Change:
```bash
# delete_termix_credential_by_name "Bastion VM SSH Key"  # Phase 3
```

To:
```bash
delete_termix_credential_by_name "Bastion VM SSH Key"
```

**Step 2: Validate and commit.**

```bash
git add scripts/manager/setup-termix.sh
git commit -m "feat(termix): remove Bastion VM SSH Key credential (Phase 3)"
```

---

### Task 3.3: Remove Hetzner SSH key and field from secret (optional, final Phase 3 cleanup)

**Files:**
- Modify: `infra/opentofu/netbird/main.tf`
- Modify: `categories/talos-cluster/steps/provision-netbird-bastion/run.sh`
- Test: `tofu validate`

**Step 1: Remove `ssh_keys` from Hetzner server resource.**

In `infra/opentofu/netbird/main.tf`, remove `ssh_keys = [hcloud_ssh_key.default.id]` or comment it out.

**Step 2: Update `provision-netbird-bastion/run.sh` to not write `SSH_PRIVATE_KEY` to the secret.**

Keep generating the key in Phase 1/2 but skip writing it after Phase 3.

**Step 3: Commit only after Phase 3 has been stable for ≥7 days.**

```bash
git add infra/opentofu/netbird/main.tf categories/talos-cluster/steps/provision-netbird-bastion/run.sh
git commit -m "feat(bastion): remove static Hetzner SSH key after opkssh validation"
```

---

## Phase 4: Documentation and verification

### Task 4.1: Create Termix and SSH access docs

**Files:**
- Create: `docs/termix.md`
- Create: `docs/ssh-access.md`
- Modify: `docs/netbird.md`
- Test: `make lint && make format-check`

**Step 1: Write `docs/termix.md`.**

- What Termix is in Twinbox.
- How to reach it.
- OPKSSH host entries for Management VM and Bastion.
- Troubleshooting (cert expired, MFA not completed, groups claim missing).

**Step 2: Write `docs/ssh-access.md`.**

- NetBird prerequisite.
- `opkssh login` from a laptop.
- `~/.ssh/config` snippet.
- Direct SSH examples.

**Step 3: Trim Termix section from `docs/netbird.md`.**

Replace with a link to `docs/termix.md`.

**Step 4: Commit.**

```bash
git add docs/termix.md docs/ssh-access.md docs/netbird.md
git commit -m "docs: add Termix and opkssh SSH access guides"
```

---

### Task 4.2: Add integration and unit tests

**Files:**
- Create: `tests/scripts/test_opkssh_install.py`
- Create: `tests/scripts/test_opkssh_auth_id.py`
- Create: `tests/integration/test_ssh_opkssh_e2e.py`
- Modify: `tests/scripts/test_manager_scripts_args.py` (extend if it validates step run.sh)

**Step 1: Unit test for `auth_id` parsing.**

Create `tests/scripts/test_opkssh_auth_id.py` that validates the `auth_id` line format using regex:

```python
import re
import unittest

AUTH_ID_RE = re.compile(r"^(\S+)\s+(oidc:groups:\S+|\S+)\s+(https://\S+/)$")


class TestOpksshAuthId(unittest.TestCase):
    def test_mgmt_auth_id(self):
        line = "twinbox oidc:groups:admins https://authentik.example.com/application/o/opkssh/"
        self.assertTrue(AUTH_ID_RE.match(line))

    def test_bastion_auth_id(self):
        line = "root oidc:groups:admins https://authentik.example.com/application/o/opkssh/"
        self.assertTrue(AUTH_ID_RE.match(line))

    def test_invalid_missing_trailing_slash(self):
        line = "twinbox oidc:groups:admins https://authentik.example.com/application/o/opkssh"
        self.assertFalse(AUTH_ID_RE.match(line))


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Install test.**

Create `tests/scripts/test_opkssh_install.py` that runs `bash -n` on all new shell scripts and validates the opkssh binary URL format.

**Step 3: Integration test placeholder.**

Create `tests/integration/test_ssh_opkssh_e2e.py` with a `pytest.skip("Requires live Twinbox cluster")` guard and a docstring describing the manual test steps.

**Step 4: Run tests.**

Run: `python3 -m pytest -q tests/scripts/test_opkssh_auth_id.py tests/scripts/test_opkssh_install.py`
Expected: PASS.

Run: `python3 -m pytest -q tests`
Expected: All existing tests still pass.

**Step 5: Commit.**

```bash
git add tests/scripts/test_opkssh_auth_id.py tests/scripts/test_opkssh_install.py tests/integration/test_ssh_opkssh_e2e.py
git commit -m "test: add opkssh auth_id and install tests"
```

---

### Task 4.3: Final verification

**Files:**
- All modified files

**Step 1: Lint/format.**

Run: `make lint && make format-check`
Expected: No errors.

**Step 2: Shell syntax.**

Run:
```bash
bash -n scripts/manager/setup-opkssh-authentik.sh
bash -n scripts/manager/setup-termix.sh
bash -n scripts/manager/setup-termix-authentik.sh
bash -n categories/talos-cluster/steps/install-browser-ssh/run.sh
bash -n categories/talos-cluster/steps/install-opkssh/run.sh
```
Expected: No output.

**Step 3: Node tests.**

Run: `node --test manager-web/test/*.mjs`
Expected: PASS.

**Step 4: Python tests.**

Run: `python3 -m pytest -q tests`
Expected: PASS.

**Step 5: Kustomize build.**

Run: `kubectl kustomize gitops/platform-apps/termix/ > /tmp/termix-final.yaml`
Expected: Renders without error.

**Step 6: OpenTofu validate.**

Run: `cd infra/opentofu/netbird && tofu validate`
Expected: Success.

**Step 7: Commit any fixes.**

```bash
git commit -m "chore: final lint, test, and validation fixes for opkssh integration" -a || true
```

---

## Deployment checklist

- [ ] All commits pushed to `main`.
- [ ] GitHub Actions "Publish Docker Images" workflow succeeded for the Termix-related changes.
- [ ] Management VM refreshed via `sudo -n sh -lc 'cd /opt/twinbox && docker compose pull && docker compose up -d'`.
- [ ] Run `install-browser-ssh` step in the wizard to create the Authentik app.
- [ ] Run `install-opkssh` step to install opkssh on the Management VM and bastion.
- [ ] Verify Termix shows `Management VM` and `Bastion VM` with OPKSSH auth.
- [ ] Each admin completes one successful opkssh login via Termix.
- [ ] After 7 days: enable Phase 2 (remove mgmt password credential).
- [ ] After another 7 days: enable Phase 3 (remove bastion key credential and optionally Hetzner key).

---

## Rollback

If opkssh login fails and an admin is locked out:

1. Use the break-glass Management VM password from `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`.
2. For the bastion, use the ed25519 key from `/opt/twinbox/manager-data/ssh/netbird-<cluster-id>/id_ed25519`.
3. Re-run the previous `setup-termix.sh` to restore static credentials in Termix.
4. Remove `/etc/ssh/sshd_config.d/60-opk-ssh.conf` and restart sshd to disable opkssh.

Full rollback procedure is in `docs/operations.md`.
