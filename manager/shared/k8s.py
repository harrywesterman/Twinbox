"""
Kubernetes operations module for Twinbox.

This module provides a Python wrapper around kubectl commands for installing
and managing Kubernetes addons like CNI, MetalLB, Traefik, and monitoring stacks.

Typical usage:
    >>> from manager.shared.k8s import K8sManager
    >>> k8s = K8sManager("/config/kubeconfig")
    >>> k8s.install_calico()
    >>> k8s.install_metallb("192.168.1.200-192.168.1.250")
"""

import os
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional, Any, Union
import yaml
import json


class K8sError(Exception):
    """Base exception for Kubernetes operations."""
    pass


class K8sTimeoutError(K8sError):
    """Raised when Kubernetes operation times out."""
    pass


class K8sManager:
    """
    Manager for Kubernetes cluster operations.

    Wraps kubectl commands with proper error handling, waiting for resource
    readiness, and manifest application. Used by RQ worker tasks to install
    and configure Kubernetes components.

    Attributes:
        kubeconfig_path: Path to kubeconfig file
        kubectl_path: Path to kubectl binary (default: "kubectl")
        context: Kubernetes context to use (default from kubeconfig)
        timeout: Default timeout for operations in seconds
    """

    def __init__(
        self,
        kubeconfig_path: str,
        kubectl_path: str = "kubectl",
        context: Optional[str] = None,
        timeout: int = 600,
    ) -> None:
        """
        Initialize K8sManager.

        Args:
            kubeconfig_path: Path to kubeconfig file
            kubectl_path: Path to kubectl binary
            context: Kubernetes context name (uses current context if None)
            timeout: Default timeout for operations in seconds
        """
        self.kubeconfig_path = Path(kubeconfig_path)
        self.kubectl_path = kubectl_path
        self.context = context
        self.timeout = timeout

        if not self.kubeconfig_path.exists():
            raise K8sError(f"Kubeconfig not found: {self.kubeconfig_path}")

    def _build_args(self, extra_args: List[str]) -> List[str]:
        """Build kubectl command arguments with kubeconfig and context."""
        args = [self.kubectl_path, "--kubeconfig", str(self.kubeconfig_path)]
        if self.context:
            args.extend(["--context", self.context])
        args.extend(extra_args)
        return args

    def _run_command(
        self,
        args: List[str],
        timeout: Optional[int] = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess:
        """
        Run a kubectl command with error handling.

        Args:
            args: Command arguments (without 'kubectl' prefix, kubeconfig added automatically)
            timeout: Command timeout in seconds (uses default if None)
            check: Raise CalledProcessError if command fails

        Returns:
            CompletedProcess instance

        Raises:
            K8sError: If command fails or kubectl not found
            subprocess.CalledProcessError: If command returns non-zero (when check=True)
        """
        cmd = self._build_args(args)
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
        except subprocess.TimeoutExpired:
            raise K8sTimeoutError(f"kubectl command timed out after {timeout_sec}s: {' '.join(cmd)}")
        except FileNotFoundError:
            raise K8sError(f"kubectl binary not found at: {self.kubectl_path}")
        except subprocess.CalledProcessError as e:
            error_msg = f"Command failed: {' '.join(cmd)}\nExit code: {e.returncode}\nStdout: {e.stdout}\nStderr: {e.stderr}"
            raise K8sError(error_msg)

    def apply_manifest(
        self,
        manifest_path: str,
        wait: bool = True,
        timeout: Optional[int] = None,
    ) -> bool:
        """
        Apply a Kubernetes manifest using kubectl apply.

        Args:
            manifest_path: Path to YAML manifest file
            wait: Whether to wait for resources to be ready
            timeout: Timeout in seconds for waiting (uses default if None)

        Returns:
            True if manifest applied successfully

        Raises:
            K8sError: If application fails
            K8sTimeoutError: If wait times out
        """
        if not Path(manifest_path).exists():
            raise K8sError(f"Manifest file not found: {manifest_path}")

        # Apply the manifest
        self._run_command(["apply", "-f", manifest_path])

        if wait:
            # Wait for all resources in the manifest to be ready
            self._wait_for_manifest_resources(manifest_path, timeout)

        return True

    def _wait_for_manifest_resources(
        self,
        manifest_path: str,
        timeout: Optional[int] = None,
    ) -> None:
        """
        Wait for all resources defined in a manifest to be ready.

        Parses the manifest to identify resource types that support readiness
        (Deployments, StatefulSets, DaemonSets, etc.) and waits for them.

        Args:
            manifest_path: Path to YAML manifest
            timeout: Timeout in seconds

        Raises:
            K8sTimeoutError: If resources don't become ready in time
        """
        timeout_sec = timeout if timeout is not None else self.timeout
        start_time = time.time()

        # Parse manifest to get resource types and names
        resources = self._parse_manifest_resources(manifest_path)

        # Wait for each resource type
        for resource in resources:
            kind = resource["kind"]
            name = resource["name"]
            namespace = resource.get("namespace", "default")

            if kind in ("Deployment", "StatefulSet", "DaemonSet"):
                self._wait_for_deployment_ready(namespace, name, timeout_sec)
            elif kind == "Pod":
                self._wait_for_pod_running(namespace, name, timeout_sec)
            # For other resource types (Service, ConfigMap, etc.), no readiness check

    def _parse_manifest_resources(self, manifest_path: str) -> List[Dict[str, Any]]:
        """Parse a manifest file and extract resource metadata."""
        resources = []
        try:
            with open(manifest_path) as f:
                docs = yaml.safe_load_all(f)
                for doc in docs:
                    if doc is None:
                        continue
                    resources.append({
                        "kind": doc.get("kind", ""),
                        "name": doc.get("metadata", {}).get("name", ""),
                        "namespace": doc.get("metadata", {}).get("namespace", "default"),
                    })
        except Exception as e:
            raise K8sError(f"Failed to parse manifest {manifest_path}: {e}")

        return resources

    def _wait_for_deployment_ready(
        self,
        namespace: str,
        deployment_name: str,
        timeout: int,
    ) -> None:
        """
        Wait for a Deployment to have all replicas ready.

        Args:
            namespace: Kubernetes namespace
            deployment_name: Name of the Deployment
            timeout: Timeout in seconds

        Raises:
            K8sTimeoutError: If deployment doesn't become ready in time
        """
        end_time = time.time() + timeout

        while time.time() < end_time:
            try:
                result = self._run_command([
                    "get",
                    "deployment",
                    deployment_name,
                    "-n", namespace,
                    "-o",
                    "jsonpath={.status.readyReplicas}/{.status.replicas}",
                ], check=False)

                if result.returncode == 0:
                    ready, total = map(int, result.stdout.strip().split("/"))
                    if ready == total and total > 0:
                        return  # Ready

            except K8sError:
                pass  # Expected during startup

            time.sleep(5)

        raise K8sTimeoutError(
            f"Deployment {namespace}/{deployment_name} did not become ready within {timeout}s"
        )

    def _wait_for_pod_running(
        self,
        namespace: str,
        pod_name: str,
        timeout: int,
    ) -> None:
        """
        Wait for a specific Pod to be in Running state.

        Args:
            namespace: Kubernetes namespace
            pod_name: Name of the Pod
            timeout: Timeout in seconds

        Raises:
            K8sTimeoutError: If pod doesn't become Running in time
        """
        end_time = time.time() + timeout

        while time.time() < end_time:
            try:
                result = self._run_command([
                    "get",
                    "pod",
                    pod_name,
                    "-n", namespace,
                    "-o",
                    "jsonpath={.status.phase}",
                ], check=False)

                if result.returncode == 0:
                    phase = result.stdout.strip()
                    if phase == "Running":
                        return

            except K8sError:
                pass

            time.sleep(5)

        raise K8sTimeoutError(
            f"Pod {namespace}/{pod_name} did not reach Running state within {timeout}s"
        )

    def wait_for_nodes_ready(
        self,
        expected_count: int,
        timeout: Optional[int] = None,
        node_selector: Optional[str] = None,
    ) -> bool:
        """
        Wait for all expected nodes to be in Ready state.

        Args:
            expected_count: Number of Ready nodes expected
            timeout: Timeout in seconds (uses default if None)
            node_selector: Label selector to filter nodes

        Returns:
            True if all nodes become Ready within timeout

        Raises:
            K8sTimeoutError: If not all nodes become Ready in time
        """
        timeout_sec = timeout if timeout is not None else self.timeout
        end_time = time.time() + timeout_sec

        while time.time() < end_time:
            try:
                args = ["get", "nodes"]
                if node_selector:
                    args.extend(["-l", node_selector])

                result = self._run_command(args + ["-o", "json"])

                import json
                nodes_data = json.loads(result.stdout)
                ready_count = 0

                for node in nodes_data.get("items", []):
                    conditions = node.get("status", {}).get("conditions", [])
                    for condition in conditions:
                        if condition.get("type") == "Ready" and condition.get("status") == "True":
                            ready_count += 1
                            break

                if ready_count >= expected_count:
                    return True

            except K8sError:
                pass

            time.sleep(5)

        raise K8sTimeoutError(
            f"Only {ready_count}/{expected_count} nodes became Ready within {timeout_sec}s"
        )

    def install_calico(
        self,
        pod_cidr: str = "10.244.0.0/16",
        service_cidr: str = "10.96.0.0/12",
        version: str = "v1.28.0",
        wait: bool = True,
    ) -> bool:
        """
        Install Calico CNI plugin.

        Downloads and applies the Calico manifest for the given Kubernetes version.

        Args:
            pod_cidr: Pod network CIDR
            service_cidr: Service network CIDR (not used by Calico)
            version: Kubernetes version (determines which manifest to use)
            wait: Whether to wait for Calico pods to be ready

        Returns:
            True if installation succeeded

        Raises:
            K8sError: If installation fails
            K8sTimeoutError: If wait times out
        """
        # Construct Calico manifest URL based on version
        manifest_url = f"https://projectcalico.docs.tigera.io/manifests/calico.yaml"

        try:
            # Download manifest to temporary location
            import tempfile
            with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
                temp_path = f.name

            # Download using curl or wget
            self._download_file(manifest_url, temp_path)

            # Apply the manifest
            self._run_command(["apply", "-f", temp_path])

            # Clean up
            Path(temp_path).unlink(missing_ok=True)

            if wait:
                # Wait for Calico pods in kube-system to be ready
                self._wait_for_namespace_pods_ready("kube-system", timeout=self.timeout)

            return True

        except Exception as e:
            raise K8sError(f"Failed to install Calico: {e}")

    def _download_file(self, url: str, dest_path: str) -> None:
        """Download a file from URL to destination."""
        try:
            import urllib.request
            urllib.request.urlretrieve(url, dest_path)
        except Exception as e:
            raise K8sError(f"Failed to download {url}: {e}")

    def _wait_for_namespace_pods_ready(
        self,
        namespace: str,
        timeout: int,
        label_selector: Optional[str] = None,
    ) -> None:
        """
        Wait for all pods in a namespace to be ready.

        Args:
            namespace: Namespace to check
            timeout: Timeout in seconds
            label_selector: Optional label selector to filter pods

        Raises:
            K8sTimeoutError: If pods don't all become ready in time
        """
        end_time = time.time() + timeout

        while time.time() < end_time:
            try:
                args = ["get", "pods", "-n", namespace, "-o", "json"]
                if label_selector:
                    args.extend(["-l", label_selector])

                result = self._run_command(args)
                import json
                pods_data = json.loads(result.stdout)

                all_ready = True
                for pod in pods_data.get("items", []):
                    # Skip terminated pods
                    phase = pod.get("status", {}).get("phase")
                    if phase == "Succeeded":
                        continue
                    if phase == "Failed":
                        all_ready = False
                        break

                    # Check ready condition
                    container_statuses = pod.get("status", {}).get("containerStatuses", [])
                    ready_count = sum(1 for cs in container_statuses if cs.get("ready"))
                    total_count = len(container_statuses)

                    if ready_count < total_count:
                        all_ready = False
                        break

                if all_ready:
                    return

            except K8sError:
                pass

            time.sleep(5)

        raise K8sTimeoutError(
            f"Not all pods in namespace {namespace} became ready within {timeout}s"
        )

    def install_metallb(
        self,
        ip_range: str,
        version: str = "0.13.10",
        wait: bool = True,
    ) -> bool:
        """
        Install MetalLB load balancer.

        Installs MetalLB manifests and configures the IP address pool.

        Args:
            ip_range: IP address pool in CIDR notation or range (e.g., "192.168.1.200-192.168.1.250")
            version: MetalLB version to install
            wait: Whether to wait for MetalLB pods to be ready

        Returns:
            True if installation succeeded

        Raises:
            K8sError: If installation fails
            K8sTimeoutError: If wait times out
        """
        try:
            # First, apply MetalLB manifests (manifests from official repo)
            manifest_url = f"https://raw.githubusercontent.com/metallb/metallb/v{version}/config/manifests/metallb-native.yaml"

            import tempfile
            with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
                temp_manifest = f.name

            self._download_file(manifest_url, temp_manifest)
            self._run_command(["apply", "-f", temp_manifest])
            Path(temp_manifest).unlink(missing_ok=True)

            if wait:
                # Wait for MetalLB pods in metallb-system
                self._wait_for_namespace_pods_ready("metallb-system", timeout=self.timeout)

            # Create IPAddressPool and L2Advertisement config
            config = self._build_metallb_config(ip_range)

            with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
                config_path = f.name
                yaml.dump(config, f, default_flow_style=False)

            self._run_command(["apply", "-f", config_path])
            Path(config_path).unlink(missing_ok=True)

            return True

        except Exception as e:
            raise K8sError(f"Failed to install MetalLB: {e}")

    def _build_metallb_config(self, ip_range: str) -> Dict[str, Any]:
        """
        Build MetalLB IPAddressPool and L2Advertisement configuration.

        Args:
            ip_range: IP address range (e.g., "192.168.1.200-192.168.1.250")

        Returns:
            Dictionary representing the YAML configuration (list of resources)
        """
        # Parse IP range
        if "-" in ip_range:
            start_ip, end_ip = ip_range.split("-")
        else:
            # Single CIDR notation - use whole range
            start_ip = ip_range
            end_ip = self._get_last_ip_in_cidr(ip_range)

        config_ip = f"{start_ip}-{end_ip}"

        config = [
            {
                "apiVersion": "metallb.io/v1beta1",
                "kind": "IPAddressPool",
                "metadata": {
                    "name": "default-pool",
                    "namespace": "metallb-system",
                },
                "spec": {
                    "addresses": [config_ip],
                },
            },
            {
                "apiVersion": "metallb.io/v1beta1",
                "kind": "L2Advertisement",
                "metadata": {
                    "name": "default-advertisement",
                    "namespace": "metallb-system",
                },
                "spec": {
                    "interface": "",  # Empty means all interfaces
                },
            },
        ]

        return config

    def _get_last_ip_in_cidr(self, cidr: str) -> str:
        """Get the last usable IP in a CIDR block."""
        import ipaddress
        network = ipaddress.IPv4Network(cidr, strict=False)
        # Return last host IP (excluding network and broadcast)
        hosts = list(network.hosts())
        if hosts:
            return str(hosts[-1])
        raise ValueError(f"No usable hosts in CIDR: {cidr}")

    def install_traefik(
        self,
        traefik_image: str = "traefik:v2.10",
        service_type: str = "LoadBalancer",
        wait: bool = True,
    ) -> str:
        """
        Install Traefik ingress controller.

        Deploys Traefik as a Deployment with a LoadBalancer Service.
        Optionally waits for the LoadBalancer IP to be allocated.

        Args:
            traefik_image: Docker image for Traefik
            service_type: Kubernetes Service type (LoadBalancer, NodePort, etc.)
            wait: Whether to wait for LoadBalancer IP assignment

        Returns:
            LoadBalancer IP address (if wait=True and Service gets one)

        Raises:
            K8sError: If installation fails
            K8sTimeoutError: If wait times out
        """
        try:
            # Apply Traefik manifest from twinbox configs
            traefik_manifest = "/app/twinbox/k8s/apps/traefik.yaml"

            if not Path(traefik_manifest).exists():
                # Try relative paths
                traefik_manifest = "twinbox/k8s/apps/traefik.yaml"
                if not Path(traefik_manifest).exists():
                    raise K8sError(f"Traefik manifest not found at {traefik_manifest}")

            self._run_command(["apply", "-f", traefik_manifest])

            if wait:
                # Wait for Traefik deployment to be ready
                self._wait_for_deployment_ready("traefik", "traefik", self.timeout)

                # Wait for LoadBalancer service to get an external IP
                traefik_ip = self._wait_for_service_loadbalancer(
                    "traefik",
                    "traefik",
                    self.timeout,
                )

                return traefik_ip

            return ""

        except Exception as e:
            raise K8sError(f"Failed to install Traefik: {e}")

    def _wait_for_service_loadbalancer(
        self,
        namespace: str,
        service_name: str,
        timeout: int,
    ) -> str:
        """
        Wait for a Service of type LoadBalancer to get an external IP.

        Args:
            namespace: Service namespace
            service_name: Service name
            timeout: Timeout in seconds

        Returns:
            External IP address of the LoadBalancer

        Raises:
            K8sTimeoutError: If no external IP allocated in time
        """
        end_time = time.time() + timeout

        while time.time() < end_time:
            try:
                result = self._run_command([
                    "get",
                    "service",
                    service_name,
                    "-n", namespace,
                    "-o",
                    "jsonpath={.status.loadBalancer.ingress[0].ip}",
                ], check=False)

                if result.returncode == 0:
                    ip = result.stdout.strip()
                    if ip:
                        return ip

            except K8sError:
                pass

            time.sleep(5)

        raise K8sTimeoutError(
            f"Service {namespace}/{service_name} did not get LoadBalancer IP within {timeout}s"
        )

    def get_nodes(
        self,
        format: str = "json",
        label_selector: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        """
        Get information about Kubernetes nodes.

        Args:
            format: Output format ("json", "yaml", "wide", "custom")
            label_selector: Label selector to filter nodes

        Returns:
            List of node information dictionaries (for json/yaml) or raw output
        """
        args = ["get", "nodes"]
        if label_selector:
            args.extend(["-l", label_selector])
        args.extend(["-o", format])

        result = self._run_command(args)

        if format == "json":
            import json
            return json.loads(result.stdout).get("items", [])
        elif format == "yaml":
            import yaml
            return yaml.safe_load(result.stdout).get("items", [])
        else:
            return [{"raw": result.stdout}]

    def cluster_info(self) -> Dict[str, Any]:
        """
        Get cluster information summary.

        Returns:
            Dictionary with cluster info: version, node count, pod counts, etc.

        Raises:
            K8sError: If query fails
        """
        # Get cluster version
        version_result = self._run_command(["version", "-o", "json"])
        import json
        version_data = json.loads(version_result.stdout)

        # Get nodes
        nodes = self.get_nodes(format="json")

        # Get pods
        pods_result = self._run_command(["get", "pods", "--all-namespaces", "-o", "json"])
        pods_data = json.loads(pods_result.stdout)

        return {
            "kubernetes_version": version_data.get("serverVersion", {}).get("gitVersion", "unknown"),
            "node_count": len(nodes),
            "pod_count": len(pods_data.get("items", [])),
            "nodes": [
                {
                    "name": node.get("metadata", {}).get("name"),
                    "status": next(
                        (cond.get("status") for cond in node.get("status", {}).get("conditions", [])
                         if cond.get("type") == "Ready"),
                        "Unknown"
                    ),
                    "os_image": node.get("status", {}).get("nodeInfo", {}).get("osImage"),
                    "kernel_version": node.get("status", {}).get("nodeInfo", {}).get("kernelVersion"),
                }
                for node in nodes
            ],
        }

    def delete_namespace(
        self,
        namespace: str,
        wait: bool = False,
    ) -> bool:
        """
        Delete a Kubernetes namespace and all contained resources.

        Args:
            namespace: Namespace to delete
            wait: Whether to wait for deletion to complete

        Returns:
            True if deletion succeeded

        Raises:
            K8sError: If deletion fails
        """
        self._run_command(["delete", "namespace", namespace])

        if wait:
            # Wait for namespace to be fully removed
            end_time = time.time() + self.timeout
            while time.time() < end_time:
                try:
                    self._run_command(["get", "namespace", namespace], check=False)
                except K8sError:
                    # Namespace not found = deletion complete
                    return True
                time.sleep(5)

            raise K8sTimeoutError(f"Namespace {namespace} did not delete within {self.timeout}s")

        return True

    def __repr__(self) -> str:
        return f"K8sManager(kubeconfig={self.kubeconfig_path}, context={self.context or 'default'})"
