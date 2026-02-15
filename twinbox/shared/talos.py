"""
Talos Linux management utilities for Twinbox.

This module provides utilities for Talos configuration, cluster bootstrap,
and node management using talosctl.
"""

from typing import Dict, List, Optional, Any
import subprocess
import json
import yaml
import tempfile
import os


class TalosError(Exception):
    """Custom exception for Talos operations."""
    pass


def generate_config(
    node_name: str,
    node_ip: str,
    role: str,
    cluster_name: str,
    kubernetes_version: str = "v1.28.0",
    talos_version: str = "v1.5.0",
    pod_cidr: str = "10.244.0.0/16",
    service_cidr: str = "10.96.0.0/12",
    **kwargs
) -> Dict:
    """
    Generate Talos configuration for a node.

    Args:
        node_name: Name of the node
        node_ip: IP address of the node
        role: Node role (controlplane, worker)
        cluster_name: Name of the cluster
        kubernetes_version: Kubernetes version
        talos_version: Talos version
        pod_cidr: Pod network CIDR
        service_cidr: Service network CIDR
        **kwargs: Additional configuration options

    Returns:
        Talos configuration dictionary
    """
    config = {
        'version': 1,
        'meta': {
            'name': node_name,
            'cluster': cluster_name,
            'install': {
                'disk': '/dev/sda',
                'image': kwargs.get('talos_image', f"factory.talos.dev/installer/{talos_version}:{talos_version}")
            }
        },
        'machine': {
            'type': 'ControlPlane' if role == 'controlplane' else 'Worker',
            'network': {
                'name': 'eth0',
                'ipAddress': [f"{node_ip}/24"],  # Assume /24 for simplicity
                'nameservers': ['8.8.8.8', '8.8.4.4']
            },
            'kubelet': {
                'clusterDNS': ['10.96.0.10'],
                'clusterDomain': 'cluster.local'
            }
        },
        'cluster': {
            'clusterName': cluster_name,
            'controlPlane': {
                'endpoint': f"https://{node_ip}:6443" if role == 'controlplane' else None
            },
            'kubernetes': {
                'version': kubernetes_version,
                'clusterCIDR': pod_cidr,
                'serviceCIDR': service_cidr
            },
            'secretbox': {
                'secret': kwargs.get('secret', 'placeholder-secret')
            }
        }
    }

    # Add additional config for control plane nodes
    if role == 'controlplane':
        config['cluster']['etcd'] = {
            'ca': kwargs.get('etcd_ca'),
            'key': kwargs.get('etcd_key'),
            'cert': kwargs.get('etcd_cert')
        }

    return config


def generate_config_yaml(config: Dict) -> str:
    """
    Convert Talos configuration dictionary to YAML string.

    Args:
        config: Configuration dictionary

    Returns:
        YAML string
    """
    return yaml.dump(config, default_flow_style=False)


def apply_config(node_ip: str, config: Dict, talosctl_path: str = "talosctl", insecure: bool = True) -> bool:
    """
    Apply Talos configuration to a node using talosctl.

    Args:
        node_ip: IP address of the node
        config: Talos configuration dictionary
        talosctl_path: Path to talosctl binary
        insecure: Skip TLS verification (for initial bootstrap)

    Returns:
        True if successful, False otherwise
    """
    try:
        # Write config to temporary file
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
            yaml_str = generate_config_yaml(config)
            f.write(yaml_str)
            config_path = f.name

        # Build command
        cmd = [talosctl_path, '--nodes', node_ip, 'apply-config', '--file', config_path]
        if insecure:
            cmd.append('--insecure')

        # Execute
        result = subprocess.run(cmd, capture_output=True, text=True)
        os.unlink(config_path)

        if result.returncode != 0:
            raise TalosError(f"talosctl failed: {result.stderr}")

        return True

    except Exception as e:
        raise TalosError(f"Failed to apply config: {e}")


def bootstrap_cluster(
    controlplane_ip: str,
    kubeconfig_path: str,
    talosctl_path: str = "talosctl",
    insecure: bool = True
) -> bool:
    """
    Bootstrap a Talos Kubernetes cluster.

    Args:
        controlplane_ip: IP of the first control plane node
        kubeconfig_path: Path where kubeconfig will be written
        talosctl_path: Path to talosctl binary
        insecure: Skip TLS verification

    Returns:
        True if successful, False otherwise
    """
    try:
        cmd = [
            talosctl_path, '--nodes', controlplane_ip,
            'bootstrap',
            '--kubeconfig', kubeconfig_path
        ]
        if insecure:
            cmd.append('--insecure')

        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise TalosError(f"talosctl bootstrap failed: {result.stderr}")

        return True

    except Exception as e:
        raise TalosError(f"Failed to bootstrap cluster: {e}")


def get_cluster_info(kubeconfig_path: Optional[str] = None) -> Dict:
    """
    Get Talos cluster information.

    Args:
        kubeconfig_path: Optional path to kubeconfig

    Returns:
        Dictionary with cluster info
    """
    try:
        cmd = ['talosctl', 'cluster', 'info', '--output', 'json']
        if kubeconfig_path:
            cmd.extend(['--kubeconfig', kubeconfig_path])

        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        raise TalosError(f"Failed to get cluster info: {e.stderr}")
    except json.JSONDecodeError as e:
        raise TalosError(f"Failed to parse cluster info: {e}")


def get_nodes_info(kubeconfig_path: Optional[str] = None) -> List[Dict]:
    """
    Get information about all Talos nodes.

    Args:
        kubeconfig_path: Optional path to kubeconfig

    Returns:
        List of node information dictionaries
    """
    try:
        cmd = ['talosctl', 'get', 'nodes', '--output', 'json']
        if kubeconfig_path:
            cmd.extend(['--kubeconfig', kubeconfig_path])

        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        raise TalosError(f"Failed to get nodes: {e.stderr}")
    except json.JSONDecodeError as e:
        raise TalosError(f"Failed to parse node info: {e}")


def join_controlplane(
    node_ip: str,
    controlplane_endpoint: str,
    token: str,
    talosctl_path: str = "talosctl",
    insecure: bool = True
) -> bool:
    """
    Join a control plane node to an existing cluster.

    Args:
        node_ip: IP address of the node to join
        controlplane_endpoint: Endpoint of existing control plane
        token: Join token from bootstrap
        talosctl_path: Path to talosctl binary
        insecure: Skip TLS verification

    Returns:
        True if successful
    """
    try:
        cmd = [
            talosctl_path, '--nodes', node_ip,
            'join', controlplane_endpoint,
            '--token', token
        ]
        if insecure:
            cmd.append('--insecure')

        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise TalosError(f"Failed to join control plane: {result.stderr}")

        return True

    except Exception as e:
        raise TalosError(f"Failed to join control plane: {e}")


def join_worker(
    node_ip: str,
    controlplane_endpoint: str,
    token: str,
    talosctl_path: str = "talosctl",
    insecure: bool = True
) -> bool:
    """
    Join a worker node to an existing cluster.

    Args:
        node_ip: IP address of the node to join
        controlplane_endpoint: Endpoint of control plane
        token: Join token
        talosctl_path: Path to talosctl binary
        insecure: Skip TLS verification

    Returns:
        True if successful
    """
    try:
        cmd = [
            talosctl_path, '--nodes', node_ip,
            'join', controlplane_endpoint,
            '--worker',
            '--token', token
        ]
        if insecure:
            cmd.append('--insecure')

        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            raise TalosError(f"Failed to join worker: {result.stderr}")

        return True

    except Exception as e:
        raise TalosError(f"Failed to join worker: {e}")


def generate_apply_config(
    node_name: str,
    node_ip: str,
    role: str,
    cluster_name: str,
    output_path: str,
    **kwargs
) -> str:
    """
    Generate Talos configuration and write to file.

    Args:
        node_name: Name of the node
        node_ip: IP address
        role: Node role
        cluster_name: Cluster name
        output_path: Path to write config file
        **kwargs: Additional config options

    Returns:
        Path to written config file
    """
    config = generate_config(
        node_name=node_name,
        node_ip=node_ip,
        role=role,
        cluster_name=cluster_name,
        **kwargs
    )

    yaml_str = generate_config_yaml(config)

    with open(output_path, 'w') as f:
        f.write(yaml_str)

    return output_path


def check_node_ready(node_ip: str, talosctl_path: str = "talosctl", timeout: int = 300) -> bool:
    """
    Check if a Talos node is ready.

    Args:
        node_ip: IP address of the node
        talosctl_path: Path to talosctl binary
        timeout: Timeout in seconds

    Returns:
        True if node is ready, False otherwise
    """
    import time
    start_time = time.time()

    while time.time() - start_time < timeout:
        try:
            cmd = [talosctl_path, '--nodes', node_ip, 'get', 'disks', '--output', 'json']
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            # If command succeeds, node is accessible
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            time.sleep(5)
            continue

    return False
