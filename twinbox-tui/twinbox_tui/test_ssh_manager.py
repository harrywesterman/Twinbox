"""
Tests for twinbox_tui.ssh_manager module.

Uses mock asyncssh to test connection handling and command execution.
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch

import asyncssh

from twinbox_tui.ssh_manager import SSHCommandError, SSHConnectionError, SSHManager, SSHConnectionPool


@pytest.fixture
def ssh_manager():
    """Create a basic SSHManager instance."""
    return SSHManager(
        host="test.example.com",
        port=2222,
        username="testuser",
        password="testpass",
    )


@pytest.mark.asyncio
async def test_connect_success(ssh_manager):
    """Test successful connection."""
    with patch.object(asyncssh, 'connect', new_callable=AsyncMock) as mock_connect:
        mock_connection = AsyncMock()
        mock_connect.return_value = mock_connection

        await ssh_manager.connect()

        assert ssh_manager._connection == mock_connection
        mock_connect.assert_called_once()
        call_kwargs = mock_connect.call_args.kwargs
        assert call_kwargs['host'] == 'test.example.com'
        assert call_kwargs['port'] == 2222
        assert call_kwargs['username'] == 'testuser'
        assert call_kwargs['password'] == 'testpass'


@pytest.mark.asyncio
async def test_connect_with_key(ssh_manager):
    """Test connection using client key."""
    ssh_manager.client_key = "/path/to/key"
    ssh_manager.password = None

    with patch.object(asyncssh, 'connect', new_callable=AsyncMock) as mock_connect:
        mock_connection = AsyncMock()
        mock_connect.return_value = mock_connection

        await ssh_manager.connect()

        mock_connect.assert_called_once()
        call_kwargs = mock_connect.call_args.kwargs
        assert call_kwargs['client_keys'] == ['/path/to/key']
        assert 'password' not in call_kwargs


@pytest.mark.asyncio
async def test_connect_retry_logic(ssh_manager):
    """Test that connection retries on failure."""
    with patch.object(asyncssh, 'connect', new_callable=AsyncMock) as mock_connect:
        # Fail twice, then succeed
        mock_connection = AsyncMock()
        mock_connect.side_effect = [
            ConnectionError("Failed"),
            ConnectionError("Failed again"),
            mock_connection,
        ]

        await ssh_manager.connect()

        assert mock_connect.call_count == 3
        assert ssh_manager._connection == mock_connection


@pytest.mark.asyncio
async def test_connect_fails_after_retries(ssh_manager):
    """Test that connection raises after max retries."""
    with patch.object(asyncssh, 'connect', new_callable=AsyncMock) as mock_connect:
        mock_connect.side_effect = ConnectionError("Connection error")

        with pytest.raises(SSHConnectionError) as exc_info:
            await ssh_manager.connect()

        assert "after 3 attempts" in str(exc_info.value)
        assert mock_connect.call_count == 3


@pytest.mark.asyncio
async def test_disconnect(ssh_manager):
    """Test disconnect closes connection."""
    mock_connection = AsyncMock()
    ssh_manager._connection = mock_connection

    await ssh_manager.disconnect()

    mock_connection.close.assert_called_once()
    mock_connection.wait_closed.assert_called_once()
    assert ssh_manager._connection is None


@pytest.mark.asyncio
async def test_disconnect_when_not_connected(ssh_manager):
    """Test disconnect is safe when not connected."""
    # No connection set
    await ssh_manager.disconnect()  # Should not raise


@pytest.mark.asyncio
async def test_is_connected(ssh_manager):
    """Test connection status check."""
    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    ssh_manager._connection = mock_connection

    assert await ssh_manager.is_connected() is True
    assert ssh_manager._connection is mock_connection  # Still connected

    mock_connection.is_closed = True
    assert await ssh_manager.is_connected() is False
    # Should clear connection reference when closed
    assert ssh_manager._connection is None


@pytest.mark.asyncio
async def test_execute_success(ssh_manager):
    """Test successful command execution."""
    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    mock_connection.run.return_value = MagicMock(
        exit_status=0,
        stdout="Command output",
        stderr="",
    )
    ssh_manager._connection = mock_connection

    exit_code, stdout, stderr = await ssh_manager.execute("ls -la")

    assert exit_code == 0
    assert stdout == "Command output"
    assert stderr == ""


@pytest.mark.asyncio
async def test_execute_with_error(ssh_manager):
    """Test command execution with non-zero exit."""
    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    mock_connection.run.return_value = MagicMock(
        exit_status=1,
        stdout="",
        stderr="Error message",
    )
    ssh_manager._connection = mock_connection

    exit_code, stdout, stderr = await ssh_manager.execute("false")

    assert exit_code == 1
    assert stderr == "Error message"


@pytest.mark.asyncio
async def test_execute_not_connected(ssh_manager):
    """Test execute raises when not connected."""
    with pytest.raises(SSHConnectionError) as exc_info:
        await ssh_manager.execute("ls")

    assert "Not connected" in str(exc_info.value)


@pytest.mark.asyncio
async def test_execute_streaming(ssh_manager):
    """Test streaming command execution."""
    mock_process = AsyncMock()
    # Simulate streaming output
    async def mock_stdout():
        for line in ["Line 1", "Line 2", "Line 3"]:
            yield line + "\n"
    mock_process.stdout = mock_stdout()
    async def mock_stderr():
        yield "Error line\n"
    mock_process.stderr = mock_stderr()
    mock_process.wait.return_value = None
    mock_process.exit_status = 0

    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    mock_connection.create_process.return_value = mock_process
    ssh_manager._connection = mock_connection

    lines = []
    async for stream_type, line in ssh_manager.execute_streaming("echo test"):
        lines.append((stream_type, line))

    assert len(lines) == 4
    assert ("stdout", "Line 1") in lines
    assert ("stdout", "Line 2") in lines
    assert ("stdout", "Line 3") in lines
    assert ("stderr", "Error line") in lines


@pytest.mark.asyncio
async def test_execute_streaming_nonzero_exit(ssh_manager):
    """Test streaming raises on non-zero exit."""
    mock_process = AsyncMock()
    async def mock_stdout():
        yield "output\n"
    mock_process.stdout = mock_stdout()
    async def mock_stderr():
        yield "error\n"
    mock_process.stderr = mock_stderr()
    mock_process.wait.return_value = None
    mock_process.exit_status = 1

    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    mock_connection.create_process.return_value = mock_process
    ssh_manager._connection = mock_connection

    with pytest.raises(SSHCommandError) as exc_info:
        async for _ in ssh_manager.execute_streaming("false"):
            pass

    assert "exited with code 1" in str(exc_info.value)


@pytest.mark.asyncio
async def test_upload_file(ssh_manager):
    """Test file upload."""
    mock_sftp_client = AsyncMock()
    mock_sftp_client.put = AsyncMock()

    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    # Mock start_sftp_client to return an async context manager
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def mock_start_sftp():
        yield mock_sftp_client

    mock_connection.start_sftp_client = mock_start_sftp
    ssh_manager._connection = mock_connection

    await ssh_manager.upload_file("/local/path", "/remote/path")

    mock_sftp_client.put.assert_called_once_with("/local/path", "/remote/path")


@pytest.mark.asyncio
async def test_download_file(ssh_manager):
    """Test file download."""
    mock_sftp_client = AsyncMock()
    mock_sftp_client.get = AsyncMock()

    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    # Mock start_sftp_client to return an async context manager
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def mock_start_sftp():
        yield mock_sftp_client

    mock_connection.start_sftp_client = mock_start_sftp
    ssh_manager._connection = mock_connection

    await ssh_manager.download_file("/remote/path", "/local/path")

    mock_sftp_client.get.assert_called_once_with("/remote/path", "/local/path")


@pytest.mark.asyncio
async def test_check_command(ssh_manager):
    """Test command check helper."""
    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    mock_connection.run.return_value = MagicMock(exit_status=0, stdout="", stderr="")
    ssh_manager._connection = mock_connection

    assert await ssh_manager.check_command("true") is True

    mock_connection.run.return_value = MagicMock(exit_status=1, stdout="", stderr="")
    assert await ssh_manager.check_command("false") is False


@pytest.mark.asyncio
async def test_wait_for_ssh(ssh_manager):
    """Test waiting for SSH to become ready."""
    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    mock_connection.run.return_value = MagicMock(exit_status=0, stdout="test", stderr="")

    with patch.object(asyncssh, 'connect', return_value=mock_connection):
        # First call to is_connected returns False (not yet connected)
        # After connect, it returns True
        call_count = 0
        original_is_connected = ssh_manager.is_connected
        async def fake_is_connected():
            nonlocal call_count
            call_count += 1
            return call_count > 1 and not mock_connection.is_closed
        ssh_manager.is_connected = fake_is_connected

        result = await ssh_manager.wait_for_ssh(timeout=5, poll_interval=0.1)
        assert result is True

        # Restore for cleanup
        ssh_manager.is_connected = original_is_connected


@pytest.mark.asyncio
async def test_wait_for_ssh_timeout(ssh_manager):
    """Test timeout waiting for SSH."""
    with patch.object(asyncssh, 'connect', side_effect=Exception("Not ready")):
        with pytest.raises(TimeoutError) as exc_info:
            await ssh_manager.wait_for_ssh(timeout=0.3, poll_interval=0.1)

        assert "did not become available" in str(exc_info.value)


@pytest.mark.asyncio
async def test_session_context_manager(ssh_manager):
    """Test session context manager."""
    mock_connection = AsyncMock()
    mock_connection.is_closed = False
    mock_connection.close = AsyncMock()
    mock_connection.wait_closed = AsyncMock()
    # Use AsyncMock for connect so it can be awaited
    with patch.object(asyncssh, 'connect', new_callable=AsyncMock, return_value=mock_connection):
        async with ssh_manager.session() as session:
            assert session is ssh_manager
            assert ssh_manager._connection == mock_connection

        mock_connection.close.assert_called_once()
        mock_connection.wait_closed.assert_called_once()


def test_ssh_connection_pool():
    """Test connection pool."""
    pool = SSHConnectionPool()

    manager1 = pool.get("host1", username="user1")
    manager2 = pool.get("host1", username="user1")  # Same host/user
    manager3 = pool.get("host2", username="user2")

    # Same connection should be reused
    assert manager1 is manager2
    # Different hosts should have different connections
    assert manager1 is not manager3

    # Check configuration is passed
    assert manager1.host == "host1"
    assert manager1.username == "user1"
