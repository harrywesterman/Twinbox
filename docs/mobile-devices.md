# Twinbox Mobile: Headwind MDM for LineageOS

Twinbox can install Headwind MDM as the optional **Install Headwind MDM** app.
It deploys one `Recreate` Headwind replica with Longhorn-backed Tomcat state,
a dedicated CloudNativePG cluster with Barman/SeaweedFS backup, OpenBao-backed
credentials, Traefik, Cloudflare/TLS and a private NetBird management route.

## Security boundary

The Headwind server has two distinct hosts:

- `mdm.<zone>` is the public device host. Traefik permits only
  `/rest/public/` and `/files/`; it never routes the UI root or
  `/rest/private/`.
- `mdm-admin.<zone>` is the full Headwind console via NetBird. It has a local
  Headwind administrator login because Headwind Community does not provide
  native OIDC. The initial `admin:admin` login is changed by the Argo Sync
  hook before the public enrollment route exists.

Headwind provides device policy, remote lock/wipe and application control. It
does not protect a phone against a person who can unlock its bootloader and
flash another operating system. Treat the supported hardware baseline as a
corporate asset with a locked bootloader after installing the approved
LineageOS build.

## Mobile catalog

The chart maintains a small, version-pinned catalog in
`gitops/platform-apps/headwind-mdm/templates/catalog-configmap.yaml`.

- NetBird is installed from the official `netbirdio/android-client` GitHub
  release, pinned to version, package ID and SHA-256.
- Fennec F-Droid is the initial managed browser, pinned to the arm64 artifact,
  F-Droid signing-certificate fingerprint and SHA-256.
- Twinbox Portal is always a Headwind web shortcut. Other Twinbox apps become
  shortcuts only while their Argo CD Application is `Synced`.

The in-cluster reconciler verifies a native artifact checksum before admitting
a new version and owns only the `io.twinbox.mobile.web.*` shortcuts. It leaves
manually-created Headwind applications and settings in place. The generic
optional-app install/uninstall flow triggers an immediate catalog job; an
hourly CronJob also converges state. Headwind web entries are shortcuts, not
managed PWAs.

The NetBird Android client is automatically installed and opened, but it is
not zero-touch: the phone owner must enter the self-hosted endpoint when
needed, complete Authentik SSO and approve Android's VPN permission. NetBird
does not currently expose the necessary Android managed configuration for a
fully unattended enrollment.

## Standard enrollment

1. Factory-reset the approved LineageOS phone. Do not use a personal or
   previously managed device for the corporate baseline.
2. At the Android welcome screen, tap the setup screen six times and scan the
   QR code generated for the `Twinbox Mobile` configuration in the private
   Headwind console. Enter Wi-Fi details when Android requests them.
3. Android downloads Headwind, grants it Device Owner and enrolls the phone.
   The launcher installs NetBird and Fennec, then applies Twinbox shortcuts.
4. Open NetBird, choose the self-hosted Twinbox endpoint, sign in with
   Authentik and approve the Android VPN dialog exactly once.
5. Verify that the private MDM console, Portal links, private DNS and allowed
   NetBird routes work. The phone can now receive policy and app updates.

To auto-assign freshly enrolled devices, add approved device serial numbers
to Headwind's `Twinbox Mobile` configuration before distributing QR codes.
Keep the Headwind device-administrator code in OpenBao; do not put it in a QR
code, ticket or Git repository.

## Release and update policy

Test Headwind upgrades against a separate test configuration and a spare
phone before updating the standard mobile group. The physical acceptance
matrix below is the support gate; an untested model is explicitly experimental.

| Check | Required result |
| --- | --- |
| QR / Device Owner | Fresh factory reset reaches the Twinbox Mobile policy. |
| Reboot | Headwind launcher and managed apps recover without de-enrollment. |
| App update | A catalog version update verifies, installs and preserves data. |
| Portal shortcuts | Portal and every installed Twinbox app open the expected host. |
| NetBird | Authentik SSO, VPN consent, private DNS and allowed routes succeed. |
| Remote control | Remote lock, wipe and re-enrollment work from the private console. |
| Boundary | Public host rejects `/` and `/rest/private/`; NetBird host reaches the console. |

The first supported LineageOS model is marked **supported** only after all
checks pass on physical hardware. Record the exact device, LineageOS build,
bootloader state, Headwind version and NetBird version with the test result.
