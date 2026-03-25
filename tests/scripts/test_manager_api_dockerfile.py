from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_manager_api_image_includes_shared_secret_runtime_and_bw():
    text = (REPO_ROOT / "manager-api" / "Dockerfile").read_text(encoding="utf-8")

    assert "FROM node:20-bookworm-slim" in text
    assert "ARG BW_VERSION=1.22.1" in text
    assert "COPY lib ./lib" in text
    assert "COPY manager-api/package.json ./manager-api/package.json" in text
    assert "install -m 0755 /tmp/bw/bw /usr/local/bin/bw" in text
    assert "bw --version" in text
