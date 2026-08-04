# Nextcloud EuroOffice File Action Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep Collabora as the default Nextcloud office editor and expose a working **Open in EuroOffice** action in the Files menu on Nextcloud 34.

**Architecture:** Add a small local Nextcloud companion app rather than modifying EuroOffice's App Store files. Its Vite bundle uses `@nextcloud/files` to register the action with the supported API; a Files load listener injects it only into the Files UI. The Nextcloud bootstrap copies the built companion app to the persistent custom-apps directory and enables it after the EuroOffice connector.

**Tech Stack:** PHP Nextcloud app bootstrap, JavaScript ES modules, `@nextcloud/files`, Vite, Docker build, Bash installer, Python contract tests.

---

### Task 1: Lock the companion-app contract with a failing test

**Files:**
- Modify: `tests/test_nextcloud_eurooffice_gitops.py`

**Step 1: Write the failing test**

Add `test_nextcloud_bootstrap_installs_the_modern_eurooffice_file_action` asserting that the companion app metadata, Files event listener, modern `registerFileAction` source, worker-image build step, and bootstrap installation command all exist.

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest -q tests/test_nextcloud_eurooffice_gitops.py`

Expected: FAIL because the companion-app files and installation command do not exist.

### Task 2: Add the modern Nextcloud companion app

**Files:**
- Create: `categories/apps/steps/install-nextcloud/eurooffice-file-action/appinfo/info.xml`
- Create: `categories/apps/steps/install-nextcloud/eurooffice-file-action/lib/AppInfo/Application.php`
- Create: `categories/apps/steps/install-nextcloud/eurooffice-file-action/lib/Listener/LoadAdditionalListener.php`
- Create: `categories/apps/steps/install-nextcloud/eurooffice-file-action/src/main.js`
- Create: `categories/apps/steps/install-nextcloud/eurooffice-file-action/package.json`
- Create: `categories/apps/steps/install-nextcloud/eurooffice-file-action/package-lock.json`
- Create: `categories/apps/steps/install-nextcloud/eurooffice-file-action/vite.config.mjs`

**Step 1: Implement the app metadata and Files listener**

Use app id `twinbox_eurooffice_action`, require Nextcloud 34 and 35, register `LoadAdditionalScriptsEvent`, and load the Vite `main` module after the Files app.

**Step 2: Implement the action source**

Import `registerFileAction` and `Permission` from `@nextcloud/files`, `generateUrl` from `@nextcloud/router`, and `t` from `@nextcloud/l10n`. Register exactly one action with id `twinbox-eurooffice-open`, label **Open in EuroOffice**, and an `enabled` predicate requiring a single readable, supported office file. Its executor constructs the existing `/apps/eurooffice/{fileId}` URL with the encoded full file path and opens it in a new tab. Do not set a default action.

**Step 3: Add the Vite build**

Use the Nextcloud Vite configuration with `src/main.js` as the `main` entry. Keep generated `js/` output out of Git; it is produced in the worker image build.

**Step 4: Run the focused test**

Run: `python3 -m pytest -q tests/test_nextcloud_eurooffice_gitops.py`

Expected: PASS.

### Task 3: Package and install the companion app deterministically

**Files:**
- Modify: `manager-worker/Dockerfile`
- Modify: `categories/apps/steps/install-nextcloud/run.sh`

**Step 1: Build the bundle in the worker image**

Install the companion app's locked Node dependencies and run its production build after the source is copied into the image. The resulting app tree, including Vite chunks, remains available under `/opt/twinbox/categories/.../eurooffice-file-action` for the installer.

**Step 2: Install before enabling**

After EuroOffice is configured, stream the companion app tree into `/var/www/html/custom_apps/twinbox_eurooffice_action` in the Nextcloud pod, set `www-data` ownership, and run `php occ app:enable twinbox_eurooffice_action`. Replace only that verified app directory so repeated installs are idempotent; do not modify the EuroOffice app directory.

**Step 3: Run focused verification**

Run:
```bash
bash -n categories/apps/steps/install-nextcloud/run.sh
python3 -m pytest -q tests/test_nextcloud_eurooffice_gitops.py
```

Expected: shell syntax and contract tests pass.

### Task 4: Build, verify, and deploy

**Files:**
- Modify: all files from Tasks 1–3

**Step 1: Run the full local checks**

Run:
```bash
make lint && make format-check
python3 -m pytest -q tests
node --test manager-*/test/*.mjs
npm run build --prefix categories/apps/steps/install-nextcloud/eurooffice-file-action
```

**Step 2: Commit and push**

Commit the companion app, installer, worker Dockerfile, and test with `feat(nextcloud): add eurooffice file action adapter`, then push `main`.

**Step 3: Update the Management VM only after image publication**

Wait for the `Publish Docker Images` workflow for that commit to succeed. On the Management VM run `sudo -n sh -lc 'cd /opt/twinbox && docker compose pull && docker compose up -d'`.

**Step 4: Re-run the Nextcloud install and inspect live state**

Run the Nextcloud install from the refreshed Management VM. Verify the companion app is enabled and use a signed-in browser session to confirm a DOCX file's three-dot menu has **Open in EuroOffice**, while normal file click remains Collabora. Also check that the EuroOffice document server accepts the resulting editor request.

**Step 5: Commit after successful verification**

No extra code commit is needed after deployment. Report the exact workflow, image revision, app status, and menu test result.
