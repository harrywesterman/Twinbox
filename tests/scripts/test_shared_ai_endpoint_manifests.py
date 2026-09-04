from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_yaml_documents(path):
    return list(yaml.safe_load_all(path.read_text(encoding="utf-8")))


def test_openwebui_consumes_shared_ai_endpoint_secret():
    deployment = yaml.safe_load(
        (REPO_ROOT / "gitops/platform-apps/openwebui/deployment.yaml").read_text(encoding="utf-8")
    )
    externalsecrets = load_yaml_documents(
        REPO_ROOT / "gitops/platform-apps/openwebui/externalsecret.yaml"
    )
    text = (REPO_ROOT / "gitops/platform-apps/openwebui/deployment.yaml").read_text(
        encoding="utf-8"
    )
    externalsecret_text = (
        REPO_ROOT / "gitops/platform-apps/openwebui/externalsecret.yaml"
    ).read_text(encoding="utf-8")

    assert "openwebui-ai-provider" in {doc["metadata"]["name"] for doc in externalsecrets}
    assert "OPENAI_API_BASE_URL" in externalsecret_text
    assert "OPENAI_API_KEY" in externalsecret_text
    assert "DEFAULT_MODELS" in externalsecret_text
    assert "ENABLE_PERSISTENT_CONFIG" in text

    env_from = deployment["spec"]["template"]["spec"]["containers"][0].get("envFrom", [])
    assert {"secretRef": {"name": "openwebui-ai-provider", "optional": True}} in env_from


def test_karakeep_consumes_shared_ai_endpoint_secret():
    externalsecrets = load_yaml_documents(
        REPO_ROOT / "gitops/platform-apps/karakeep/externalsecret.yaml"
    )
    optional_app = (REPO_ROOT / "gitops/optional-apps/karakeep.yaml").read_text(encoding="utf-8")

    assert "karakeep-ai-provider" in {doc["metadata"]["name"] for doc in externalsecrets}
    assert "OPENAI_BASE_URL" in optional_app
    assert "OPENAI_API_KEY" in optional_app
    assert "INFERENCE_TEXT_MODEL" in optional_app
    assert "INFERENCE_IMAGE_MODEL" in optional_app
    assert "EMBEDDING_TEXT_MODEL" not in optional_app


def test_paperless_consumes_shared_ai_endpoint_secret_without_embeddings():
    deployment = yaml.safe_load(
        (REPO_ROOT / "gitops/platform-apps/paperless/deployment.yaml").read_text(encoding="utf-8")
    )
    externalsecrets = load_yaml_documents(
        REPO_ROOT / "gitops/platform-apps/paperless/externalsecret.yaml"
    )
    text = (REPO_ROOT / "gitops/platform-apps/paperless/deployment.yaml").read_text(
        encoding="utf-8"
    )
    externalsecret_text = (
        REPO_ROOT / "gitops/platform-apps/paperless/externalsecret.yaml"
    ).read_text(encoding="utf-8")

    assert "paperless-ai-provider" in {doc["metadata"]["name"] for doc in externalsecrets}
    assert "PAPERLESS_AI_ENABLED" in externalsecret_text
    assert "PAPERLESS_AI_LLM_BACKEND" in externalsecret_text
    assert "PAPERLESS_AI_LLM_MODEL" in externalsecret_text
    assert "PAPERLESS_AI_LLM_API_KEY" in externalsecret_text
    assert "PAPERLESS_AI_LLM_ENDPOINT" in externalsecret_text
    assert "PAPERLESS_AI_LLM_EMBEDDING" not in text

    env_from = deployment["spec"]["template"]["spec"]["containers"][0].get("envFrom", [])
    assert {"secretRef": {"name": "paperless-ai-provider", "optional": True}} in env_from


def test_coder_workspace_consumes_shared_ai_endpoint_for_opencode():
    externalsecrets = load_yaml_documents(
        REPO_ROOT / "gitops/workspace-namespaces/coder-workspaces/externalsecret.yaml"
    )
    values_text = (REPO_ROOT / "gitops/values/coder.yaml").read_text(encoding="utf-8")
    template_text = (REPO_ROOT / "infra/coder/templates/twinbox-development/main.tf").read_text(
        encoding="utf-8"
    )

    assert "coder-workspace-ai-provider" in {doc["metadata"]["name"] for doc in externalsecrets}
    assert "OPENCODE_CONFIG_JSON" in template_text
    assert "OPENCODE_CONFIG" in template_text
    assert "OPENAI_API_KEY" in template_text
    assert "coder-workspace-ai-provider" in template_text
    assert "OPENCODE_CONFIG_JSON" not in values_text
    assert "OPENCODE_AUTH_JSON" not in values_text
    assert "OPENAI_API_KEY" not in values_text
