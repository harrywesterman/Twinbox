"""
Tests for twinbox_tui.deployment_executor module.

Uses mocks to test the orchestration logic without real Proxmox or SSH.
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch
import asyncio

from twinbox_tui.constants import ClusterStatus, PHASE_1_STEPS, PHASE_2_STEPS
from twinbox_tui.database import Database
from twinbox_tui.deployment_executor import DeploymentExecutor
from twinbox_tui.state_manager import StateManager


@pytest.fixture
def mock_db():
    """Create mock Database."""
    db = MagicMock()
    db.get_session.return_value.__enter__ = MagicMock(return_value=MagicMock())
    db.get_session.return_value.__exit__ = MagicMock(return_value=False)
    return db


@pytest.fixture
def mock_state_manager(mock_db):
    """Create a mock StateManager with default configurations."""
    sm = MagicMock(spec=StateManager)
    # These methods are synchronous, so use regular return_value
    sm.get_last_step.return_value = (0, False, False)
    sm.get_cluster_config.return_value = {"node": "pve1"}
    sm.get_cluster.return_value = {"management_ip": "192.168.1.100", "config": {}}
    sm.update_deployment = MagicMock()
    sm.log = MagicMock()
    sm.complete_deployment = MagicMock()
    sm.update_cluster = MagicMock()
    return sm


@pytest.fixture
def mock_config():
    """Create mock config."""
    config = MagicMock()
    config.ssh_timeout = 30
    config.ssh_max_retries = 3
    return config


@pytest.fixture
def executor(mock_state_manager, mock_db, mock_config):
    """Create DeploymentExecutor instance."""
    return DeploymentExecutor(
        state_manager=mock_state_manager,
        db=mock_db,
        config=mock_config,
        deployment_id="deploy-123",
        cluster_id="cluster-123",
    )


@pytest.mark.asyncio
async def test_execute_success_all_phases(executor, mock_state_manager):
    """Test full deployment success."""
    # Setup: cluster exists, no previous deployment
    mock_state_manager.get_last_step.return_value = (0, False, False)
    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {"node": "pve1"},
    }

    # Mock SSHManager
    mock_ssh = AsyncMock()
    mock_ssh.connect.return_value = None
    mock_ssh.execute.return_value = (0, "output", "")
    # Mock execute_streaming as async generator that yields nothing
    async def mock_streaming(*args, **kwargs):
        if False:
            yield
    mock_ssh.execute_streaming = mock_streaming
    mock_ssh.disconnect.return_value = None
    mock_ssh.is_closed = False

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        success = await executor.execute()

    assert success is True
    mock_state_manager.complete_deployment.assert_called_once_with(
        "deploy-123", success=True
    )


@pytest.mark.asyncio
async def test_execute_phase1_already_done(executor, mock_state_manager):
    """Test deployment when Phase 1 already complete."""
    # Checkpoint: phase1_done=True, phase2_done=False
    mock_state_manager.get_last_step.return_value = (11, True, False)

    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}

    # Mock SSH
    mock_ssh = AsyncMock()
    mock_ssh.connect.return_value = None
    mock_ssh.execute.return_value = (0, "output", "")
    async def mock_streaming(*args, **kwargs):
        if False:
            yield
    mock_ssh.execute_streaming = mock_streaming
    mock_ssh.disconnect.return_value = None
    mock_ssh.is_closed = False

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        success = await executor.execute()

    assert success is True
    # Should only run Phase 2
    mock_ssh.connect.assert_called_once()
    # Phase 2 steps should be executed
    assert mock_ssh.execute.call_count > 0


@pytest.mark.asyncio
async def test_execute_phase2_already_done(executor, mock_state_manager):
    """Test deployment when both phases already complete."""
    mock_state_manager.get_last_step.return_value = (18, True, True)

    success = await executor.execute()

    assert success is True
    # Should skip both phases, just mark complete (already complete)
    mock_state_manager.complete_deployment.assert_called_once_with(
        "deploy-123", success=True
    )


@pytest.mark.asyncio
async def test_execute_with_resume_from_checkpoint(executor, mock_state_manager):
    """Test resuming from a checkpoint in the middle of Phase 2."""
    # Simulate: Phase 1 complete, Phase 2 at step 3 (installing deps)
    mock_state_manager.get_last_step.return_value = (13, True, False)  # 11 + 2

    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {"node": "pve1"},
    }

    mock_ssh = AsyncMock()
    mock_ssh.connect.return_value = None
    mock_ssh.execute.return_value = (0, "output", "")
    async def mock_streaming(*args, **kwargs):
        if False:
            yield
    mock_ssh.execute_streaming = mock_streaming
    mock_ssh.disconnect.return_value = None
    mock_ssh.is_connected = True

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        success = await executor.execute()

    assert success is True

    # Verify that Phase 1 was logged as skipped
    log_messages = [call[0][2] for call in mock_state_manager.log.call_args_list if call[0]]
    # The message includes "already completed, skipping" or "Skipping (already done)"
    assert any("skipping" in msg.lower() and "already" in msg.lower() for msg in log_messages), f"Log messages: {log_messages}"


@pytest.mark.asyncio
async def test_execute_phase1_fails(executor, mock_state_manager):
    """Test failure during Phase 1."""
    mock_state_manager.get_last_step.return_value = (0, False, False)
    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}

    # Simulate failure in Phase 1
    with patch.object(executor, '_execute_phase1', side_effect=Exception("Phase 1 error")):
        success = await executor.execute()

    assert success is False
    mock_state_manager.complete_deployment.assert_called_once_with(
        "deploy-123", success=False, error="Phase 1 error"
    )


@pytest.mark.asyncio
async def test_execute_phase2_ssh_fails(executor, mock_state_manager):
    """Test SSH connection failure in Phase 2."""
    # Phase 1 complete
    mock_state_manager.get_last_step.return_value = (11, True, False)
    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {"node": "pve1"},
    }

    # SSH connect fails
    mock_ssh = AsyncMock()
    mock_ssh.connect.side_effect = Exception("Connection timeout")

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        success = await executor.execute()

    assert success is False
    # Disconnect should still be called in finally
    mock_ssh.disconnect.assert_called_once()


@pytest.mark.asyncio
async def test_execute_phase2_command_fails(executor, mock_state_manager):
    """Test command failure in Phase 2."""
    mock_state_manager.get_last_step.return_value = (11, True, False)
    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {"node": "pve1"},
    }

    mock_ssh = AsyncMock()
    mock_ssh.connect.return_value = None
    # Simulate command failure during step execution
    async def mock_streaming(cmd, *args, **kwargs):
        if "git clone" in cmd:
            yield ("stdout", "Cloning...")
            raise Exception("git clone failed")
        yield ("stdout", "output")
    mock_ssh.execute_streaming = mock_streaming
    mock_ssh.execute.return_value = (0, "output", "")
    mock_ssh.disconnect.return_value = None

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        success = await executor.execute()

    assert success is False


@pytest.mark.asyncio
async def test_logging_through_callbacks(executor, mock_state_manager):
    """Test that log messages go to callback and state manager."""
    # Track log calls
    log_calls = []
    async def fake_log(level, step, message):
        log_calls.append({"level": level, "step": step, "message": message})

    # Directly test the _log method
    await executor._log(fake_log, "INFO", "TestStep", "Test message")

    # Verify log was recorded
    assert len(log_calls) == 1
    assert log_calls[0]["level"] == "INFO"
    assert log_calls[0]["step"] == "TestStep"
    assert log_calls[0]["message"] == "Test message"

    # Verify state_manager.log was called
    mock_state_manager.log.assert_called()


@pytest.mark.asyncio
async def test_update_progress_callback(executor, mock_state_manager):
    """Test that progress updates trigger callbacks."""
    progress_calls = []
    def fake_progress(percent, step):
        progress_calls.append(percent)

    # Call _update_progress directly
    await executor._update_progress(fake_progress, 75.5)

    # Should clamp? Actually it's already clamped in StateManager
    assert 75.5 in progress_calls

    # State manager should also be updated
    mock_state_manager.update_deployment.assert_called_with(
        "deploy-123", progress=75.5
    )


def test_get_cluster_config_missing(executor, mock_state_manager):
    """Test handling of missing cluster config."""
    mock_state_manager.get_cluster_config.return_value = None

    with pytest.raises(ValueError, match="Cluster config not found"):
        asyncio.run(executor._execute_phase1(None, None, 0))


@pytest.mark.asyncio
async def test_phase1_execution_flow(executor, mock_state_manager):
    """Test that Phase 1 executes all expected steps."""
    mock_state_manager.get_last_step.return_value = (0, False, False)
    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}

    # Stub out the actual API calls
    # We'll just verify that all steps log and update progress

    log_calls = []
    def fake_log(level, step, message):
        log_calls.append((step, level, message))

    await executor._execute_phase1(None, fake_log, start_step=0)

    # Should have logs for each step (11 steps in PHASE_1_STEPS)
    step_names = [step for step, _, _ in log_calls]
    # Check that all step names appear (from PHASE_1_STEPS)
    for expected_step in PHASE_1_STEPS:
        assert expected_step in step_names, f"Missing step: {expected_step}"

    # Should update cluster with test IP
    mock_state_manager.update_cluster.assert_called_with(
        "cluster-123",
        management_ip="192.168.1.100",
        status=ClusterStatus.INSTALLING,
    )


@pytest.mark.asyncio
async def test_phase1_resume_from_middle(executor, mock_state_manager):
    """Test Phase 1 resume skipping completed steps."""
    mock_state_manager.get_cluster_config.return_value = {"node": "pve1"}

    log_calls = []
    def fake_log(level, step, message):
        log_calls.append((step, level, message))

    # Start from step 5
    await executor._execute_phase1(None, fake_log, start_step=5)

    step_names = [step for step, _, _ in log_calls]

    # Steps 0-4 should appear "Skipping"
    assert any("Skipping (already done)" in msg for _, _, msg in log_calls[:5])
    # Steps 5-10 should be executed (actual logs) - use actual step names from PHASE_1_STEPS
    assert PHASE_1_STEPS[5] in step_names  # Creating cloud-init snippet
    assert PHASE_1_STEPS[10] in step_names  # Waiting for VM IP address


@pytest.mark.asyncio
async def test_phase2_full_execution(executor, mock_state_manager):
    """Test Phase 2 complete execution."""
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {},
    }

    mock_ssh = AsyncMock()
    mock_ssh.is_closed = False
    mock_ssh.connect.return_value = None
    mock_ssh.execute.return_value = (0, "output", "")
    async def mock_streaming(*args, **kwargs):
        if False:
            yield
    mock_ssh.execute_streaming = mock_streaming
    mock_ssh.disconnect.return_value = None

    log_calls = []
    def fake_log(level, step, message):
        log_calls.append(step)

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        await executor._execute_phase2(None, fake_log, start_step=0)

    # Should have all Phase 2 steps (may also include "Phase 2" summary messages)
    # Verify each step from PHASE_2_STEPS is present
    for step in PHASE_2_STEPS:
        assert step in log_calls, f"Missing step: {step}"

    # Should disconnect at the end
    mock_ssh.disconnect.assert_called_once()


@pytest.mark.asyncio
async def test_phase2_verify_services_success(executor, mock_state_manager):
    """Test service health verification."""
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {},
    }

    mock_ssh = AsyncMock()
    mock_ssh.is_closed = False
    mock_ssh.connect.return_value = None
    # Simulate health check succeeding on first try
    mock_ssh.execute.return_value = (0, " healthy", "")
    async def mock_streaming(*args, **kwargs):
        if False:
            yield
    mock_ssh.execute_streaming = mock_streaming

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        await executor._execute_phase2(None, None, start_step=7)  # Start at verify step

    # Should have called health check
    health_call = mock_ssh.execute.call_args_list[-1]
    assert "curl" in health_call[0][0]


@pytest.mark.asyncio
async def test_phase2_verify_services_retry(executor, mock_state_manager):
    """Test service health verification with retries."""
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {},
    }

    mock_ssh = AsyncMock()
    mock_ssh.is_closed = False
    mock_ssh.connect.return_value = None
    # Fail first 2 attempts, succeed on 3rd
    attempt = [0]
    def mock_verify(cmd, *args, **kwargs):
        attempt[0] += 1
        if attempt[0] < 3:
            raise Exception("Not ready")
        return (0, "OK", "")
    mock_ssh.execute.side_effect = mock_verify
    async def mock_streaming(*args, **kwargs):
        if False:
            yield
    mock_ssh.execute_streaming = mock_streaming

    with patch('twinbox_tui.deployment_executor.SSHManager', return_value=mock_ssh):
        await executor._execute_phase2(None, None, start_step=7)

    # Should have retried
    assert attempt[0] == 3


@pytest.mark.asyncio
async def test_create_env_config(executor, mock_state_manager):
    """Test environment configuration generation."""
    mock_state_manager.get_cluster.return_value = {
        "management_ip": "192.168.1.100",
        "config": {"node": "pve1"},
    }

    mock_ssh = AsyncMock()
    mock_ssh.is_closed = False
    mock_ssh.execute.return_value = (0, "", "")

    await executor._create_env_config(mock_ssh, {"node": "pve1"})

    # Should have executed cat command to write file
    called_command = mock_ssh.execute.call_args[0][0]
    assert "cat > /opt/twinbox/manager/.env" in called_command
    assert "DATABASE_URL" in called_command
    assert "SECRET_KEY" in called_command
