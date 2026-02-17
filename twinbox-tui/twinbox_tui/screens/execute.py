"""
Execution Progress Screen.

Shows live deployment progress with progress bar and log viewer.
"""

import asyncio
from typing import Optional

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, Static

from ..deployment_executor import DeploymentExecutor
from ..models.wizard import WizardData
from ..widgets import HorizontalProgressBar, LogViewer, WizardNavigation


class ExecutionScreen(Vertical):
    """Execution progress screen."""

    def __init__(
        self,
        deployment_id: str,
        cluster_id: str,
        wizard_data: WizardData,
        *,
        id: str = "execute-screen",
        **kwargs,
    ) -> None:
        """Initialize execution screen.

        Args:
            deployment_id: Deployment UUID
            cluster_id: Cluster UUID
            wizard_data: WizardData with configuration
        """
        super().__init__(id=id, **kwargs)
        self.deployment_id = deployment_id
        self.cluster_id = cluster_id
        self.wizard_data = wizard_data
        self._navigation = None
        self._progress_bar = None
        self._log_viewer = None
        self._step_label = None
        self._executor: Optional[DeploymentExecutor] = None
        self._execution_task: Optional[asyncio.Task] = None

    def compose(self) -> ComposeResult:
        """Compose layout."""
        yield Static("Deployment in Progress", classes="wizard-header")

        with Vertical(classes="wizard-content"):
            # Current step
            yield Static("Initializing...", id="current-step")

            # Progress bar
            yield HorizontalProgressBar(total=100, show_percentage=True, id="progress-bar")

            # Log viewer
            yield LogViewer(id="log-viewer")

        # Footer controls
        with Horizontal(classes="execution-footer", id="execution-footer"):
            yield Button("Pause", id="btn-pause")
            yield Button("Cancel", id="btn-cancel", variant="error")
            yield Button("Background", id="btn-background")

        # Wizard navigation (hidden during execution, shown on completion)
        yield WizardNavigation(current_step=3, total_steps=5, id="wizard-nav", classes="hidden")

    def on_mount(self) -> None:
        """Start execution when mounted."""
        self._step_label = self.query_one("#current-step", Static)
        self._progress_bar = self.query_one("#progress-bar", HorizontalProgressBar)
        self._log_viewer = self.query_one("#log-viewer", LogViewer)
        self._navigation = self.query_one("#wizard-nav", WizardNavigation)

        # Initialize progress
        self._progress_bar.set_progress(0)
        self._step_label.update("Starting deployment...")

        # Start background execution task
        self._execution_task = self.run_worker(self._run_deployment, exclusive=True)

    async def _run_deployment(self) -> None:
        """Execute deployment in background."""
        try:
            # Create executor
            self._executor = DeploymentExecutor(
                state_manager=self.app.state_manager,
                db=self.app.db,
                config=self.app.config,
                deployment_id=self.deployment_id,
                cluster_id=self.cluster_id,
            )

            # Define callbacks
            def progress_callback(percent: float, step_name: str) -> None:
                self.call_from_thread(self._update_progress, percent, step_name)

            def log_callback(level: str, step: str, message: str) -> None:
                self.call_from_thread(self._add_log, level, step, message)

            # Execute
            success = await self._executor.execute(
                progress_callback=progress_callback,
                log_callback=log_callback,
            )

            # Deployment completed
            self.call_from_thread(self._deployment_completed, success)

        except Exception as e:
            self.call_from_thread(self._deployment_failed, str(e))

    def _update_progress(self, percent: float, step_name: str) -> None:
        """Update progress bar and step label.

        Args:
            percent: Progress percentage (0-100)
            step_name: Current step name
        """
        self._progress_bar.set_progress(percent)
        self._step_label.update(f"Current: {step_name}")

    def _add_log(self, level: str, step: str, message: str) -> None:
        """Add log entry to viewer.

        Args:
            level: Log level (INFO, SUCCESS, WARNING, ERROR, DEBUG)
            step: Step name
            message: Log message
        """
        self._log_viewer.add_log(level, step, message)
        self._log_viewer.scroll_to_bottom()

    def _deployment_completed(self, success: bool) -> None:
        """Handle deployment completion.

        Args:
            success: True if deployment succeeded
        """
        status = "Deployment successful!" if success else "Deployment failed"
        level = "SUCCESS" if success else "ERROR"

        self._add_log(level, "Complete", status)
        self._step_label.update(status)

        # Update cluster status in database
        cluster_data = self.app.state_manager.get_cluster(self.cluster_id)
        if cluster_data:
            self.app.state_manager.update_cluster(
                self.cluster_id,
                status="deployed" if success else "failed",
                management_ip=cluster_data.get("management_ip"),  # should have been set
            )

        # Show completion screen with options
        self._show_completion_options(success)

    def _deployment_failed(self, error: str) -> None:
        """Handle deployment failure due to exception.

        Args:
            error: Error message
        """
        self._add_log("ERROR", "Fatal", f"Deployment failed: {error}")
        self._step_label.update("Deployment failed")

        # Mark deployment as failed
        self.app.state_manager.complete_deployment(self.deployment_id, success=False, error=error)

        # Show completion options
        self._show_completion_options(success=False)

    def _show_completion_options(self, success: bool) -> None:
        """Show completion screen with action buttons.

        Args:
            success: Whether deployment succeeded
        """
        # Hide footer controls
        footer = self.query_one("#execution-footer", Horizontal)
        footer.styles.display = "none"

        # Show wizard nav with completion options
        nav = self.query_one("#wizard-nav", WizardNavigation)
        nav.styles.display = "block"
        nav.set_can_go_back(False)  # Can't go back after completion

        if success:
            nav._navigation = None  # Disable default nav behavior
            # Replace nav buttons with completion actions
            nav.remove_children()

            # View Logs button
            logs_btn = Button("View Logs", id="btn-logs", variant="default")
            logs_btn.on_click = lambda _: self._action_view_logs()
            nav.mount(logs_btn)

            # Deploy Another button
            another_btn = Button("Deploy Another", id="btn-another", variant="primary")
            another_btn.on_click = lambda _: self._action_deploy_another()
            nav.mount(another_btn)

            self._step_label.update("Deployment complete!")
        else:
            # Failed - show retry option
            nav.set_can_go_back(True)
            nav.on_back = lambda: self._action_retry()
            nav.on_next = lambda: self._action_back_to_dashboard()

            nav.query_one("#back-button").label = "Retry"
            nav.query_one("#next-button").label = "Dashboard"

            self.notify("Deployment failed. You can retry or return to dashboard.", severity="error")

    # Action button handlers

    def action_pause(self) -> None:
        """Toggle auto-scroll."""
        self._log_viewer.toggle_auto_scroll()
        pause_btn = self.query_one("#btn-pause")
        pause_btn.label = "Resume" if not self._log_viewer.auto_scroll else "Pause"

    def action_cancel(self) -> None:
        """Cancel deployment."""
        from textual.widgets import Dialog, Button, Label

        # TODO: Implement cancel confirmation dialog
        self.notify("Cancel not fully implemented", severity="warning")

    def action_background(self) -> None:
        """Return to dashboard while deployment continues."""
        self.app.pop_screen()
        self.notify("Deployment running in background", severity="information")

    def _action_view_logs(self) -> None:
        """Go to logs screen."""
        self.app.push_screen("logs")

    def _action_deploy_another(self) -> None:
        """Start another deployment."""
        self.app.pop_screen()  # Back to dashboard
        self.app.action_new_deployment()

    def _action_retry(self) -> None:
        """Retry failed deployment."""
        # Implementation would reset deployment and restart executor
        self.notify("Retry not implemented", severity="warning")

    def _action_back_to_dashboard(self) -> None:
        """Return to dashboard."""
        self.app.pop_screen()

    # Button handlers
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle footer button clicks."""
        button_id = event.button.id
        if button_id == "btn-pause":
            self.action_pause()
        elif button_id == "btn-cancel":
            self.action_cancel()
        elif button_id == "btn-background":
            self.action_background()
        elif button_id == "btn-logs":
            self._action_view_logs()
        elif button_id == "btn-another":
            self._action_deploy_another()

    def on_wizard_nav_back(self) -> None:
        """Handle wizard navigation back."""
        self._action_retry()

    def on_wizard_nav_next(self) -> None:
        """Handle wizard navigation next."""
        self._action_back_to_dashboard()

    def on_unmount(self) -> None:
        """Clean up on unmount."""
        if self._execution_task and not self._execution_task.done():
            self._execution_task.cancel()
