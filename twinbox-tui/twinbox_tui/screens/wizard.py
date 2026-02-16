"""
Wizard Container Screen.

Manages the multi-screen deployment wizard flow.
"""

from textual.app import ComposeResult
from textual.containers import Container
from textual.screen import Screen

from ..models.wizard import WizardData
from .preflight import PreflightCheckScreen
from .config import ConfigFormScreen
from .review import ReviewScreen
from .execute import ExecutionScreen


class WizardScreen(Screen):
    """Wizard container that manages screen flow."""

    def __init__(self, *, id: str = "wizard-screen", **kwargs) -> None:
        """Initialize wizard screen."""
        super().__init__(id=id, **kwargs)
        # Create initial wizard data
        self.wizard_data = WizardData(
            cluster_name="",
            ssh_public_key="",
            vm_cpu_cores=2,
            vm_ram_mb=4096,
            vm_disk_gb=32,
            vm_bridge="vmbr0",
            vm_storage="local-lvm",
            control_plane_count=3,
            worker_count=0,
            selected_nodes=[],
            preflight_passed=False,
        )

    def compose(self) -> ComposeResult:
        """Compose wizard - will show first screen."""
        # The wizard screens are pushed onto the stack rather than contained
        # This container just serves as a marker for the back stack
        yield Container(id="wizard-container")

    def on_mount(self) -> None:
        """Start wizard flow by pushing first screen."""
        # Push preflight screen
        preflight = PreflightCheckScreen(self.wizard_data)
        self.app.push_screen(preflight)
