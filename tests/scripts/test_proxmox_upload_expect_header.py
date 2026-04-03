from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"


def test_proxmox_iso_upload_disables_expect_100_continue():
    text = APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")
    assert '--header "Expect:"' in text
    assert '--form "content=iso"' in text


def test_proxmox_iso_upload_captures_curl_failure_without_errexit_short_circuit():
    text = APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")
    assert 'if http_code="$(' in text
    assert 'curl_exit=0' in text
    assert 'curl_exit=$?' in text
