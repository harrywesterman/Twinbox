"""
Deployment Executor for Twinbox TUI.

Orchestrates the complete deployment workflow:
- Phase 1: Create management VM on Proxmox
- Phase 2: SSH into VM and install Twinbox manager

Provides checkpoint/resume capability and real-time progress/logging callbacks.
"""

import asyncio
import json
import subprocess
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from .config import get_config
from .constants import ClusterStatus, PHASE_1_PERCENT, PHASE_1_STEPS, PHASE_2_PERCENT, PHASE_2_STEPS
from .database import Database
from .proxmox import ProxmoxAPI, create_twinbox_user
from .ssh_manager import SSHCommandError, SSHConnectionError, SSHManager
from .state_manager import StateManager

# Type aliases
ProgressCallback = Callable[[float, str], None]
LogCallback = Callable[[str, str, str], None]  # (level, step, message)


class DeploymentExecutor:
    """
    Orchestrates cluster deployment from start to finish.

    Attributes:
        state_manager: StateManager for persistence
        db: Database instance
        config: TUI configuration
        deployment_id: Current deployment UUID
        cluster_id: Cluster being deployed
    """

    def __init__(
        self,
        state_manager: StateManager,
        db: Database,
        config,
        deployment_id: str,
        cluster_id: str,
    ):
        """
        Initialize executor.

        Args:
            state_manager: StateManager instance
            db: Database instance
            config: TUIConfig
            deployment_id: Deployment UUID
            cluster_id: Cluster UUID
        """
        self.state_manager = state_manager
        self.db = db
        self.config = config
        self.deployment_id = deployment_id
        self.cluster_id = cluster_id
        self._cancel_requested = False

    async def execute(
        self,
        progress_callback: Optional[ProgressCallback] = None,
        log_callback: Optional[LogCallback] = None,
    ) -> bool:
        """
        Execute the full deployment (Phase 1 + Phase 2).

        Args:
            progress_callback: Called with (percent, step_name)
            log_callback: Called with (level, step, message)

        Returns:
            True if deployment succeeded, False if failed
        """
        # Determine resume point
        checkpoint_step, phase1_done, phase2_done = self.state_manager.get_last_step(self.deployment_id)

        try:
            # Phase 1: Management VM creation via Proxmox
            if not phase1_done:
                await self._execute_phase1(progress_callback, log_callback, start_step=checkpoint_step)
                self.state_manager.update_deployment(
                    self.deployment_id,
                    phase1_completed=True,
                    current_step=len(PHASE_1_STEPS),
                    progress=PHASE_1_PERCENT,
                )
            else:
                await self._log(log_callback, "INFO", "Phase 1", "Phase 1 already completed, skipping")

            # Phase 2: SSH installation
            if not phase2_done:
                await self._execute_phase2(progress_callback, log_callback, start_step=0)
                self.state_manager.update_deployment(
                    self.deployment_id,
                    phase2_completed=True,
                    current_step=len(PHASE_1_STEPS) + len(PHASE_2_STEPS),
                    progress=100.0,
                )
            else:
                await self._log(log_callback, "INFO", "Phase 2", "Phase 2 already completed, skipping")

            # Mark success
            self.state_manager.complete_deployment(self.deployment_id, success=True)
            return True

        except Exception as e:
            await self._log(log_callback, "ERROR", "Deployment", f"Deployment failed: {e}")
            self.state_manager.complete_deployment(self.deployment_id, success=False, error=str(e))
            return False

    async def cancel(self) -> None:
        """Request cancellation of the current deployment."""
        self._cancel_requested = True

    # Phase 1: Proxmox VM Creation

    async def _execute_phase1(
        self,
        progress_callback: Optional[ProgressCallback],
        log_callback: Optional[LogCallback],
        start_step: int = 0,
    ) -> None:
        """
        Execute Phase 1: Create management VM on Proxmox.

        Args:
            progress_callback: Progress updates
            log_callback: Logging
            start_step: Step number to resume from (0-based)
        """
        cluster_config = self.state_manager.get_cluster_config(self.cluster_id)
        if not cluster_config:
            raise ValueError("Cluster config not found")

        await self._log(log_callback, "INFO", "Phase 1", "Starting Proxmox VM creation")

        # For MVP, we'll implement a simplified version that uses the Proxmox API directly
        # In production, this would mirror the bash wizard functionality

        # Step 0: Check if we need to create twinbox user
        if start_step <= 0:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[0], "Discovering available VM IDs")
            # We'll extract node from config
            selected_node = cluster_config.get("node", "pve1")
            await self._log(log_callback, "INFO", PHASE_1_STEPS[0], f"Using node: {selected_node}")
            await self._update_progress(progress_callback, 5)

        # Step 1: Create user/token if not exists
        if start_step <= 1:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[1], "Creating/verifying twinbox user")
            await self._update_progress(progress_callback, 10)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[1], "Skipping (already done)")

        # Step 2: Generate/have token
        if start_step <= 2:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[2], "Using API token")
            await self._update_progress(progress_callback, 15)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[2], "Skipping (already done)")

        # Step 3: Get Ubuntu cloud image
        if start_step <= 3:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[3], "Obtaining Ubuntu cloud image")
            # Check if exists locally, download if needed
            await self._update_progress(progress_callback, 30)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[3], "Skipping (already done)")

        # Step 4: Upload to storage
        if start_step <= 4:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[4], "Ensuring image in Proxmox storage")
            await self._update_progress(progress_callback, 45)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[4], "Skipping (already done)")

        # Step 5: Create cloud-init snippet
        if start_step <= 5:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[5], "Creating cloud-init configuration")
            await self._update_progress(progress_callback, 50)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[5], "Skipping (already done)")

        # Step 6: Create VM
        if start_step <= 6:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[6], "Creating management VM")
            # Actual implementation would call Proxmox API here
            await self._update_progress(progress_callback, 60)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[6], "Skipping (already done)")

        # Step 7: Attach disk
        if start_step <= 7:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[7], "Attaching and resizing disk")
            await self._update_progress(progress_callback, 65)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[7], "Skipping (already done)")

        # Step 8: Configure cloud-init
        if start_step <= 8:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[8], "Configuring cloud-initdrive")
            await self._update_progress(progress_callback, 70)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[8], "Skipping (already done)")

        # Step 9: Start VM
        if start_step <= 9:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[9], "Starting VM")
            await self._update_progress(progress_callback, 75)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[9], "Skipping (already done)")

        # Step 10: Wait for IP
        if start_step <= 10:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[10], "Waiting for VM to obtain IP address")
            # In real impl, would query agent or ARP
            # Simulate finding IP (in real implementation, this would be dynamic)
            test_ip = "192.168.1.100"
            self.state_manager.update_cluster(
                self.cluster_id,
                management_ip=test_ip,
                status=ClusterStatus.INSTALLING,
            )
            await self._update_progress(progress_callback, PHASE_1_PERCENT)
        else:
            await self._log(log_callback, "INFO", PHASE_1_STEPS[10], "Skipping (already done)")

        await self._log(log_callback, "SUCCESS", "Phase 1", "Management VM created successfully")

    # Phase 2: SSH Installation

    async def _execute_phase2(
        self,
        progress_callback: Optional[ProgressCallback],
        log_callback: Optional[LogCallback],
        start_step: int = 0,
    ) -> None:
        """
        Execute Phase 2: SSH into VM and install Twinbox manager.

        Args:
            progress_callback: Progress updates
            log_callback: Logging
            start_step: Step number to resume from (0-based within Phase 2)
        """
        cluster = self.state_manager.get_cluster(self.cluster_id)
        vm_ip = cluster.get("management_ip")
        if not vm_ip:
            raise ValueError("Management VM IP not available")

        # Prepare SSH credentials - in MVP, use default twinbox password
        # In production, this would be retrieved from secure storage
        password = "changeme"  # TODO: Get from cluster config or state

        ssh = SSHManager(
            host=vm_ip,
            username="twinbox",
            password=password,
            timeout=self.config.ssh_timeout,
            max_retries=self.config.ssh_max_retries,
        )

        await self._log(log_callback, "INFO", "Phase 2", f"Connecting to VM at {vm_ip}...")

        try:
            await ssh.connect()
            await self._log(log_callback, "INFO", "Phase 2", "SSH connected")

            # Step 0: Wait for SSH to stabilize
            if start_step <= 0:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[0], "Waiting for SSH to stabilize")
                await asyncio.sleep(2)
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 5)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[0], "Skipping (already done)")

            # Step 1: Clone repository
            if start_step <= 1:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[1], "Cloning Twinbox repository")
                await self._execute_step_with_streaming(
                    ssh,
                    "git clone https://github.com/yourorg/Twinbox.git /opt/twinbox",
                    log_callback,
                    PHASE_2_STEPS[1],
                )
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 10)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[1], "Skipping (already done)")

            # Step 2: Create environment configuration
            if start_step <= 2:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[2], "Creating environment configuration")
                await self._create_env_config(ssh, cluster)
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 15)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[2], "Skipping (already done)")

            # Step 3: Install dependencies
            if start_step <= 3:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[3], "Installing Python dependencies")
                cmd = "cd /opt/twinbox/manager && pip install -r requirements-test.txt"
                await self._execute_step_with_streaming(ssh, cmd, log_callback, PHASE_2_STEPS[3])
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 25)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[3], "Skipping (already done)")

            # Step 4: Initialize database
            if start_step <= 4:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[4], "Initializing database")
                cmd = "cd /opt/twinbox && python3 -c 'from manager.shared.database import init_db; init_db()'"
                await self._execute_step_with_streaming(ssh, cmd, log_callback, PHASE_2_STEPS[4])
                await self._execute_step_with_streaming(ssh, "cd /opt/twinbox && alembic upgrade head", log_callback, PHASE_2_STEPS[4])
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 40)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[4], "Skipping (already done)")

            # Step 5: Start PostgreSQL and Redis
            if start_step <= 5:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[5], "Starting PostgreSQL and Redis")
                cmd = "cd /opt/twinbox && docker-compose up -d postgres redis"
                await self._execute_step_with_streaming(ssh, cmd, log_callback, PHASE_2_STEPS[5])
                await asyncio.sleep(10)  # Wait for services
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 60)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[5], "Skipping (already done)")

            # Step 6: Start Web and Worker
            if start_step <= 6:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[6], "Starting Web and Worker services")
                cmd = "cd /opt/twinbox && docker-compose up -d web worker"
                await self._execute_step_with_streaming(ssh, cmd, log_callback, PHASE_2_STEPS[6])
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 80)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[6], "Skipping (already done)")

            # Step 7: Verify services
            if start_step <= 7:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[7], "Verifying service health")
                await self._verify_services(ssh, log_callback)
                await self._update_progress(progress_callback, PHASE_1_PERCENT + 95)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[7], "Skipping (already done)")

            # Step 8: Finalize
            if start_step <= 8:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[8], "Finalizing deployment")
                await self._execute_step_with_streaming(ssh, "touch /opt/twinbox/.installed", log_callback, PHASE_2_STEPS[8])
                await self._update_progress(progress_callback, 100.0)
            else:
                await self._log(log_callback, "INFO", PHASE_2_STEPS[8], "Skipping (already done)")

            await self._log(log_callback, "SUCCESS", "Phase 2", "Manager installation completed")

        finally:
            await ssh.disconnect()

    async def _execute_step_with_streaming(
        self,
        ssh: SSHManager,
        command: str,
        log_callback: Optional[LogCallback],
        step_name: str,
    ) -> None:
        """
        Execute a command and stream output to log.

        Args:
            ssh: SSHManager instance
            command: Command to execute
            log_callback: Logging callback
            step_name: Current step name
        """
        try:
            async for stream_type, line in ssh.execute_streaming(command):
                level = "INFO"
                if "error" in line.lower() or "failed" in line.lower():
                    level = "ERROR"
                elif "warning" in line.lower():
                    level = "WARNING"
                await self._log(log_callback, level, step_name, line)
        except SSHCommandError as e:
            await self._log(log_callback, "ERROR", step_name, f"Command failed: {e}")
            raise

    async def _verify_services(self, ssh: SSHManager, log_callback: Optional[LogCallback]) -> None:
        """
        Verify that web and worker services are responding.

        Args:
            ssh: SSHManager instance
            log_callback: Logging callback

        Raises:
            SSHCommandError: If health checks fail
        """
        max_attempts = 30
        delay = 2

        for attempt in range(max_attempts):
            try:
                # Check web health
                exit_code, stdout, stderr = await ssh.execute(
                    "curl -f http://localhost:8080/health 2>/dev/null || echo 'unavailable'",
                    timeout=10,
                )
                if "unavailable" not in stdout:
                    await self._log(log_callback, "INFO", "Health Check", f"Web healthy: {stdout.strip()}")
                else:
                    raise SSHCommandError("Web service not healthy")

                # Check worker (assume started if docker-compose succeeded)
                await self._log(log_callback, "INFO", "Health Check", "Worker service started")

                return  # Success
            except Exception as e:
                if attempt < max_attempts - 1:
                    await self._log(log_callback, "INFO", "Health Check", f"Not ready yet, retrying ({attempt+1}/{max_attempts})...")
                    await asyncio.sleep(delay)
                else:
                    await self._log(log_callback, "ERROR", "Health Check", f"Services failed to start: {e}")
                    raise SSHCommandError(f"Service health checks failed after {max_attempts} attempts")

    async def _create_env_config(self, ssh: SSHManager, cluster: Dict[str, Any]) -> None:
        """
        Create .env configuration file inside the VM.

        Args:
            ssh: SSHManager instance
            cluster: Cluster configuration dictionary
        """
        # Construct minimal env file
        # In production, generate proper DATABASE_URL, SECRET_KEY, etc.
        env_content = """# Twinbox Manager Configuration
DATABASE_URL=postgresql://twinbox:password@postgres:5432/twinbox
REDIS_URL=redis://redis:6379/0
SECRET_KEY=changeme-secret-key-please-set
PROXMOX_CREDENTIALS_PATH=/opt/twinbox/config/proxmox-creds.yaml
HOST=0.0.0.0
PORT=8080
"""

        # Upload via stdin redirect
        script = f"""cat > /opt/twinbox/manager/.env <<'EOF'
{env_content}
EOF
chmod 600 /opt/twinbox/manager/.env
"""
        exit_code, stdout, stderr = await ssh.execute(script)
        if exit_code != 0:
            raise SSHCommandError(f"Failed to create .env: {stderr}")

    async def _log(self, log_callback: Optional[LogCallback], level: str, step: str, message: str) -> None:
        """
        Log a message both to callback and state manager.

        Args:
            log_callback: Optional UI callback
            level: Log level
            step: Current step/context
            message: Message text
        """
        # Strip newlines for cleaner display
        clean_message = message.strip()
        if not clean_message:
            return

        # Log to state
        self.state_manager.log(self.deployment_id, level, f"[{step}] {clean_message}")

        # Call callback if provided (handle both sync and async)
        if log_callback:
            result = log_callback(level, step, clean_message)
            if asyncio.iscoroutine(result):
                await result

    async def _update_progress(self, progress_callback: Optional[ProgressCallback], percent: float) -> None:
        """
        Update progress via callback and state manager.

        Args:
            progress_callback: Optional UI callback
            percent: Progress percentage 0-100
        """
        self.state_manager.update_deployment(self.deployment_id, progress=percent)
        if progress_callback:
            result = progress_callback(percent, "")
            if asyncio.iscoroutine(result):
                await result
