import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "gatus_bastion", ROOT / "scripts/manager/gatus-bastion.py"
)
gatus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gatus)


def test_passthrough_excludes_only_status_and_is_idempotent():
    original = "HostSNI(`*`) && !HostSNI(`netbird.example.test`)"
    key = "traefik.tcp.routers.proxy-passthrough.rule"
    for labels in ({key: original}, [f"{key}={original}"]):
        stack = {"services": {"proxy": {"labels": labels}}}
        result = gatus.patch_passthrough(stack, ["status.example.test"])
        once = json.dumps(result)
        assert json.dumps(gatus.patch_passthrough(result, ["status.example.test"])) == once
        assert "!HostSNI(`status.example.test`)" in once
        assert "!HostSNI(`netbird.example.test`)" in once
        assert "HostSNI(`*`)" in once
        migrated = gatus.patch_passthrough(
            result, ["status.new.example.test"], ["status.example.test"]
        )
        assert "!HostSNI(`status.example.test`)" not in json.dumps(migrated)
        assert "!HostSNI(`status.new.example.test`)" in json.dumps(migrated)


def test_compose_is_private_persistent_and_uses_exact_host_tls():
    config = gatus.compose_config(
        "official:pinned", "discovered-network", ["status.example.test"], "secure", "dns"
    )
    service = config["services"]["gatus"]
    assert "ports" not in service
    assert service["volumes"] == ["./config:/config:ro", "./data:/data"]
    assert service["mem_limit"] == "256m"
    assert service["restart"] == "unless-stopped"
    assert service["cap_drop"] == ["ALL"]
    assert service["read_only"] is True
    assert service["tmpfs"] == ["/tmp:rw,noexec,nosuid,size=64m,mode=1777"]
    assert (
        service["labels"]["traefik.http.routers.twinbox-gatus-0.middlewares"]
        == "twinbox-gatus-cache"
    )
    assert (
        service["labels"][
            "traefik.http.middlewares.twinbox-gatus-cache.headers.customresponseheaders.Cache-Control"
        ]
        == "no-store"
    )
    assert (
        service["labels"]["traefik.http.routers.twinbox-gatus-0.rule"]
        == "Host(`status.example.test`)"
    )
    assert (
        service["labels"]["traefik.http.routers.twinbox-gatus-0.tls.domains[0].main"]
        == "status.example.test"
    )
    assert "docker.sock" not in json.dumps(config)
    assert config["networks"]["bastion"]["name"] == "discovered-network"


@pytest.mark.parametrize("statuses", [[], {"error": "disk I/O error"}])
def test_status_api_rejects_empty_or_failed_history(tmp_path, monkeypatch, statuses):
    (tmp_path / "config").mkdir()
    (tmp_path / "config/config.yaml").write_text("endpoints:\n- name: example\n")
    monkeypatch.setattr(gatus, "ROOT", tmp_path)
    from io import StringIO

    class Response(StringIO):
        status = 200

    monkeypatch.setattr(
        gatus.urllib.request, "urlopen", lambda *_args, **_kwargs: Response(json.dumps(statuses))
    )
    with pytest.raises(RuntimeError, match="status API"):
        gatus.check_status_api("http://example.test")


def test_status_api_accepts_readable_history(tmp_path, monkeypatch):
    (tmp_path / "config").mkdir()
    (tmp_path / "config/config.yaml").write_text("endpoints:\n- name: example\n")
    monkeypatch.setattr(gatus, "ROOT", tmp_path)
    from io import StringIO

    class Response(StringIO):
        status = 200

    monkeypatch.setattr(
        gatus.urllib.request, "urlopen", lambda *_args, **_kwargs: Response('[{"name":"example"}]')
    )
    gatus.check_status_api("http://example.test")


def test_failed_provider_does_not_expose_token_or_address(monkeypatch):
    def fail(*_args, **_kwargs):
        raise RuntimeError("secret-token private-address")

    monkeypatch.setattr(gatus, "request_json", fail)
    with pytest.raises(RuntimeError, match="telegram: test notification failed") as error:
        gatus.test_notification(
            "telegram", {"telegram": {"token": "secret-token", "id": "private-address"}}
        )
    assert "secret-token" not in str(error.value)
    assert "private-address" not in str(error.value)


def test_validator_has_no_network_and_always_removes_candidate(monkeypatch):
    calls = []

    def command(*args, **_kwargs):
        calls.append(args)
        if args[1] == "inspect":
            return json.dumps([{"State": {"Running": False}}])
        return ""

    cleanup = []
    monkeypatch.setattr(gatus, "command", command)
    monkeypatch.setattr(
        gatus.subprocess,
        "run",
        lambda args, **_kwargs: cleanup.append(args) or SimpleNamespace(stdout="", stderr=""),
    )
    with pytest.raises(RuntimeError, match="validation"):
        gatus.validate_candidate("official:pinned", {"endpoints": []})
    run = calls[0]
    assert run[run.index("--network") + 1] == "none"
    assert "--read-only" in run
    assert run[run.index("--tmpfs") + 1] == "/tmp:rw,noexec,nosuid,size=64m,mode=1777"
    assert run[-1] == "official:pinned"
    assert cleanup[-1][1:3] == ["rm", "-f"]


@pytest.fixture
def deployment(tmp_path, monkeypatch):
    root = tmp_path / "gatus"
    root.mkdir()
    netbird = tmp_path / "docker-compose.yml"
    marker = tmp_path / "marker.json"
    marker.write_text(json.dumps({"managed_by": "twinbox", "component": "netbird-bastion"}))
    stack = {
        "services": {
            "proxy": {
                "labels": {
                    "traefik.tcp.routers.proxy-passthrough.rule": "HostSNI(`*`) && !HostSNI(`netbird.example.test`)"
                }
            },
            "dashboard": {
                "labels": {
                    "traefik.http.routers.netbird-dashboard.entrypoints": "secure",
                    "traefik.http.routers.netbird-dashboard.tls.certresolver": "dns",
                }
            },
        }
    }
    netbird.write_text(yaml.safe_dump(stack))
    monkeypatch.setattr(gatus, "ROOT", root)
    monkeypatch.setattr(gatus, "NETBIRD", netbird)
    monkeypatch.setattr(gatus, "MARKER", marker)
    monkeypatch.setattr(
        gatus,
        "inspect_service",
        lambda _service: {
            "NetworkSettings": {"Networks": {"discovered": {}}},
            "Config": {"Cmd": []},
        },
    )
    monkeypatch.setattr(gatus, "command", lambda *_args, **_kwargs: "")
    monkeypatch.setattr(gatus, "compose", lambda *_args: "")
    monkeypatch.setattr(
        gatus.subprocess, "run", lambda *_args, **_kwargs: SimpleNamespace(returncode=0)
    )
    return root, netbird


def test_invalid_candidate_does_not_change_live_files(deployment, monkeypatch):
    root, netbird = deployment
    original = netbird.read_bytes()

    def invalid(*_args):
        raise RuntimeError("invalid candidate")

    monkeypatch.setattr(gatus, "validate_candidate", invalid)
    with pytest.raises(RuntimeError, match="invalid candidate"):
        gatus.apply({"hosts": ["status.example.test"], "image": "official:pinned", "config": {}})
    assert netbird.read_bytes() == original
    assert not (root / "compose.yaml").exists()


def test_health_failure_restores_previous_config_and_preserves_data(deployment, monkeypatch):
    root, netbird = deployment
    original = netbird.read_bytes()
    (root / "config").mkdir()
    (root / "data").mkdir()
    (root / "config/config.yaml").write_text("previous")
    (root / "compose.yaml").write_text("previous-compose")
    (root / "data/history").write_text("keep")
    monkeypatch.setattr(gatus, "validate_candidate", lambda *_args: None)

    def unhealthy():
        raise RuntimeError("unhealthy")

    monkeypatch.setattr(gatus, "wait_healthy", unhealthy)
    with pytest.raises(RuntimeError, match="previous configuration restored"):
        gatus.apply(
            {
                "hosts": ["status.example.test"],
                "image": "official:pinned",
                "config": {"endpoints": []},
            }
        )
    assert netbird.read_bytes() == original
    assert (root / "config/config.yaml").read_text() == "previous"
    assert (root / "compose.yaml").read_text() == "previous-compose"
    assert (root / "data/history").read_text() == "keep"


def test_reapply_repairs_compose_drift_even_with_matching_digest(deployment, monkeypatch):
    root, _netbird = deployment
    monkeypatch.setattr(gatus, "validate_candidate", lambda *_args: None)
    monkeypatch.setattr(gatus, "wait_healthy", lambda: None)
    monkeypatch.setattr(gatus, "wait_public", lambda *_args: None)
    payload = {"hosts": ["status.example.test"], "image": "official:pinned", "config": {}}
    assert gatus.apply(payload) == {"changed": True}
    assert gatus.apply(payload) == {"changed": False}
    compose_file = root / "compose.yaml"
    broken = yaml.safe_load(compose_file.read_text())
    del broken["services"]["gatus"]["tmpfs"]
    compose_file.write_text(yaml.safe_dump(broken))
    assert gatus.apply(payload) == {"changed": True}
    assert yaml.safe_load(compose_file.read_text())["services"]["gatus"]["tmpfs"]


def test_bootstrap_preserves_status_exclusions():
    template = (ROOT / "scripts/manager/netbird-bastion-bootstrap-template.sh").read_text()
    assert "/opt/twinbox/gatus/hosts.json" in template
    assert 'passthrough_rule += f" && !HostSNI(`{status_host}`)"' in template
    compose = yaml.safe_load((ROOT / "docker-compose.yml").read_text())
    assert (
        "GATUS_MANAGEMENT_HEALTH_URL=${GATUS_MANAGEMENT_HEALTH_URL:-}"
        not in compose["services"]["manager-worker"]["environment"]
    )
