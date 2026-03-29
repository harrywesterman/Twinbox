import json
import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def _run_node(source: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["node", "--input-type=module", "-e", source],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_secret_broker_resolves_cluster_worker_bundle_from_filesystem_tree():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bootstrap_root = root / "bootstrap"
        global_secret_dir = bootstrap_root / "secrets" / "global"
        cluster_secret_dir = bootstrap_root / "secrets" / "cluster" / "cluster-a"
        tmp_dir = root / "tmp"
        global_secret_dir.mkdir(parents=True, exist_ok=True)
        cluster_secret_dir.mkdir(parents=True, exist_ok=True)
        tmp_dir.mkdir(parents=True, exist_ok=True)

        (global_secret_dir / "proxmox.json").write_text(
            json.dumps(
                {
                    "username": "root@pam",
                    "password": "super-secret",
                    "host": "192.168.1.10",
                    "port": "8006",
                    "endpoint": "https://192.168.1.10:8006",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        talos_secrets_dir = cluster_secret_dir / "talos-secrets"
        talosconfig_dir = cluster_secret_dir / "talosconfig"
        kubeconfig_dir = cluster_secret_dir / "kubeconfig"
        talos_secrets_dir.mkdir(parents=True, exist_ok=True)
        talosconfig_dir.mkdir(parents=True, exist_ok=True)
        kubeconfig_dir.mkdir(parents=True, exist_ok=True)
        (talos_secrets_dir / "secrets.yaml").write_text("cluster-secrets", encoding="utf-8")
        (talosconfig_dir / "talosconfig").write_text("talosconfig-data", encoding="utf-8")
        (kubeconfig_dir / "kubeconfig").write_text("kubeconfig-data", encoding="utf-8")

        env = os.environ.copy()
        env["TWINBOX_BOOTSTRAP_DIR"] = str(bootstrap_root)
        env["TWINBOX_SECRET_BACKEND"] = "filesystem"
        env["TWINBOX_SECRET_ITEM_PREFIX"] = "twinbox"
        env["TWINBOX_SECRET_TEMP_DIR"] = str(tmp_dir)

        result = _run_node(
            """
import fs from 'fs';
import { createSecretBroker } from './lib/secrets/broker.mjs';
import { buildClusterWorkerSecretBundle } from './lib/secrets/schema.mjs';

const broker = createSecretBroker(process.env);
const cluster = {
  id: 'cluster-a',
  metadata: {
    secret_refs: {
      proxmox: { scope: 'global', item: 'proxmox' },
      talos_secrets: { scope: 'cluster', item: 'talos-secrets', cluster_id: 'cluster-a' },
      talosconfig: { scope: 'cluster', item: 'talosconfig', cluster_id: 'cluster-a' },
      kubeconfig: { scope: 'cluster', item: 'kubeconfig', cluster_id: 'cluster-a' },
    },
  },
};

const resolved = broker.resolveBundle(buildClusterWorkerSecretBundle(cluster), { clusterId: 'cluster-a' });
console.log(JSON.stringify({
  proxmoxHost: resolved.env.PROXMOX_HOST,
  proxmoxEndpoint: resolved.env.TF_VAR_proxmox_endpoint,
  tfVarProxmoxPassword: resolved.env.TF_VAR_proxmox_password,
  kubeconfigPath: resolved.env.TWINBOX_KUBECONFIG_FILE,
  kubeconfigText: fs.readFileSync(resolved.env.TWINBOX_KUBECONFIG_FILE, 'utf8'),
  talosSecretsPath: resolved.env.TWINBOX_TALOS_SECRETS_FILE,
  talosSecretsText: fs.readFileSync(resolved.env.TWINBOX_TALOS_SECRETS_FILE, 'utf8'),
}));
            """,
            env,
        )

        assert result.returncode == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["proxmoxHost"] == "192.168.1.10"
        assert payload["proxmoxEndpoint"] == "https://192.168.1.10:8006"
        assert payload["tfVarProxmoxPassword"] == "super-secret"
        assert Path(payload["kubeconfigPath"]).is_file()
        assert payload["kubeconfigText"] == "kubeconfig-data"
        assert Path(payload["talosSecretsPath"]).is_file()
        assert payload["talosSecretsText"] == "cluster-secrets"


def test_secret_broker_upserts_cluster_attachment_into_bootstrap_tree():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bootstrap_root = root / "bootstrap"
        source_file = root / "source.txt"
        tmp_dir = root / "tmp"
        tmp_dir.mkdir(parents=True, exist_ok=True)
        source_file.write_text("talosconfig-data", encoding="utf-8")

        env = os.environ.copy()
        env["TWINBOX_BOOTSTRAP_DIR"] = str(bootstrap_root)
        env["TWINBOX_SECRET_BACKEND"] = "filesystem"
        env["TWINBOX_SECRET_ITEM_PREFIX"] = "twinbox"
        env["TWINBOX_SECRET_TEMP_DIR"] = str(tmp_dir)

        result = _run_node(
            f"""
import fs from 'fs';
import {{ createSecretBroker }} from './lib/secrets/broker.mjs';

const broker = createSecretBroker(process.env);
const targetPath = broker.upsertAttachment({{
  scope: 'cluster',
  item: 'talosconfig',
  cluster_id: 'cluster-a',
  attachment: 'talosconfig',
  format: 'file',
}}, {json.dumps(str(source_file))}, {{ clusterId: 'cluster-a' }});
console.log(JSON.stringify({{
  targetPath,
  copiedText: fs.readFileSync(targetPath, 'utf8'),
}}));
            """,
            env,
        )

        assert result.returncode == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["copiedText"] == "talosconfig-data"
        assert Path(payload["targetPath"]).is_file()
        assert Path(payload["targetPath"]).read_text(encoding="utf-8") == "talosconfig-data"
