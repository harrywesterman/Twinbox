"""
Proxmox VE API client for Twinbox TUI.

This module provides a Python client for interacting with the Proxmox VE REST API.
It handles token-based authentication, request retry logic, and provides VM lifecycle
management and cluster discovery.

Adapted from manager/shared/proxmox.py for use in the TUI application.

Typical usage:
    >>> from twinbox_tui.proxmox import ProxmoxAPI
    >>> api = ProxmoxAPI(base_url, token_name, token_value)
    >>> nodes = api.list_nodes()
    >>> vm_id = api.create_vm(name="twinbox-mgmt", node="pve1", ...)
"""

import os
import time
from typing import Any, Dict, List, Optional

import httpx
from httpx import Response, TimeoutException, HTTPStatusError


class ProxmoxAPIError(Exception):
    """Base exception for Proxmox API errors."""
    pass


class AuthenticationError(ProxmoxAPIError):
    """Raised when authentication with Proxmox fails."""
    pass


class ResourceNotFoundError(ProxmoxAPIError):
    """Raised when a requested resource (node, VM, etc.) is not found."""
    pass


class ProxmoxAPI:
    """
    Client for the Proxmox VE REST API.

    Handles token-based authentication, request retry logic, and provides
    convenience methods for VM lifecycle management and cluster discovery.

    Attributes:
        base_url: Proxmox API endpoint (e.g., "https://pve-host:8006/api2/json")
        token_name: API token name (e.g., "twinbox@pve!token-id")
        token_value: API token secret
        verify_ssl: Whether to verify SSL certificates (default: True)
        timeout: Request timeout in seconds (default: 30)
        max_retries: Maximum number of retry attempts (default: 3)
        backoff_factor: Exponential backoff multiplier (default: 1)
    """

    def __init__(
        self,
        base_url: str,
        token_name: str,
        token_value: str,
        verify_ssl: bool = True,
        timeout: float = 30.0,
        max_retries: int = 3,
        backoff_factor: float = 1.0,
    ) -> None:
        """
        Initialize ProxmoxAPI client.

        Args:
            base_url: Proxmox API endpoint (e.g., "https://192.168.1.10:8006/api2/json")
            token_name: API token name in format "user@pve!tokenid"
            token_value: API token secret value
            verify_ssl: Verify SSL certificates (set False for self-signed certs)
            timeout: Request timeout in seconds
            max_retries: Maximum number of retry attempts for failed requests
            backoff_factor: Exponential backoff multiplier (e.g., 1.0, 2.0)
        """
        self.base_url = base_url.rstrip("/")
        self.token_name = token_name
        self.token_value = token_value
        self.verify_ssl = verify_ssl
        self.timeout = timeout
        self.max_retries = max_retries
        self.backoff_factor = backoff_factor

        # Build auth header value
        self.auth_header = f"PVEAPIToken={token_name}={token_value}"

        # Create HTTP client with default headers
        self.client = httpx.Client(
            base_url=self.base_url,
            headers={"Authorization": self.auth_header},
            timeout=timeout,
            verify=verify_ssl,
        )

    @classmethod
    def from_env(
        cls,
        base_url: Optional[str] = None,
        token_name: Optional[str] = None,
        token_value: Optional[str] = None,
        **kwargs: Any,
    ) -> "ProxmoxAPI":
        """
        Create ProxmoxAPI instance from environment variables.

        Expected environment variables:
        - PROXMOX_URL: Proxmox API endpoint (required if not passed)
        - PROXMOX_TOKEN_NAME: API token name (required if not passed)
        - PROXMOX_TOKEN_VALUE: API token secret (required if not passed)
        - PROXMOX_VERIFY_SSL: "true" or "false" (optional, default: true)

        Args:
            base_url: Override environment variable
            token_name: Override environment variable
            token_value: Override environment variable
            **kwargs: Additional arguments passed to constructor

        Returns:
            ProxmoxAPI instance

        Raises:
            ValueError: If required credentials are missing
        """
        _base_url = base_url or os.getenv("PROXMOX_URL")
        _token_name = token_name or os.getenv("PROXMOX_TOKEN_NAME")
        _token_value = token_value or os.getenv("PROXMOX_TOKEN_VALUE")

        if not all([_base_url, _token_name, _token_value]):
            raise ValueError(
                "Missing Proxmox credentials. Provide via arguments "
                "or environment variables: PROXMOX_URL, PROXMOX_TOKEN_NAME, "
                "PROXMOX_TOKEN_VALUE"
            )

        verify_ssl = kwargs.get("verify_ssl", os.getenv("PROXMOX_VERIFY_SSL", "true").lower() == "true")

        return cls(
            base_url=_base_url,
            token_name=_token_name,
            token_value=_token_value,
            verify_ssl=verify_ssl,
            **{k: v for k, v in kwargs.items() if k != "verify_ssl"},
        )

    def _request(
        self,
        method: str,
        endpoint: str,
        *,
        params: Optional[Dict[str, Any]] = None,
        json_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """
        Make HTTP request to Proxmox API with retry logic.

        Args:
            method: HTTP method (GET, POST, PUT, DELETE)
            endpoint: API endpoint path (e.g., "/nodes/pve1/qemu")
            params: Query parameters
            json_data: JSON body for POST/PUT requests

        Returns:
            Parsed JSON response data

        Raises:
            AuthenticationError: If authentication fails (401)
            ResourceNotFoundError: If resource not found (404)
            ProxmoxAPIError: For other HTTP errors or after retries exhausted
        """
        url = endpoint if endpoint.startswith("/") else f"/{endpoint}"

        for attempt in range(self.max_retries + 1):
            try:
                response = self.client.request(
                    method=method,
                    url=url,
                    params=params,
                    json=json_data,
                )

                if response.status_code == 200:
                    return response.json()["data"]
                elif response.status_code == 401:
                    raise AuthenticationError(f"Authentication failed: {response.text}")
                elif response.status_code == 404:
                    raise ResourceNotFoundError(f"Resource not found: {endpoint}")
                else:
                    response.raise_for_status()

            except (TimeoutException, HTTPStatusError) as e:
                if attempt >= self.max_retries:
                    raise ProxmoxAPIError(f"Request failed after {self.max_retries} retries: {e}")

                # Exponential backoff
                sleep_time = self.backoff_factor * (2 ** attempt)
                time.sleep(sleep_time)

        raise ProxmoxAPIError("Max retries exceeded")

    def get(self, endpoint: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Perform GET request."""
        return self._request("GET", endpoint, params=params)

    def post(self, endpoint: str, json_data: Dict[str, Any]) -> Dict[str, Any]:
        """Perform POST request."""
        return self._request("POST", endpoint, json_data=json_data)

    def put(self, endpoint: str, json_data: Dict[str, Any]) -> Dict[str, Any]:
        """Perform PUT request."""
        return self._request("PUT", endpoint, json_data=json_data)

    def delete(self, endpoint: str, json_data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Perform DELETE request."""
        return self._request("DELETE", endpoint, json_data=json_data if json_data else None)

    def list_nodes(self) -> List[Dict[str, Any]]:
        """
        List all Proxmox nodes in the cluster.

        Returns:
            List of node dictionaries with keys:
            - id: Node name (e.g., "pve1")
            - status: "online" or "offline"
            - cpu: CPU usage info (cores, load)
            - memory: Memory usage info (total, used, free)
            - disk: Disk usage info (total, used, free)
            - network: Network interfaces
        """
        return self.get("/nodes")

    def get_node_resources(self, node: str) -> Dict[str, Any]:
        """
        Get detailed resource information for a specific node.

        Args:
            node: Node name (e.g., "pve1")

        Returns:
            Dictionary with resource metrics:
            - cpu: {"cores": int, "load": float, "usage": float}
            - memory: {"total": int (MB), "used": int (MB), "free": int (MB), "usage": float}
            - disk: {"total": int (KB), "used": int (KB), "free": int (KB), "usage": float}
            - network: {"interfaces": list, "rx": int, "tx": int}
        """
        status = self.get(f"/nodes/{node}/status")
        return status

    def list_networks(self, node: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        List network bridges on a node or all nodes.

        Args:
            node: Optional node name. If None, returns bridges from all nodes.

        Returns:
            List of bridge dictionaries with keys:
            - iface: Interface name (e.g., "vmbr0")
            - type: "bridge"
            - active: bool (whether bridge is active)
            - address: IP address if configured
            - netmask: Netmask if configured
            - node: Node name
        """
        bridges = []

        nodes = [node] if node else [n["id"] for n in self.list_nodes() if n["status"] == "online"]

        for node_id in nodes:
            try:
                # Get network interfaces
                net_data = self.get(f"/nodes/{node_id}/network")
                for iface in net_data:
                    if iface.get("type") == "bridge":
                        iface_copy = iface.copy()
                        iface_copy["node"] = node_id
                        bridges.append(iface_copy)
            except ProxmoxAPIError:
                # Skip nodes that fail
                continue

        return bridges

    def create_vm(
        self,
        *,
        node: str,
        name: str,
        cpu: int,
        ram_mb: int,
        disk_gb: int,
        bridge: str,
        iso: str,
        cloud_init: bool = True,
        **kwargs: Any,
    ) -> int:
        """
        Create a new QEMU virtual machine.

        Args:
            node: Target Proxmox node name
            name: VM name (will be used as guest name)
            cpu: Number of CPU cores
            ram_mb: RAM in megabytes
            disk_gb: Disk size in gigabytes
            bridge: Network bridge interface (e.g., "vmbr0")
            iso: ISO image name/path (e.g., "local:iso/talos-amd64.iso")
            cloud_init: Whether to enable cloud-init (default: True)
            **kwargs: Additional VM parameters:
                - bios: "seabios" or "ovmf" (default: "seabios")
                - machine: QEMU machine type (default: "pc")
                - cpu_type: CPU type (default: "host")
                - net_model: Network model (default: "virtio")
                - scsihw: SCSI controller (default: "virtio-scsi")
                - ovmf_secure_boot: bool for OVMF
                - qemu_agent: bool for QGA (default: True)
                - start_at_boot: bool (default: False)

        Returns:
            VM ID (vmid) of the created VM

        Raises:
            ProxmoxAPIError: If VM creation fails
        """
        # First, get next available VM ID
        next_vmid = self._get_next_vmid()

        # Build VM configuration
        vm_config = {
            "vmid": next_vmid,
            "name": name,
            "memory": ram_mb,
            "cores": cpu,
            "net0": f"virtio,bridge={bridge}",
            "scsihw": kwargs.get("scsihw", "virtio-scsi"),
            "bios": kwargs.get("bios", "seabios"),
            "machine": kwargs.get("machine", "pc"),
            "cpu": kwargs.get("cpu_type", "host"),
        }

        # Add cloud-init if requested
        if cloud_init:
            vm_config["net1"] = f"virtio,bridge={bridge}"
            vm_config["ipconfig1"] = "dhcp"

        # Add ISO as CD-ROM
        if iso:
            vm_config["ide2"] = f"{iso},media=cdrom"

        # Add QEMU agent if enabled (default: True)
        if kwargs.get("qemu_agent", True):
            vm_config["qga"] = "1"

        # SCSI disk
        vm_config["scsi0"] = f"local-lvm:{disk_gb}"

        # Start VM after creation?
        if kwargs.get("start_after_create", False):
            vm_config["onboot"] = 1

        # Additional options
        if "ostype" in kwargs:
            vm_config["ostype"] = kwargs["ostype"]
        if "description" in kwargs:
            vm_config["description"] = kwargs["description"]

        # Create the VM
        result = self.post(f"/nodes/{node}/qemu", vm_config)

        return next_vmid

    def _get_next_vmid(self) -> int:
        """
        Get the next available VM ID from the cluster.

        Returns:
            Next available VM ID (integer)
        """
        # Get current VMs to find the max ID
        next_id = 100  # Starting point
        for node in self.list_nodes():
            try:
                vms = self.get(f"/nodes/{node['id']}/qemu")
                for vm in vms:
                    if vm["vmid"] >= next_id:
                        next_id = vm["vmid"] + 1
            except ProxmoxAPIError:
                continue

        return next_id

    def get_vm_status(self, node: str, vmid: int) -> Dict[str, Any]:
        """
        Get current status and configuration of a VM.

        Args:
            node: Node name where VM resides
            vmid: VM ID

        Returns:
            VM status dictionary with keys:
            - vmid: int
            - name: str
            - status: "running", "stopped", "paused", etc.
            - maxmem: max memory in bytes
            - mem: current memory usage in bytes
            - maxcpu: max CPU cores
            - cpu: current CPU usage (normalized to cores)
            - cputime: CPU time in nanoseconds
            - uptime: uptime in seconds
            - disk: disk usage (read/write bytes)
            - net: network traffic (rx/tx bytes)
        """
        return self.get(f"/nodes/{node}/qemu/{vmid}/status/current")

    def get_vm_ip(self, node: str, vmid: int, interface: int = 0) -> Optional[str]:
        """
        Get the IP address of a VM using the QEMU Guest Agent.

        Args:
            node: Node name where VM resides
            vmid: VM ID
            interface: Network interface index (default: 0)

        Returns:
            IP address as string, or None if not available

        Note:
            Requires QEMU Guest Agent to be running inside the VM.
            For cloud-init VMs, this typically works after guest agent starts.
        """
        try:
            ifaces = self.get(f"/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces")
            if ifaces and isinstance(ifaces, list) and len(ifaces) > interface:
                iface = ifaces[interface]
                # Look for IPv4 address
                for addr in iface.get("ip-addresses", []):
                    if addr.get("ip-address-type") == "ipv4":
                        return addr.get("ip-address")
        except (ProxmoxAPIError, KeyError, IndexError):
            pass

        return None

    def delete_vm(self, node: str, vmid: int, *, purge: bool = True, destroy: bool = True) -> None:
        """
        Delete a VM from Proxmox.

        Args:
            node: Node name where VM resides
            vmid: VM ID to delete
            purge: Also delete volumes (default: True)
            destroy: Destroy immediately without destroy flag (default: True)
        """
        params = {}
        if purge:
            params["purge"] = 1
        if destroy:
            params["destroy"] = 1

        self.delete(f"/nodes/{node}/qemu/{vmid}", json_data=params if params else None)

    def start_vm(self, node: str, vmid: int) -> None:
        """
        Start a VM.

        Args:
            node: Node name
            vmid: VM ID
        """
        self.post(f"/nodes/{node}/qemu/{vmid}/status/start", {})

    def stop_vm(self, node: str, vmid: int, *, force: bool = False) -> None:
        """
        Stop a VM (gracefully or forced).

        Args:
            node: Node name
            vmid: VM ID
            force: Force stop (like pulling power plug)
        """
        params = {"force": 1} if force else {}
        self.post(f"/nodes/{node}/qemu/{vmid}/status/stop", params)

    def get_vm_config(self, node: str, vmid: int) -> Dict[str, Any]:
        """
        Get VM configuration.

        Args:
            node: Node name
            vmid: VM ID

        Returns:
            VM configuration dictionary
        """
        return self.get(f"/nodes/{node}/qemu/{vmid}/config")

    def update_vm_config(self, node: str, vmid: int, **config_updates: Any) -> None:
        """
        Update VM configuration parameters.

        Args:
            node: Node name
            vmid: VM ID
            **config_updates: Configuration key-value pairs to update
        """
        self.put(f"/nodes/{node}/qemu/{vmid}/config", config_updates)

    def get_storage_list(self, node: str, storage_type: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        List storage available on a node.

        Args:
            node: Node name
            storage_type: Filter by storage type (e.g., "lvm", "nfs", "dir")

        Returns:
            List of storage configurations
        """
        storage = self.get(f"/nodes/{node}/storage")
        if storage_type:
            return [s for s in storage if s.get("type") == storage_type]
        return storage

    def get_cluster_status(self) -> Dict[str, Any]:
        """
        Get overall cluster status.

        Returns:
            Cluster status dictionary with information about:
            - cluster name
            - node count
            - quorate status
            - HA status
        """
        return self.get("/cluster/status")

    def wait_for_vm_agent(
        self,
        node: str,
        vmid: int,
        timeout: float = 60.0,
        poll_interval: float = 2.0
    ) -> bool:
        """
        Wait for VM's QEMU Guest Agent to become ready.

        Args:
            node: Node name
            vmid: VM ID
            timeout: Maximum wait time in seconds
            poll_interval: Polling interval in seconds

        Returns:
            True if agent is ready within timeout

        Raises:
            TimeoutError: If agent doesn't become ready in time
        """
        start_time = time.time()

        while time.time() - start_time < timeout:
            try:
                # Try to ping the agent
                result = self.get(f"/nodes/{node}/qemu/{vmid}/agent/ping")
                if result.get("connected") is True:
                    return True
            except ProxmoxAPIError:
                pass

            time.sleep(poll_interval)

        raise TimeoutError(f"VM {vmid} agent did not become ready within {timeout}s")

    def __enter__(self) -> "ProxmoxAPI":
        """Context manager entry."""
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        """Context manager exit - close HTTP client."""
        self.client.close()


# Helper function to create managed VM (specific to Twinbox Phase 1)
def create_twinbox_user(api: ProxmoxAPI, cluster_name: str) -> tuple[str, str]:
    """
    Create the twinbox@pve user and generate an API token.

    Args:
        api: Authenticated ProxmoxAPI instance
        cluster_name: Cluster name (used for resource pool)

    Returns:
        tuple: (token_name, token_secret)

    Raises:
        ProxmoxAPIError: If user/token creation fails
    """
    import subprocess

    # Create user if not exists using pvesh (simpler than API for user creation)
    try:
        subprocess.run(
            ["pvesh", "get", "/access/users/twinbox@pve"],
            capture_output=True,
            check=False
        )
    except Exception:
        # User doesn't exist, create it
        password = subprocess.check_output(
            ["openssl", "rand", "-base64", "24"]
        ).decode().strip()[:16]

        subprocess.run(
            ["pvesh", "create", "/access/users", "-userid", "twinbox@pve", "-password", password],
            capture_output=True,
            check=True
        )

    # Create resource pool
    pool_id = f"twinbox-{cluster_name}"
    try:
        subprocess.run(
            ["pvesh", "get", f"/pools/{pool_id}"],
            capture_output=True,
            check=False
        )
    except Exception:
        subprocess.run(
            ["pvesh", "create", "/pools", "-poolid", pool_id],
            capture_output=True,
            check=True
        )

    # Set ACLs
    subprocess.run(
        ["pvesh", "set", f"/pools/{pool_id}/acl", "-path", "/", "-group", "user:twinbox@pve",
         "-roles", "VM.Create,VM.Modify,VM.PowerMgmt,Pool.List"],
        capture_output=True,
        check=False
    )

    # Generate token using pveum
    token_id = f"twinbox-token-{int(time.time())}"
    result = subprocess.run(
        ["pveum", "user", "token", "add", "twinbox@pve", token_id, "--privsep", "0"],
        capture_output=True,
        text=True,
        check=True
    )

    # Parse output: first line is token name, second is token value
    lines = result.stdout.strip().split('\n')
    if len(lines) >= 2:
        token_name = lines[0].strip()
        token_secret = lines[1].strip()
        return token_name, token_secret
    else:
        raise ProxmoxAPIError("Failed to parse token output from pveum")
