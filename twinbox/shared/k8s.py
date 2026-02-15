"""
Kubernetes utility functions for Twinbox.

This module provides utilities for Kubernetes cluster management,
including kubeconfig handling, cluster operations, and health checks.
"""

from typing import Optional, Dict, List, Any
import subprocess
import json
import yaml


class K8sError(Exception):
    """Custom exception for Kubernetes operations."""
    pass


def load_kubeconfig(config_path: str) -> Dict:
    """
    Load kubeconfig from file.

    Args:
        config_path: Path to kubeconfig file

    Returns:
        Parsed kubeconfig dictionary
    """
    with open(config_path, 'r') as f:
        return yaml.safe_load(f)


def save_kubeconfig(config: Dict, config_path: str) -> None:
    """
    Save kubeconfig to file.

    Args:
        config: Kubeconfig dictionary
        config_path: Path to save to
    """
    with open(config_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False)


def set_current_context(kubeconfig: Dict, context_name: str) -> bool:
    """
    Set the current context in kubeconfig.

    Args:
        kubeconfig: Kubeconfig dictionary
        context_name: Name of context to set as current

    Returns:
        True if successful, False otherwise
    """
    contexts = kubeconfig.get('contexts', [])
    context_names = [c['name'] for c in contexts]
    if context_name in context_names:
        kubeconfig['current-context'] = context_name
        return True
    return False


def get_current_context(kubeconfig: Dict) -> Optional[str]:
    """
    Get the current context from kubeconfig.

    Args:
        kubeconfig: Kubeconfig dictionary

    Returns:
        Current context name or None
    """
    return kubeconfig.get('current-context')


def exec_kubectl(command: List[str], kubeconfig: Optional[str] = None) -> Dict:
    """
    Execute kubectl command and return parsed JSON output.

    Args:
        command: kubectl command as list of args (e.g., ['get', 'nodes', '-o', 'json'])
        kubeconfig: Optional path to kubeconfig

    Returns:
        Parsed JSON output as dictionary

    Raises:
        K8sError: If command fails
    """
    cmd = ['kubectl']
    if kubeconfig:
        cmd.extend(['--kubeconfig', kubeconfig])
    cmd.extend(command)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        raise K8sError(f"kubectl command failed: {e.stderr}")
    except json.JSONDecodeError as e:
        raise K8sError(f"Failed to parse kubectl output: {e}")


def get_nodes(kubeconfig: Optional[str] = None) -> List[Dict]:
    """
    Get all nodes in the cluster.

    Args:
        kubeconfig: Optional path to kubeconfig

    Returns:
        List of node dictionaries
    """
    output = exec_kubectl(['get', 'nodes', '-o', 'json'], kubeconfig)
    return output.get('items', [])


def get_pods(kubeconfig: Optional[str] = None, namespace: str = "default") -> List[Dict]:
    """
    Get all pods in a namespace.

    Args:
        kubeconfig: Optional path to kubeconfig
        namespace: Namespace to query

    Returns:
        List of pod dictionaries
    """
    output = exec_kubectl(['get', 'pods', '-n', namespace, '-o', 'json'], kubeconfig)
    return output.get('items', [])


def cluster_info(kubeconfig: Optional[str] = None) -> Dict:
    """
    Get cluster information.

    Args:
        kubeconfig: Optional path to kubeconfig

    Returns:
        Dictionary with cluster info
    """
    try:
        nodes = get_nodes(kubeconfig)
        pods = get_pods(kubeconfig, namespace="kube-system")

        ready_nodes = sum(
            1 for node in nodes
            if any(
                cond['type'] == 'Ready' and cond['status'] == 'True'
                for cond in node.get('status', {}).get('conditions', [])
            )
        )

        return {
            'node_count': len(nodes),
            'ready_nodes': ready_nodes,
            'kube_system_pods': len(pods),
            'cluster_status': 'healthy' if ready_nodes == len(nodes) else 'degraded'
        }
    except Exception as e:
        return {
            'node_count': 0,
            'ready_nodes': 0,
            'kube_system_pods': 0,
            'cluster_status': 'error',
            'error': str(e)
        }


def wait_for_node_ready(node_name: str, kubeconfig: Optional[str] = None, timeout: int = 300) -> bool:
    """
    Wait for a node to become Ready.

    Args:
        node_name: Name of the node
        kubeconfig: Optional path to kubeconfig
        timeout: Timeout in seconds

    Returns:
        True if node becomes Ready, False if timeout
    """
    import time
    start_time = time.time()

    while time.time() - start_time < timeout:
        try:
            nodes = get_nodes(kubeconfig)
            node = next((n for n in nodes if n['metadata']['name'] == node_name), None)
            if node:
                conditions = node.get('status', {}).get('conditions', [])
                ready_condition = next(
                    (c for c in conditions if c['type'] == 'Ready'),
                    None
                )
                if ready_condition and ready_condition.get('status') == 'True':
                    return True
        except Exception:
            pass
        time.sleep(5)

    return False


def apply_manifest(manifest: str, kubeconfig: Optional[str] = None, namespace: Optional[str] = None) -> Dict:
    """
    Apply a Kubernetes manifest.

    Args:
        manifest: YAML manifest string
        kubeconfig: Optional path to kubeconfig
        namespace: Optional namespace to apply to

    Returns:
        kubectl apply output
    """
    import tempfile
    import os

    with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
        f.write(manifest)
        temp_path = f.name

    try:
        cmd = ['apply', '-f', temp_path]
        if namespace:
            cmd.extend(['-n', namespace])
        output = exec_kubectl(cmd, kubeconfig)
        return output
    finally:
        os.unlink(temp_path)


def delete_manifest(manifest: str, kubeconfig: Optional[str] = None, namespace: Optional[str] = None) -> Dict:
    """
    Delete resources defined in a manifest.

    Args:
        manifest: YAML manifest string
        kubeconfig: Optional path to kubeconfig
        namespace: Optional namespace

    Returns:
        kubectl delete output
    """
    import tempfile
    import os

    with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
        f.write(manifest)
        temp_path = f.name

    try:
        cmd = ['delete', '-f', temp_path, '--ignore-not-found']
        if namespace:
            cmd.extend(['-n', namespace])
        output = exec_kubectl(cmd, kubeconfig)
        return output
    finally:
        os.unlink(temp_path)


def get_pod_log(pod_name: str, container: Optional[str] = None, kubeconfig: Optional[str] = None, namespace: str = "default", tail_lines: int = 100) -> str:
    """
    Get logs from a pod.

    Args:
        pod_name: Name of the pod
        container: Optional container name (for multi-container pods)
        kubeconfig: Optional path to kubeconfig
        namespace: Namespace of the pod
        tail_lines: Number of lines to tail

    Returns:
        Pod log string
    """
    cmd = ['logs', pod_name, '-n', namespace, f'--tail={tail_lines}']
    if container:
        cmd.extend(['-c', container])

    try:
        result = subprocess.run(
            ['kubectl'] + (['--kubeconfig', kubeconfig] if kubeconfig else []) + cmd,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        raise K8sError(f"Failed to get pod logs: {e.stderr}")


def exec_in_pod(pod_name: str, command: List[str], kubeconfig: Optional[str] = None, namespace: str = "default", container: Optional[str] = None) -> str:
    """
    Execute command in a pod.

    Args:
        pod_name: Name of the pod
        command: Command to execute (as list)
        kubeconfig: Optional path to kubeconfig
        namespace: Namespace of the pod
        container: Optional container name

    Returns:
        Command output
    """
    cmd = ['exec', pod_name, '-n', namespace] + command
    if container:
        cmd = ['exec', pod_name, '-c', container, '-n', namespace] + command

    try:
        result = subprocess.run(
            ['kubectl'] + (['--kubeconfig', kubeconfig] if kubeconfig else []) + cmd,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        raise K8sError(f"Failed to exec in pod: {e.stderr}")
