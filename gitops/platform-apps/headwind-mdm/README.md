# Twinbox Headwind MDM chart

This is the Twinbox-owned Headwind MDM chart. It intentionally does not use
the community chart at runtime: its historical defaults lag the official
Docker wrapper and only persist Tomcat's `work` directory. The chart pins the
official wrapper, server WAR and launcher, and persists all three mutable
Tomcat paths (`work`, context configuration and `webapps`) on Longhorn.

The Argo Sync hook is a security gate. It waits for Headwind, replaces the
initial `admin:admin` password from OpenBao, creates `Twinbox Mobile` with a
unique device-administrator password, verifies each initial native APK and
only then permits the public enrollment `IngressRoute` at sync wave 20.

The public enrollment hostname serves only `/rest/public/` and `/files/`.
The local Headwind console is deliberately exposed only as the separate
`mdm-admin.<zone>` NetBird service. Headwind Community has no native OIDC
integration, so the Headwind console retains its own OpenBao-generated local
administrator login.

Before changing a native catalog entry, obtain the artifact from its official
release URL and compare both `shasum -a 256` and
`apksigner verify --print-certs` with its `sha256` and `signer` fields. The
reconciler repeats the SHA-256 check before it registers a changed artifact
with Headwind; the signing-certificate digest is the release-review gate.
