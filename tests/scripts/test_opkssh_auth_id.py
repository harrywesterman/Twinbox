import re
import unittest

AUTH_ID_RE = re.compile(r"^(\S+)\s+(oidc:groups:\S+|\S+)\s+(https://.*/)$")


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

    def test_invalid_principal(self):
        line = " oidc:groups:admins https://authentik.example.com/application/o/opkssh/"
        self.assertFalse(AUTH_ID_RE.match(line))


if __name__ == "__main__":
    unittest.main()
