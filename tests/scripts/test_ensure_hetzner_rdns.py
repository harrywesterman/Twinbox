import importlib.util
import io
import json
import urllib.error
import urllib.parse
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = REPO_ROOT / "scripts" / "manager" / "ensure-hetzner-rdns.py"


def _load_helper_module():
    spec = importlib.util.spec_from_file_location("ensure_hetzner_rdns", HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


def _fake_http_error(url, code=403, payload=None, reason="Forbidden"):
    body = json.dumps(payload or {"error": {"message": "forbidden"}}).encode("utf-8")
    return urllib.error.HTTPError(url, code, reason, hdrs=None, fp=io.BytesIO(body))


def test_noop_when_ptr_already_matches(monkeypatch):
    helper = _load_helper_module()
    server = {
        "id": 42,
        "name": "twinbox-abc-netbird",
        "public_net": {
            "ipv4": {
                "ip": "203.0.113.10",
                "dns_ptr": "mail.example.com",
            }
        },
    }
    requests = []

    def fake_urlopen(request, timeout=30):
        requests.append(request)
        parsed = urllib.parse.urlparse(request.full_url)
        assert request.get_method() == "GET"
        assert parsed.path == "/v1/servers"
        assert urllib.parse.parse_qs(parsed.query) == {
            "name": ["twinbox-abc-netbird"],
            "page": ["1"],
            "per_page": ["50"],
        }
        return _FakeResponse({"servers": [server], "meta": {"pagination": {"last_page": 1}}})

    monkeypatch.setenv("HCLOUD_TOKEN", "secret-token")
    monkeypatch.setattr(helper.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(helper.time, "sleep", lambda *_: None)

    exit_code = helper.main(
        [
            "--server-name",
            "twinbox-abc-netbird",
            "--fallback-server-name",
            "netbird-abc",
            "--ip",
            "203.0.113.10",
            "--ptr",
            "mail.example.com",
        ]
    )

    assert exit_code == 0
    assert len(requests) == 1


def test_updates_ptr_and_verifies(monkeypatch):
    helper = _load_helper_module()
    server = {
        "id": 42,
        "name": "twinbox-abc-netbird",
        "public_net": {
            "ipv4": {
                "ip": "203.0.113.10",
                "dns_ptr": "static.10.113.0.203.clients.your-server.de",
            }
        },
    }
    updated_server = {
        "id": 42,
        "name": "twinbox-abc-netbird",
        "public_net": {
            "ipv4": {
                "ip": "203.0.113.10",
                "dns_ptr": "mail.example.com",
            }
        },
    }
    requests = []

    def fake_urlopen(request, timeout=30):
        requests.append(request)
        if len(requests) == 1:
            return _FakeResponse({"servers": [server], "meta": {"pagination": {"last_page": 1}}})
        if len(requests) == 2:
            assert request.get_method() == "POST"
            parsed = urllib.parse.urlparse(request.full_url)
            assert parsed.path == "/v1/servers/42/actions/change_dns_ptr"
            assert json.loads(request.data.decode("utf-8")) == {
                "ip": "203.0.113.10",
                "dns_ptr": "mail.example.com",
            }
            return _FakeResponse({"action": {"id": 7, "status": "running"}})
        if len(requests) == 3:
            parsed = urllib.parse.urlparse(request.full_url)
            assert parsed.path == "/v1/servers/42/actions/7"
            return _FakeResponse({"action": {"id": 7, "status": "success"}})
        if len(requests) == 4:
            parsed = urllib.parse.urlparse(request.full_url)
            assert parsed.path == "/v1/servers/42"
            return _FakeResponse({"server": updated_server})
        raise AssertionError("unexpected request")

    monkeypatch.setenv("HCLOUD_TOKEN", "secret-token")
    monkeypatch.setattr(helper.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(helper.time, "sleep", lambda *_: None)

    exit_code = helper.main(
        [
            "--server-name",
            "twinbox-abc-netbird",
            "--fallback-server-name",
            "netbird-abc",
            "--ip",
            "203.0.113.10",
            "--ptr",
            "mail.example.com",
        ]
    )

    assert exit_code == 0
    assert len(requests) == 4
    assert requests[1].get_header("Authorization") == "Bearer secret-token"


def test_falls_back_to_ipv4_lookup_when_name_lookup_misses(monkeypatch):
    helper = _load_helper_module()
    server = {
        "id": 99,
        "name": "legacy-netbird",
        "public_net": {
            "ipv4": {
                "ip": "203.0.113.11",
                "dns_ptr": "mail.example.com",
            }
        },
    }
    requests = []

    def fake_urlopen(request, timeout=30):
        requests.append(request)
        parsed = urllib.parse.urlparse(request.full_url)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/v1/servers" and query.get("name") == ["twinbox-abc-netbird"]:
            return _FakeResponse({"servers": [], "meta": {"pagination": {"last_page": 1}}})
        if parsed.path == "/v1/servers" and query.get("name") == ["netbird-abc"]:
            return _FakeResponse({"servers": [], "meta": {"pagination": {"last_page": 1}}})
        if parsed.path == "/v1/servers" and "name" not in query:
            return _FakeResponse({"servers": [server], "meta": {"pagination": {"last_page": 1}}})
        raise AssertionError(f"unexpected request {request.full_url}")

    monkeypatch.setenv("HCLOUD_TOKEN", "secret-token")
    monkeypatch.setattr(helper.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(helper.time, "sleep", lambda *_: None)

    exit_code = helper.main(
        [
            "--server-name",
            "twinbox-abc-netbird",
            "--fallback-server-name",
            "netbird-abc",
            "--ip",
            "203.0.113.11",
            "--ptr",
            "mail.example.com",
        ]
    )

    assert exit_code == 0
    assert len(requests) == 3


def test_name_lookup_ip_mismatch_fails_without_leaking_token(monkeypatch):
    helper = _load_helper_module()
    server = {
        "id": 42,
        "name": "twinbox-abc-netbird",
        "public_net": {
            "ipv4": {
                "ip": "198.51.100.3",
                "dns_ptr": "static.3.100.51.198.clients.your-server.de",
            }
        },
    }

    def fake_urlopen(request, timeout=30):
        parsed = urllib.parse.urlparse(request.full_url)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/v1/servers" and query.get("name") == ["twinbox-abc-netbird"]:
            return _FakeResponse({"servers": [server], "meta": {"pagination": {"last_page": 1}}})
        if parsed.path == "/v1/servers" and query.get("name") == ["netbird-abc"]:
            return _FakeResponse({"servers": [], "meta": {"pagination": {"last_page": 1}}})
        if parsed.path == "/v1/servers" and "name" not in query:
            return _FakeResponse({"servers": [], "meta": {"pagination": {"last_page": 1}}})
        raise AssertionError(f"unexpected request {request.full_url}")

    monkeypatch.setenv("HCLOUD_TOKEN", "super-secret-token")
    monkeypatch.setattr(helper.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(helper.time, "sleep", lambda *_: None)

    with pytest.raises(helper.HetznerError) as exc_info:
        helper.main(
            [
                "--server-name",
                "twinbox-abc-netbird",
                "--fallback-server-name",
                "netbird-abc",
                "--ip",
                "203.0.113.12",
                "--ptr",
                "mail.example.com",
            ]
        )

    message = str(exc_info.value)
    assert "matched by name but not by IPv4" in message
    assert "super-secret-token" not in message


def test_http_error_does_not_include_token(monkeypatch):
    helper = _load_helper_module()

    def fake_urlopen(request, timeout=30):
        raise _fake_http_error(
            request.full_url,
            code=403,
            payload={"error": {"code": "forbidden", "message": "denied"}},
        )

    monkeypatch.setenv("HCLOUD_TOKEN", "super-secret-token")
    monkeypatch.setattr(helper.urllib.request, "urlopen", fake_urlopen)

    with pytest.raises(helper.HetznerError) as exc_info:
        helper.main(
            [
                "--server-name",
                "twinbox-abc-netbird",
                "--fallback-server-name",
                "netbird-abc",
                "--ip",
                "203.0.113.12",
                "--ptr",
                "mail.example.com",
            ]
        )

    message = str(exc_info.value)
    assert "HTTP 403" in message
    assert "super-secret-token" not in message
