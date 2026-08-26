import test from "node:test";
import assert from "node:assert/strict";
import { buildAppleMailProfile, buildAppleMailProfileFilename } from "../mail-profile.mjs";

test("buildAppleMailProfile renders escaped Apple Mail plist settings", () => {
  const profile = buildAppleMailProfile({
    email: "alex+test@example.com",
    displayName: 'Alex & "Mail" <User>',
    imap: { host: "mail.example.com", port: 993 },
    smtp: { host: "smtp.example.com", port: 587 },
    password: 'secret & <token> "quoted"',
    profileUuid: "11111111-1111-4111-8111-111111111111",
    payloadUuid: "22222222-2222-4222-8222-222222222222",
  });

  assert.match(profile, /<key>PayloadType<\/key>\s+<string>Configuration<\/string>/);
  assert.match(profile, /<key>PayloadType<\/key>\s+<string>com\.apple\.mail\.managed<\/string>/);
  assert.match(profile, /<key>EmailAccountType<\/key>\s+<string>EmailTypeIMAP<\/string>/);
  assert.match(profile, /<key>IncomingMailServerPortNumber<\/key>\s+<integer>993<\/integer>/);
  assert.match(profile, /<key>OutgoingMailServerPortNumber<\/key>\s+<integer>587<\/integer>/);
  assert.match(profile, /<key>IncomingMailServerUseSSL<\/key>\s+<true\/>/);
  assert.match(profile, /<key>OutgoingMailServerUseSSL<\/key>\s+<false\/>/);
  assert.match(profile, /Alex &amp; &quot;Mail&quot; &lt;User&gt;/);
  assert.match(profile, /secret &amp; &lt;token&gt; &quot;quoted&quot;/);
  assert.match(profile, /11111111-1111-4111-8111-111111111111/);
  assert.match(profile, /22222222-2222-4222-8222-222222222222/);
  assert.doesNotMatch(profile, /undefined|null/);
});

test("buildAppleMailProfileFilename produces a mobileconfig filename", () => {
  assert.equal(
    buildAppleMailProfileFilename("Alex+Test@Example.COM"),
    "twinbox-mail-alex-test-example.com.mobileconfig"
  );
});
