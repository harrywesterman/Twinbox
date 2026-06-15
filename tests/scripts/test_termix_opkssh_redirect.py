import re
import unittest
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
TERMIX_CONFIGMAP = WORKSPACE_ROOT / "gitops" / "platform-apps" / "termix" / "configmap.yaml"
TERMIX_DEPLOYMENT = WORKSPACE_ROOT / "gitops" / "platform-apps" / "termix" / "deployment.yaml"
OPKSSH_SETUP = WORKSPACE_ROOT / "scripts" / "manager" / "setup-opkssh-authentik.sh"


class TestTermixOpksshRedirect(unittest.TestCase):
    def test_opkssh_remote_redirect_respects_force_https(self):
        text = TERMIX_CONFIGMAP.read_text(encoding="utf-8")

        self.assertIn("function normalizeRemoteRedirectOrigin(requestOrigin)", text)
        self.assertIn('process.env.OIDC_FORCE_HTTPS === "true"', text)
        self.assertIn('return requestOrigin.replace(/^http:/, "https:");', text)
        self.assertIn(
            "const remoteRedirectUri = `${remoteRedirectOrigin}${OPKSSH_CALLBACK_PATH}`;",
            text,
        )

    def test_opkssh_oauth_redirect_forwards_state_cookie(self):
        text = TERMIX_CONFIGMAP.read_text(encoding="utf-8")

        self.assertIn("function rewriteOPKSSHCallbackCookies(value)", text)
        self.assertIn('const setCookieHeader = response.headers["set-cookie"];', text)
        self.assertIn(
            'res.setHeader("set-cookie", rewriteOPKSSHCallbackCookies(setCookieHeader));',
            text,
        )
        self.assertIn("res.setHeader(key, rewriteOPKSSHCallbackCookies(value));", text)

    def test_opkssh_provider_redirect_uri_stays_strict_https(self):
        text = OPKSSH_SETUP.read_text(encoding="utf-8")

        self.assertIn('termix_host="https://termix.${public_zone_name}"', text)
        self.assertIn('opkssh_redirect_uri="${termix_host}/host/opkssh-callback"', text)
        self.assertNotRegex(
            text,
            re.compile(r'url:\s*"http://termix|\bhttp://termix\.\$\{public_zone_name\}'),
        )

    def test_termix_patch_rollout_annotation_is_present(self):
        text = TERMIX_DEPLOYMENT.read_text(encoding="utf-8")

        self.assertIn("twinbox.dev/termix-patch-revision:", text)
        self.assertIn("termix-patch", text)
        self.assertIn("subPath: opkssh-auth.js", text)
        self.assertIn("subPath: host.js", text)


if __name__ == "__main__":
    unittest.main()
