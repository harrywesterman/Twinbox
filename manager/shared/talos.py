"""
Talos Linux integration module for Twinbox.

This module provides a Python wrapper around talosctl commands for managing
Talos Linux nodes, generating configurations, and bootstrapping Kubernetes clusters.

Typical usage:
    >>> from manager.shared.talos import TalosManager
    >>> talos = TalosManager()
    >>> talos.wait_for_ready("192.168.1.10", timeout=600)
    >>> config = talos.gen_config(cluster_name="mycluster", endpoint="192.168.1.10")
"""

import os
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional, Any
import yaml


class TalosError(Exception):
    """Base exception for Talos operations."""
    pass


class TalosTimeoutError(TalosError):
    """Raised when Talos operation times out."""
    pass


class TalosConfig:
    """Configuration for Talos operations."""

    def __init__(
        self,
        cluster_name: str,
        endpoint: str,
        pod_cidr: str = "10.244.0.0/16",
        service_cidr: str = "10.96.0.0/12",
        version: str = "v1.5.0",
    ) -> None:
        """
        Initialize Talos configuration.

        Args:
            cluster_name: Name of the Kubernetes cluster
            endpoint: Control plane endpoint IP/hostname
            pod_cidr: Pod network CIDR
            service_cidr: Service network CIDR
            version: Talos version to use
        """
        self.cluster_name = cluster_name
        self.endpoint = endpoint
        self.pod_cidr = pod_cidr
        self.service_cidr = service_cidr
        self.version = version

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "cluster_name": self.cluster_name,
            "endpoint": self.endpoint,
            "pod_cidr": self.pod_cidr,
            "service_cidr": self.service_cidr,
            "version": self.version,
        }


class TalosManager:
    """
    Manager for Talos Linux operations.

    Wraps talosctl commands with proper error handling, logging, and
    configuration management. Used by RQ worker tasks to perform
    cluster initialization and configuration.

    Attributes:
        talosctl_path: Path to talosctl binary (default: "talosctl")
        config_dir: Directory for storing generated configs
        timeout: Default timeout for operations in seconds
    """

    def __init__(
        self,
        talosctl_path: str = "talosctl",
        config_dir: str = "/config/talos",
        timeout: int = 600,
    ) -> None:
        """
        Initialize TalosManager.

        Args:
            talosctl_path: Path to talosctl binary
            config_dir: Directory to store generated configuration files
            timeout: Default timeout for wait operations in seconds
        """
        self.talosctl_path = talosctl_path
        self.config_dir = Path(config_dir)
        self.timeout = timeout

        # Ensure config directory exists
        self.config_dir.mkdir(parents=True, exist_ok=True)

    def _run_command(
        self,
        args: List[str],
        timeout: Optional[int] = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess:
        """
        Run a talosctl command with error handling.

        Args:
            args: Command arguments (without 'talosctl' prefix)
            timeout: Command timeout in seconds (uses default if None)
            check: Raise CalledProcessError if command fails

        Returns:
            CompletedProcess instance

        Raises:
            TalosError: If command fails or talosctl not found
            subprocess.CalledProcessError: If command returns non-zero (when check=True)
        """
        cmd = [self.talosctl_path] + args
        timeout_sec = timeout if timeout is not None else self.timeout

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout_sec,
                check=check,
            )
            return result
        except subprocess.TimeoutExpired as e:
            raise TalosTimeoutError(f"Talos command timed out after {timeout_sec}s: {e}")
        except FileNotFoundError:
            raise TalosError(f"talosctl binary not found at: {self.talosctl_path}")
        except subprocess.CalledProcessError as e:
            error_msg = f"Command failed: {' '.join(cmd)}\nExit code: {e.returncode}\nStdout: {e.stdout}\nStderr: {e.stderr}"
            raise TalosError(error_msg)

    def wait_for_ready(
        self,
        node_ip: str,
        timeout: Optional[int] = None,
        poll_interval: int = 5,
    ) -> bool:
        """
        Wait for a Talos node to be ready (API accessible).

        Polls the Talos API on the node until it responds or timeout.

        Args:
            node_ip: IP address of the Talos node
            timeout: Maximum wait time in seconds (uses default if None)
            poll_interval: Polling interval in seconds

        Returns:
            True if node is ready within timeout

        Raises:
            TalosTimeoutError: If node doesn't become ready in time
            TalosError: If talosctl command fails
        """
        timeout_sec = timeout if timeout is not None else self.timeout
        start_time = time.time()

        while time.time() - start_time < timeout_sec:
            try:
                # Use talosctl health to check node readiness
                # talosctl --nodes <ip> health
                result = self._run_command(
                    ["--nodes", node_ip, "health"],
                    timeout=poll_interval,
                    check=False,
                )

                if result.returncode == 0:
                    # Parse output - if it contains "healthy", node is ready
                    if "healthy" in result.stdout.lower():
                        return True

            except TalosError:
                # Expected during startup, continue polling
                pass

            time.sleep(poll_interval)

        raise TalosTimeoutError(
            f"Node {node_ip} did not become ready within {timeout_sec}s"
        )

    def gen_config(
        self,
        cluster_name: str,
        endpoint: str,
        output_dir: Optional[str] = None,
        pod_cidr: Optional[str] = None,
        service_cidr: Optional[str] = None,
        version: Optional[str] = None,
    ) -> Dict[str, str]:
        """
        Generate Talos configuration files for a cluster.

        Runs `talosctl gen config` to create machine configurations
        and stores them in the specified directory.

        Args:
            cluster_name: Name of the cluster
            endpoint: Control plane endpoint IP/hostname
            output_dir: Directory to write configs (defaults to self.config_dir)
            pod_cidr: Pod network CIDR (default from TalosConfig)
            service_cidr: Service network CIDR (default from TalosConfig)
            version: Talos version (default from TalosConfig)

        Returns:
            Dictionary mapping config types to file paths:
            {
                "controlplane": "/path/to/controlplane.yaml",
                "worker": "/path/to/worker.yaml",
                "etcd": "/path/to/etcd.yaml"  # if applicable
            }

        Raises:
            TalosError: If config generation fails
        """
        output_path = Path(output_dir) if output_dir else self.config_dir
        output_path.mkdir(parents=True, exist_ok=True)

        args = [
            "gen",
            "config",
            cluster_name,
            f"--endpoint={endpoint}",
            f"--output-dir={str(output_path)}",
        ]

        if pod_cidr:
            args.append(f"--pod-cidr={pod_cidr}")
        if service_cidr:
            args.append(f"--service-cidr={service_cidr}")
        if version:
            args.append(f"--version={version}")

        try:
            self._run_command(args)
        except TalosError as e:
            raise TalosError(f"Failed to generate Talos config: {e}")

        # Return paths to generated files
        configs = {
            "controlplane": str(output_path / "controlplane.yaml"),
            "worker": str(output_path / "worker.yaml"),
        }

        # Check that files were created
        for key, path in configs.items():
            if not Path(path).exists():
                raise TalosError(f"Expected config file not created: {path}")

        return configs

    def apply_config(
        self,
        node_ip: str,
        config_file: str,
        wait: bool = True,
        timeout: Optional[int] = None,
    ) -> bool:
        """
        Apply a Talos configuration to a node.

        Args:
            node_ip: IP address of the target Talos node
            config_file: Path to the Talos configuration YAML
            wait: Whether to wait for the operation to complete
            timeout: Timeout in seconds for wait (uses default if None)

        Returns:
            True if configuration applied successfully

        Raises:
            TalosError: If application fails
            TalosTimeoutError: If wait times out
        """
        if not Path(config_file).exists():
            raise TalosError(f"Config file not found: {config_file}")

        args = [
            "--nodes",
            node_ip,
            "apply-config",
            "--file",
            config_file,
        ]

        if wait:
            args.append("--wait")

        try:
            timeout_sec = timeout if timeout is not None else self.timeout
            self._run_command(args, timeout=timeout_sec)
            return True
        except TalosError as e:
            raise TalosError(f"Failed to apply config to {node_ip}: {e}")

    def bootstrap(
        self,
        node_ip: str,
        control_plane_endpoint: Optional[str] = None,
    ) -> bool:
        """
        Bootstrap the Kubernetes cluster on a control plane node.

        Args:
            node_ip: IP address of the first control plane node
            control_plane_endpoint: Endpoint for the Kubernetes API
                (defaults to node_ip)

        Returns:
            True if bootstrap succeeded

        Raises:
            TalosError: If bootstrap fails
        """
        args = [
            "--nodes",
            node_ip,
            "bootstrap",
        ]

        if control_plane_endpoint:
            args.extend(["--endpoint", control_plane_endpoint])

        try:
            self._run_command(args, timeout=self.timeout * 2)  # Bootstrap can take longer
            return True
        except TalosError as e:
            raise TalosError(f"Failed to bootstrap cluster: {e}")

    def get_kubeconfig(
        self,
        output_file: str,
        node_ip: str,
        cluster_name: Optional[str] = None,
    ) -> str:
        """
        Retrieve and save the Kubernetes kubeconfig from a Talos cluster.

        Args:
            output_file: Path where kubeconfig will be written
            node_ip: IP address of a control plane node
            cluster_name: Cluster name (defaults to configured cluster)

        Returns:
            Path to the saved kubeconfig file

        Raises:
            TalosError: If kubeconfig retrieval fails
        """
        args = [
            "kubeconfig",
            f"--nodes={node_ip}",
            f"--output={output_file}",
        ]

        if cluster_name:
            args.append(f"--cluster={cluster_name}")

        try:
            self._run_command(args)
            return output_file
        except TalosError as e:
            raise TalosError(f"Failed to get kubeconfig: {e}")

    def get_nodes(
        self,
        node_ip: str,
        format: str = "json",
    ) -> List[Dict[str, Any]]:
        """
        Get information about Talos nodes in the cluster.

        Args:
            node_ip: IP address of any control plane node
            format: Output format ("json", "yaml", "table")

        Returns:
            List of node information dictionaries

        Raises:
            TalosError: If query fails
        """
        args = [
            "--nodes",
            node_ip,
            "get",
            "nodes",
            f"--output={format}",
        ]

        try:
            result = self._run_command(args)
            if format == "json":
                import json
                return json.loads(result.stdout)
            elif format == "yaml":
                return yaml.safe_load(result.stdout)
            else:
                # Return raw output for table format
                return [{"raw": result.stdout}]
        except (TalosError, ValueError) as e:
            raise TalosError(f"Failed to get node information: {e}")

    def upgrade_apply(
        self,
        node_ip: str,
        version: str,
        wait: bool = True,
    ) -> bool:
        """
        Upgrade Talos on a node to a specific version.

        Args:
            node_ip: IP address of the node to upgrade
            version: Target Talos version (e.g., "v1.5.0")
            wait: Whether to wait for upgrade completion

        Returns:
            True if upgrade succeeded

        Raises:
            TalosError: If upgrade fails
        """
        args = [
            "--nodes",
            node_ip,
            "upgrade",
            "apply",
            f"--version={version}",
        ]

        if wait:
            args.append("--wait")

        try:
            self._run_command(args, timeout=self.timeout * 3)  # Upgrades can take a while
            return True
        except TalosError as e:
            raise TalosError(f"Failed to upgrade node {node_ip}: {e}")

    def reset_node(
        self,
        node_ip: str,
        *,
        dangerous: bool = False,
    ) -> bool:
        """
        Reset a Talos node to factory state.

        Args:
            node_ip: IP address of the node to reset
            dangerous: Required flag to acknowledge data loss

        Returns:
            True if reset succeeded

        Raises:
            TalosError: If reset fails or dangerous not set
        """
        args = [
            "--nodes",
            node_ip,
            "reset",
        ]

        if dangerous:
            args.append("--dangerous")
        else:
            raise TalosError("Must set dangerous=True to reset node (acknowledge data loss)")

        try:
            self._run_command(args)
            return True
        except TalosError as e:
            raise TalosError(f"Failed to reset node {node_ip}: {e}")

    def __repr__(self) -> str:
        return f"TalosManager(talosctl={self.talosctl_path}, config_dir={self.config_dir})"
