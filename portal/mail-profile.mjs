import crypto from "crypto";

export const APPLE_MAIL_PROFILE_CONTENT_TYPE = "application/x-apple-aspen-config";

function escapeXml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function safeIdentifierPart(value) {
  return (
    String(value || "")
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9.-]+/g, "-")
      .replace(/^-+|-+$/g, "") || "mail"
  );
}

export function buildAppleMailProfileFilename(email) {
  return `twinbox-mail-${safeIdentifierPart(email).replaceAll("@", "-")}.mobileconfig`;
}

export function buildAppleMailProfile({
  email,
  displayName = "",
  imap,
  smtp,
  password,
  profileUuid = crypto.randomUUID(),
  payloadUuid = crypto.randomUUID(),
}) {
  const accountEmail = String(email || "").trim();
  const incoming = imap || {};
  const outgoing = smtp || {};
  const secret = String(password || "");
  const name = String(displayName || accountEmail).trim() || accountEmail;
  const identifier = `nl.twinbox.mail.${safeIdentifierPart(accountEmail)}`;

  if (!accountEmail || !incoming.host || !incoming.port || !outgoing.host || !outgoing.port) {
    throw new Error("mail profile requires email, IMAP settings, and SMTP settings");
  }
  if (!secret) {
    throw new Error("mail profile requires an app password");
  }

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>EmailAccountDescription</key>
      <string>${escapeXml(`Twinbox Mail - ${accountEmail}`)}</string>
      <key>EmailAccountName</key>
      <string>${escapeXml(name)}</string>
      <key>EmailAccountType</key>
      <string>EmailTypeIMAP</string>
      <key>EmailAddress</key>
      <string>${escapeXml(accountEmail)}</string>
      <key>IncomingMailServerAuthentication</key>
      <string>EmailAuthPassword</string>
      <key>IncomingMailServerHostName</key>
      <string>${escapeXml(incoming.host)}</string>
      <key>IncomingMailServerPortNumber</key>
      <integer>${Number(incoming.port)}</integer>
      <key>IncomingMailServerUseSSL</key>
      <true/>
      <key>IncomingMailServerUsername</key>
      <string>${escapeXml(accountEmail)}</string>
      <key>IncomingPassword</key>
      <string>${escapeXml(secret)}</string>
      <key>OutgoingMailServerAuthentication</key>
      <string>EmailAuthPassword</string>
      <key>OutgoingMailServerHostName</key>
      <string>${escapeXml(outgoing.host)}</string>
      <key>OutgoingMailServerPortNumber</key>
      <integer>${Number(outgoing.port)}</integer>
      <key>OutgoingMailServerUseSSL</key>
      <true/>
      <key>OutgoingMailServerUsername</key>
      <string>${escapeXml(accountEmail)}</string>
      <key>OutgoingPassword</key>
      <string>${escapeXml(secret)}</string>
      <key>OutgoingPasswordSameAsIncomingPassword</key>
      <false/>
      <key>PayloadIdentifier</key>
      <string>${escapeXml(`${identifier}.account`)}</string>
      <key>PayloadType</key>
      <string>com.apple.mail.managed</string>
      <key>PayloadUUID</key>
      <string>${escapeXml(payloadUuid)}</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>${escapeXml(`Twinbox Mail - ${accountEmail}`)}</string>
  <key>PayloadIdentifier</key>
  <string>${escapeXml(identifier)}</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>${escapeXml(profileUuid)}</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
`;
}
