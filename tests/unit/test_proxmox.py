"""
Unit tests for the Proxmox API client.

Tests cover:
- Authentication (token and password)
- list_nodes
- get_node_resources
- create_vm
- Error handling (400/500)
- get_vm_ip
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
from manager.shared.proxmox import ProxmoxAPI, ProxmoxAPIError


class TestProxmoxAuthentication:
    """Tests for Proxmox API authentication."""

    def test_authenticate_with_token(self):
        """Test authentication using API token."""
        # Create client with token credentials
        client = ProxmoxAPI(
            host="proxmox.example.com",
            user="root@pam",
            token_id="root@pam!twinbox",
            secret="secret-token-value"
        )

        # Token auth doesn't fetch a ticket - just sets state
        client.authenticate(use_token=True)

        assert client._ticket is None
        assert client._csrf_token is None
        # Token should be used directly in headers via token_id/secret

    def test_authenticate_with_password_success(self):
        """Test successful password-based authentication."""
        client = ProxmoxAPI(
            host="proxmox.example.com",
            user="root@pam",
            password="test-password"
        )

        # Mock the HTTP response
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': {
                'ticket': 'PVEAuthCookie=abc123',
                'CSRFPreventionToken': 'CSRF=def456'
            }
        }

        with patch.object(client._client, 'post', return_value=mock_response):
            client.authenticate(use_token=False)

        assert client._ticket == 'PVEAuthCookie=abc123'
        assert client._csrf_token == 'CSRF=def456'

    def test_authenticate_with_password_failure(self):
        """Test failed password-based authentication."""
        client = ProxmoxAPI(
            host="proxmox.example.com",
            user="root@pam",
            password="wrong-password"
        )

        mock_response = Mock()
        mock_response.status_code = 401
        mock_response.text = "Authentication failed"

        with patch.object(client._client, 'post', return_value=mock_response):
            with pytest.raises(ProxmoxAPIError, match="Authentication failed"):
                client.authenticate(use_token=False)

        assert client._ticket is None
        assert client._csrf_token is None

    def test_authenticate_no_credentials(self):
        """Test authentication with no credentials raises error."""
        client = ProxmoxAPI(
            host="proxmox.example.com",
            user="root@pam"
        )

        with pytest.raises(ProxmoxAPIError, match="No authentication credentials"):
            client.authenticate(use_token=False)

    def test_get_headers_with_auth(self):
        """Test that headers include auth tokens."""
        client = ProxmoxAPI(
            host="proxmox.example.com",
            user="root@pam",
            password="password"
        )
        client._ticket = "PVEAuthCookie=test123"
        client._csrf_token = "CSRF=test456"

        headers = client._get_headers()

        assert 'Cookie' in headers
        assert headers['Cookie'] == "PVEAuthCookie=test123"
        assert 'CSRFPreventionToken' in headers
        assert headers['CSRFPreventionToken'] == "CSRF=test456"

    def test_get_headers_without_csrf(self):
        """Test headers work with cookie but no CSRF."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "PVEAuthCookie=test"
        client._csrf_token = None

        headers = client._get_headers()
        assert 'Cookie' in headers
        assert 'CSRFPreventionToken' not in headers


class TestListNodes:
    """Tests for list_nodes method."""

    def test_list_nodes_success(self):
        """Test successful node listing."""
        client = ProxmoxAPI(host="proxmox.example.com", user="root@pam", password="pass")

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': [
                {'node': 'pve1', 'status': 'online'},
                {'node': 'pve2', 'status': 'online'},
                {'node': 'pve3', 'status': 'offline'}
            ]
        }

        with patch.object(client._client, 'get', return_value=mock_response):
            nodes = client.list_nodes()

        assert len(nodes) == 3
        assert nodes[0]['node'] == 'pve1'
        assert nodes[1]['node'] == 'pve2'
        assert nodes[2]['node'] == 'pve3'

    def test_list_nodes_error(self):
        """Test node listing with API error."""
        client = ProxmoxAPI(host="proxmox.example.com", user="root@pam", password="pass")

        mock_response = Mock()
        mock_response.status_code = 500
        mock_response.text = "Internal server error"

        with patch.object(client._client, 'get', return_value=mock_response):
            with pytest.raises(ProxmoxAPIError, match="Failed to list nodes"):
                client.list_nodes()


class TestGetNodeResources:
    """Tests for get_node_resources method."""

    def test_get_node_resources_success(self):
        """Test successful resource retrieval."""
        client = ProxmoxAPI(host="proxmox.example.com", user="root@pam", password="pass")

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': {
                'cpu': 0.12,
                'memory': {
                    'used': 40960,
                    'total': 131072
                },
                'rootfs': {
                    'used': 53687091200,
                    'total': 1000000000000
                }
            }
        }

        with patch.object(client._client, 'get', return_value=mock_response):
            resources = client.get_node_resources('pve1')

        assert resources['cpu'] == 0.12
        assert resources['memory']['used'] == 40960
        assert resources['memory']['total'] == 131072

    def test_get_node_resources_not_found(self):
        """Test resource retrieval for non-existent node."""
        client = ProxmoxAPI(host="proxmox.example.com", user="root@pam", password="pass")

        mock_response = Mock()
        mock_response.status_code = 500
        mock_response.text = "Node not found"

        with patch.object(client._client, 'get', return_value=mock_response):
            with pytest.raises(ProxmoxAPIError, match="Failed to get node resources"):
                client.get_node_resources('nonexistent')


class TestCreateVM:
    """Tests for create_vm method."""

    def test_create_vm_basic(self):
        """Test basic VM creation."""
        client = ProxmoxAPI(host="proxmox.example.com", user="root@pam", password="pass")
        client._ticket = "PVEAuthCookie=test"
        client._csrf_token = "CSRF=test"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {'vmid': 100}}

        with patch.object(client._client, 'post', return_value=mock_response) as mock_post:
            result = client.create_vm(
                node_name='pve1',
                vmid=100,
                name='test-vm',
                cores=4,
                memory=8192,
                disk='40G'
            )

        assert result == {'vmid': 100}

        # Check the request was made correctly
        mock_post.assert_called_once()
        args, kwargs = mock_post.call_args

        # Check URL
        assert 'nodes/pve1/qemu' in args[0]

        # Check headers include auth
        assert 'Cookie' in kwargs['headers']
        assert 'CSRFPreventionToken' in kwargs['headers']

        # Check form data
        data = kwargs['data']
        assert data['vmid'] == 100
        assert data['name'] == 'test-vm'
        assert data['cores'] == 4
        assert data['memory'] == 8192
        assert data['disk'] == '40G'

    def test_create_vm_with_iso(self):
        """Test VM creation with ISO boot."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {}}

        with patch.object(client._client, 'post', return_value=mock_response):
            result = client.create_vm(
                node_name='pve1',
                vmid=101,
                name='iso-vm',
                cores=2,
                memory=4096,
                disk='20G',
                iso_path='local:iso/ubuntu-22.04.iso'
            )

        # Verify iso_path was set
        # The post would have been called with ide2 parameter
        assert result == {}

    def test_create_vm_with_network(self):
        """Test VM creation with network configuration."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {}}

        with patch.object(client._client, 'post', return_value=mock_response):
            result = client.create_vm(
                node_name='pve1',
                vmid=102,
                name='net-vm',
                cores=2,
                memory=4096,
                disk='20G',
                net0='virtio,bridge=vmbr0'
            )

        assert result == {}

    def test_create_vm_additional_kwargs(self):
        """Test that additional kwargs are passed through."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {}}

        with patch.object(client._client, 'post', return_value=mock_response) as mock_post:
            result = client.create_vm(
                node_name='pve1',
                vmid=103,
                name='custom-vm',
                cores=2,
                memory=4096,
                disk='20G',
                scsihw='virtio-scsi',
                qs='1'  # Enable hugepages
            )

        # Check that extra params made it through
        args, kwargs = mock_post.call_args
        data = kwargs['data']
        assert data['scsihw'] == 'virtio-scsi'
        assert data['qs'] == '1'

    def test_create_vm_error_400(self):
        """Test VM creation with 400 Bad Request."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 400
        mock_response.text = "Invalid parameters"

        with patch.object(client._client, 'post', return_value=mock_response):
            with pytest.raises(ProxmoxAPIError, match="Failed to create VM"):
                client.create_vm(
                    node_name='pve1',
                    vmid=100,
                    name='bad-vm',
                    cores=4,
                    memory=8192,
                    disk='40G'
                )

    def test_create_vm_error_500(self):
        """Test VM creation with 500 Internal Server Error."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 500
        mock_response.text = "Internal server error"

        with patch.object(client._client, 'post', return_value=mock_response):
            with pytest.raises(ProxmoxAPIError, match="Failed to create VM"):
                client.create_vm(
                    node_name='pve1',
                    vmid=100,
                    name='error-vm',
                    cores=2,
                    memory=4096,
                    disk='20G'
                )

    def test_create_vm_no_auth(self):
        """Test VM creation without authentication."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        # Not authenticated

        with pytest.raises(ProxmoxAPIError):
            client.create_vm(
                node_name='pve1',
                vmid=100,
                name='no-auth-vm',
                cores=2,
                memory=4096,
                disk='20G'
            )


class TestVMOperations:
    """Tests for VM operation methods (start, stop, delete)."""

    def test_start_vm(self):
        """Test starting a VM."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {}}

        with patch.object(client._client, 'post', return_value=mock_response) as mock_post:
            result = client.start_vm('pve1', 100)

        assert result == {}
        # Check correct endpoint
        args, _ = mock_post.call_args
        assert 'nodes/pve1/qemu/100/status/start' in args[0]

    def test_stop_vm(self):
        """Test stopping a VM."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {}}

        with patch.object(client._client, 'post', return_value=mock_response):
            result = client.stop_vm('pve1', 100)

        assert result == {}

    def test_delete_vm_with_purge(self):
        """Test deleting a VM with purge."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"
        client._csrf_token = "csrf"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {}}

        with patch.object(client._client, 'delete', return_value=mock_response) as mock_delete:
            result = client.delete_vm('pve1', 100, purge=True)

        assert result == {}
        args, kwargs = mock_delete.call_args
        assert kwargs['params']['purge'] == 1

    def test_get_vm_status(self):
        """Test getting VM status."""
        client = ProxmoxAPI(host="test", user="user", password="pass")
        client._ticket = "cookie"

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': {
                'status': 'running',
                'cpu': 0.5,
                'mem': 2048
            }
        }

        with patch.object(client._client, 'get', return_value=mock_response):
            status = client.get_vm_status('pve1', 100)

        assert status['status'] == 'running'
        assert status['cpu'] == 0.5


class TestGetVMIP:
    """Tests for get_vm_ip method."""

    def test_get_vm_ip_success(self):
        """Test successful IP retrieval."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': {
                'status': 'running',
                'net': {
                    'net0': {
                        'ip-addresses': [
                            {
                                'ip-address': '192.168.1.100',
                                'netmask': '255.255.255.0'
                            }
                        ]
                    }
                }
            }
        }

        with patch.object(client._client, 'get', return_value=mock_response):
            ip = client.get_vm_ip('pve1', 100)

        assert ip == '192.168.1.100'

    def test_get_vm_ip_not_available(self):
        """Test when VM has no IP yet."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': {
                'status': 'stopped',
                'net': {}
            }
        }

        with patch.object(client._client, 'get', return_value=mock_response):
            ip = client.get_vm_ip('pve1', 100)

        assert ip is None

    def test_get_vm_ip_custom_iface(self):
        """Test IP retrieval with custom interface."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': {
                'net': {
                    'net1': {
                        'ip-addresses': [
                            {'ip-address': '10.0.0.50'}
                        ]
                    }
                }
            }
        }

        with patch.object(client._client, 'get', return_value=mock_response):
            ip = client.get_vm_ip('pve1', 100, iface='net1')

        assert ip == '10.0.0.50'

    def test_get_vm_ip_error_handling(self):
        """Test IP retrieval handles errors gracefully."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        # Simulate exception
        with patch.object(client._client, 'get', side_effect=Exception("Connection error")):
            ip = client.get_vm_ip('pve1', 100)

        assert ip is None


class TestWaitForVMIP:
    """Tests for wait_for_vm_ip method."""

    def test_wait_for_vm_ip_immediate(self):
        """Test when IP is available immediately."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'data': {
                'status': 'running',
                'net': {
                    'net0': {
                        'ip-addresses': [
                            {'ip-address': '192.168.1.100'}
                        ]
                    }
                }
            }
        }

        with patch.object(client._client, 'get', return_value=mock_response):
            ip = client.wait_for_vm_ip('pve1', 100, timeout=30)

        assert ip == '192.168.1.100'

    def test_wait_for_vm_ip_timeout(self):
        """Test timeout when IP never becomes available."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        # Always return no IP
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {'data': {'status': 'running', 'net': {}}}

        with patch.object(client._client, 'get', return_value=mock_response):
            with patch('time.time', side_effect=[0, 100, 200, 300, 400]):  # Mock time to trigger timeout
                ip = client.wait_for_vm_ip('pve1', 100, timeout=5)  # Short timeout for test

        assert ip is None


class TestProxmoxAPIContextManager:
    """Tests for context manager functionality."""

    def test_context_manager(self):
        """Test that client can be used as context manager."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        with patch.object(client, 'close') as mock_close:
            with client:
                pass

        mock_close.assert_called_once()

    def test_context_manager_with_exception(self):
        """Test that close is called even on exception."""
        client = ProxmoxAPI(host="test", user="user", password="pass")

        with patch.object(client, 'close') as mock_close:
            with pytest.raises(ValueError):
                with client:
                    raise ValueError("test error")

        mock_close.assert_called_once()
