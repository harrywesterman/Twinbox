"""
Review Configuration Screen.

Shows deployment configuration summary before execution.
"""

from typing import List

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import Button, Checkbox, Static

from ..models.wizard import WizardData
from ..widgets import WizardNavigation


class ReviewScreen(Vertical):
    """Review configuration screen."""

    def __init__(
        self,
        wizard_data: WizardData,
        *,
        id: str = "review-screen",
        **kwargs,
    ) -> None:
        """Initialize review screen.

        Args:
            wizard_data: WizardData with filled configuration
        """
        super().__init__(id=id, **kwargs)
        self.wizard_data = wizard_data
        self._navigation = None

    def compose(self) -> ComposeResult:
        """Compose layout."""
        yield Static("Review Configuration", classes="wizard-header")

        with Vertical(classes="wizard-content"):
            # Summary sections will be generated dynamically
            yield Static(id="summary-container")

            # Confirmation checkbox
            yield Checkbox(
                "I understand this will create VMs and modify my Proxmox cluster",
                id="confirmation-checkbox",
            )

        yield WizardNavigation(current_step=2, total_steps=5, id="wizard-nav")

    def on_mount(self) -> None:
        """Generate summary on mount."""
        self._navigation = self.query_one("#wizard-nav", WizardNavigation)
        self._navigation.set_can_go_back(True)
        self._navigation.set_can_go_forward(False)  # Enable after checkbox

        self._generate_summary()

    def _generate_summary(self) -> None:
        """Generate summary text from wizard_data."""
        container = self.query_one("#summary-container")
        data = self.wizard_data

        summary_lines = [
            "## Cluster",
            f"Name: {data.cluster_name}",
            f"Nodes: {', '.join(data.selected_nodes)}",
            "",
            "## Management VM",
            f"VM ID: Auto (will select from free IDs)",
            f"CPU: {data.vm_cpu_cores} cores",
            f"RAM: {data.vm_ram_mb} MB",
            f"Disk: {data.vm_disk_gb} GB",
            f"Bridge: {data.vm_bridge}",
            f"Storage: {data.vm_storage}",
            "",
            "## Control Planes",
            f"Count: {data.control_plane_count}",
            f"Placement: Will distribute across {len(data.selected_nodes)} nodes",
            "",
            f"## Workers: {data.worker_count}",
            "",
            "## Credentials",
            f"Management VM SSH: twinbox@<vm-ip>",
        ]

        summary_text = "\n".join(summary_lines)
        container.update(summary_text)

    def on_checkbox_changed(self, event: Checkbox.Changed) -> None:
        """Handle checkbox changes to enable/disable next button."""
        if event.checkbox.id == "confirmation-checkbox":
            self._navigation.set_can_go_forward(event.value)

    def on_wizard_nav_back(self) -> None:
        """Handle back button."""
        self.app.pop_screen()

    def on_wizard_nav_next(self) -> None:
        """Handle deploy button."""
        # Check confirmation
        checkbox = self.query_one("#confirmation-checkbox", Checkbox)
        if not checkbox.value:
            self.notify("Please confirm your understanding", severity="warning")
            return

        # Start deployment
        self._start_deployment()

    def _start_deployment(self) -> None:
        """Begin the deployment process."""
        try:
            # Create cluster record
            cluster_id = self.app.state_manager.create_cluster(
                name=self.wizard_data.cluster_name,
                config=self.wizard_data.to_dict(),
                status="installing",
            )

            # Create deployment record
            deployment_id = self.app.state_manager.start_deployment(cluster_id)

            # Push execution screen
            from .execute import ExecutionScreen
            execution_screen = ExecutionScreen(
                deployment_id=deployment_id,
                cluster_id=cluster_id,
                wizard_data=self.wizard_data,
            )
            self.app.push_screen(execution_screen)

        except Exception as e:
            self.notify(f"Failed to start deployment: {str(e)}", severity="error")
