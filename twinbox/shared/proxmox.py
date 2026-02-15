"""
Proxmox API client for managing VMs and nodes.
"""

import httpx
from typing import Dict, List, Optional, Any
import json


class ProxmoxAPIError(Exception):
    """Custom exception for Proxmox API errors."""
    pass


class ProxmoxAPI:
    """
    Client for interacting with Proxmox VE API.
    """

    def __init__(
        self,
        host: str,
        user: str,
        password: Optional[str] = None,
        token_id: Optional[str] = None,
        secret: Optional[str] = None,
        port: int = 8006,
        verify_ssl: bool = False
    ):
        """
        Initialize Proxmox API client.

        Can authenticate with either password/token or pre-existing ticket/CSRF token.

        Args:
            host: Proxmox host
            user: Username (e.g., root@pam)
            password: Password (for password-based auth)
            token_id: API token ID (e.g., root@pam!tokenname)
            secret: API token secret
            port: API port (default 8006)
            verify_ssl: Verify SSL certificates
        """
        self.host = host
        self.user = user
        self.password = password
        self.token_id = token_id
        self.secret = secret
        self.port = port
        self.verify_ssl = verify_ssl

        self.base_url = f"https://{host}:{port}/api2/json"
        self._ticket = None
        self._csrf_token = None
        self._client = httpx.Client(verify=verify_ssl)

    def authenticate(self, use_token: bool = False) -> None:
        """
        Authenticate with Proxmox API.

        Args:
            use_token: If True, use API token authentication; otherwise use password

        Raises:
            ProxmoxAPIError: If authentication fails
        """
        if use_token and self.token_id and self.secret:
            # API token authentication - token is included in requests
            self._ticket = None
            self._csrf_token = None
            return

        if self.password:
            # Password-based authentication - get ticket
            auth_data = {
                "username": self.user,
                "password": self.password,
                "realm": self.user.split('@')[1] if '@' in self.user else 'pam'
            }
            response = self._client.post(f"{self.base_url}/access/ticket", json=auth_data)
            if response.status_code != 200:
                raise ProxmoxAPIError(f"Authentication failed: {response.text}")

            data = response.json()['data']
            self._ticket = data['ticket']
            self._csrf_token = data['CSRFPreventionToken']
        else:
            raise ProxmoxAPIError("No authentication credentials provided")

    def _get_headers(self) -> Dict[str, str]:
        """Build request headers with auth tokens."""
        headers = {}
        if self._ticket:
            headers['Cookie'] = f"PVEAuthCookie={self._ticket}"
        if self._csrf_token and self._csrf_token != "None":
            headers['CSRFPreventionToken'] = self._csrf_token
        return headers

    def list_nodes(self) -> List[Dict]:
        """
        List all nodes in the cluster.

        Returns:
            List of node information dictionaries
        """
        response = self._client.get(f"{self.base_url}/nodes", headers=self._get_headers())
        if response.status_code != 200:
            raise ProxmoxAPIError(f"Failed to list nodes: {response.text}")
        return response.json()['data']

    def get_node_resources(self, node_name: str) -> Dict:
        """
        Get resource information for a specific node.

        Args:
            node_name: Name of the node

        Returns:
            Dictionary with node resource information
        """
        response = self._client.get(
            f"{self.base_url}/nodes/{node_name}/status",
            headers=self._get_headers()
        )
        if response.status_code != 200:
            raise ProxmoxAPIError(f"Failed to get node resources: {response.text}")
        return response.json()['data']

    def create_vm(
        self,
        node_name: str,
        vmid: int,
        name: str,
        cores: int,
        memory: int,  # in MB
        disk: str,  # e.g., "20G"
        iso_path: Optional[str] = None,
        net0: Optional[str] = None,
        agent: int = 1,
        **kwargs
    ) -> Dict:
        """
        Create a new VM on a node.

        Args:
            node_name: Target node
            vmid: VM ID
            name: VM name
            cores: Number of CPU cores
            memory: Memory in MB
            disk: Disk size (e.g., "20G")
            iso_path: ISO image path (e.g., "local:iso/ubuntu-22.04.iso")
            net0: Network device config (e.g., "virtio,bridge=vmbr0")
            agent: Enable QEMU agent (0=disable, 1=enable)
            **kwargs: Additional VM configuration

        Returns:
            Dictionary with creation result
        """
        params = {
            "vmid": vmid,
            "name": name,
            "cores": cores,
            "memory": memory,
            "disk": disk,
            "agent": agent,
        }

        if iso_path:
            params['ide2'] = iso_path

        if net0:
            params['net0'] = net0

        # Add any additional parameters
        params.update(kwargs)

        response = self._client.post(
            f"{self.base_url}/nodes/{node_name}/qemu",
            headers=self._get_headers(),
            data=params
        )

        if response.status_code not in (200, 201):
            raise ProxmoxAPIError(f"Failed to create VM: {response.text}")

        return response.json()['data']

    def start_vm(self, node_name: str, vmid: int) -> Dict:
        """Start a VM."""
        response = self._client.post(
            f"{self.base_url}/nodes/{node_name}/qemu/{vmid}/status/start",
            headers=self._get_headers()
        )
        if response.status_code != 200:
            raise ProxmoxAPIError(f"Failed to start VM: {response.text}")
        return response.json()['data']

    def stop_vm(self, node_name: str, vmid: int) -> Dict:
        """Stop a VM."""
        response = self._client.post(
            f"{self.base_url}/nodes/{node_name}/qemu/{vmid}/status/stop",
            headers=self._get_headers()
        )
        if response.status_code != 200:
            raise ProxmoxAPIError(f"Failed to stop VM: {response.text}")
        return response.json()['data']

    def delete_vm(self, node_name: str, vmid: int, purge: bool = True) -> Dict:
        """Delete a VM."""
        params = {}
        if purge:
            params['purge'] = 1
        response = self._client.delete(
            f"{self.base_url}/nodes/{node_name}/qemu/{vmid}",
            headers=self._get_headers(),
            params=params
        )
        if response.status_code != 200:
            raise ProxmoxAPIError(f"Failed to delete VM: {response.text}")
        return response.json()['data']

    def get_vm_status(self, node_name: str, vmid: int) -> Dict:
        """Get VM status."""
        response = self._client.get(
            f"{self.base_url}/nodes/{node_name}/qemu/{vmid}/status/current",
            headers=self._get_headers()
        )
        if response.status_code != 200:
            raise ProxmoxAPIError(f"Failed to get VM status: {response.text}")
        return response.json()['data']

    def get_vm_ip(self, node_name: str, vmid: int, iface: str = "net0") -> Optional[str]:
        """
        Get the IP address of a VM.

        Args:
            node_name: Node where VM resides
            vmid: VM ID
            iface: Network interface to query

        Returns:
            IP address string or None if not available
        """
        try:
            status = self.get_vm_status(node_name, vmid)
            if 'net' in status and iface in status['net']:
                return status['net'][iface].get('ip-addresses', [{}])[0].get('ip-address')
        except Exception:
            pass
        return None

    def wait_for_vm_ip(self, node_name: str, vmid: int, timeout: int = 300, iface: str = "net0") -> Optional[str]:
        """
        Wait for VM to obtain an IP address.

        Args:
            node_name: Node where VM resides
            vmid: VM ID
            timeout: Maximum wait time in seconds
            iface: Network interface to wait for

        Returns:
            IP address or None if timeout
        """
        import time
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                status = self.get_vm_status(node_name, vmid)
                if status.get('status') == 'running':
                    if 'net' in status and iface in status['net']:
                        ip = status['net'][iface].get('ip-addresses', [{}])[0].get('ip-address')
                        if ip:
                            return ip
            except Exception:
                pass
            time.sleep(5)
        return None

    def list_storage(self, storage_id: str = "local") -> List[Dict]:
        """List storage contents."""
        response = self._client.get(
            f"{self.base_url}/nodes/{self.host}/storage/{storage_id}/content",
            headers=self._get_headers()
        )
        if response.status_code != 200:
            raise ProxmoxAPIError(f"Failed to list storage: {response.text}")
        return response.json()['data']

    def upload_iso(self, storage_id: str, file_path: str, content: bytes) -> Dict:
        """Upload an ISO file to storage."""
        files = {'filename': (file_path.split('/')[-1], content)}
        # Note: This would need multipart form data handling
        # Implementation depends on Proxmox API specifics
        raise NotImplementedError("ISO upload not implemented in mock")

    def close(self) -> None:
        """Close the HTTP client."""
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
