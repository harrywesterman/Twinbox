from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_manager_api_image_includes_shared_secret_runtime_without_bw():
    text = (REPO_ROOT / "manager-api" / "Dockerfile").read_text(encoding="utf-8")

    assert "FROM node:24-alpine" in text
    assert "COPY lib ./lib" in text
    assert "COPY manager-api/package.json ./manager-api/package.json" in text
    assert "apk add --no-cache ca-certificates curl iproute2 iputils-ping" in text
    assert "npm install --omit=dev" in text
    assert "bitwarden" not in text.lower()
