"""
Configuration Form Screen.

Collects deployment configuration parameters from the user.
"""

from typing import List

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import Screen
from textual.widgets import Static

from ..models.wizard import WizardData
from ..widgets import (
    BridgeSelect,
    ClusterNameInput,
    ControlPlaneCountSelect,
    CpuSelect,
    DiskInput,
    NodeMultiCheck,
    RamInput,
    StorageSelect,
    SSHKeyInput,
    WorkerCountInput,
    WizardNavigation,
)


class ConfigFormScreen(Screen):
    """Configuration form screen."""

    def __init__(
        self,
        wizard_data: WizardData,
        preflight_data: dict,
        *,
        id: str = "config-screen",
        **kwargs,
    ) -> None:
        """Initialize config form.

        Args:
            wizard_data: WizardData instance
            preflight_data: Preflight check results and detected environment
        """
        super().__init__(id=id, **kwargs)
        self.wizard_data = wizard_data
        self.preflight_data = preflight_data
        self._navigation = None

        # Extract preflight info
        self.nodes = preflight_data.get("nodes", [])
        self.bridges = preflight_data.get("bridges", ["vmbr0"])
        self.storage_pools = preflight_data.get("storage_pools", ["local-lvm"])

    def compose(self) -> ComposeResult:
        """Compose form layout."""
        yield Static("Cluster Configuration", classes="wizard-header")

        with Vertical(classes="wizard-content"):
            # General section
            yield Static("General", classes="section-title")
            yield ClusterNameInput(id="cluster-name-input")

            # SSH Key section
            yield SSHKeyInput(id="ssh-key-input")

            # Management VM section
            yield Static("Management VM", classes="section-title")
            with Vertical(classes="form-section"):
                yield CpuSelect(id="cpu-select")
                yield RamInput(id="ram-input")
                yield DiskInput(id="disk-input")

            # Cluster Topology section
            yield Static("Cluster Topology", classes="section-title")
            with Vertical(classes="form-section"):
                yield ControlPlaneCountSelect(id="cp-count")
                yield WorkerCountInput(id="worker-count")
                yield NodeMultiCheck(
                    nodes=self.nodes,
                    id="node-check",
                )

            # Networking section
            yield Static("Networking", classes="section-title")
            with Vertical(classes="form-section"):
                bridge_select = BridgeSelect(id="bridge-select")
                bridge_select.set_options(self.bridges)
                yield bridge_select

                storage_select = StorageSelect(id="storage-select")
                storage_select.set_options(self.storage_pools)
                yield storage_select

            # Validation summary (hidden by default)
            yield Static(id="validation-summary", classes="validation-summary")

        yield WizardNavigation(current_step=1, total_steps=5, id="wizard-nav")

    def on_mount(self) -> None:
        """Initialize form on mount."""
        self._navigation = self.query_one("#wizard-nav", WizardNavigation)
        self._navigation.set_can_go_back(True)
        self._navigation.set_can_go_forward(False)  # Validate before enabling

        # Populate from existing wizard_data if available
        self._populate_from_wizard_data()

        # Connect validation
        self._setup_validation()

    def _populate_from_wizard_data(self) -> None:
        """Populate form fields from existing wizard_data."""
        # General fields
        if self.wizard_data.cluster_name:
            self.query_one("#cluster-name-input", ClusterNameInput).query_one(Input).value = self.wizard_data.cluster_name
        if self.wizard_data.ssh_public_key:
            self.query_one("#ssh-key-input", SSHKeyInput).query_one(TextArea).text = self.wizard_data.ssh_public_key

        self.query_one("#cpu-select", CpuSelect).query_one(Select).value = str(self.wizard_data.vm_cpu_cores)
        self.query_one("#ram-input", RamInput).query_one(Input).value = str(self.wizard_data.vm_ram_mb)
        self.query_one("#disk-input", DiskInput).query_one(Input).value = str(self.wizard_data.vm_disk_gb)
        self.query_one("#cp-count", ControlPlaneCountSelect).query_one(Select).value = str(self.wizard_data.control_plane_count)
        self.query_one("#worker-count", WorkerCountInput).query_one(Input).value = str(self.wizard_data.worker_count)

        # Set bridge and storage
        self.query_one("#bridge-select", BridgeSelect).query_one(Select).value = self.wizard_data.vm_bridge
        self.query_one("#storage-select", StorageSelect).query_one(Select).value = self.wizard_data.vm_storage

        # Set node checkboxes (will need update if nodes list differs)
        node_check = self.query_one("#node-check", NodeMultiCheck)
        for node in self.nodes:
            checkbox = node_check.query_one(f"#node-{node}", Checkbox)
            checkbox.value = node in self.wizard_data.selected_nodes

    def _setup_validation(self) -> None:
        """Set up validation for all input fields."""
        # Connect change callbacks to validate_form
        inputs = [
            self.query_one("#cluster-name-input", ClusterNameInput),
            self.query_one("#cpu-select", CpuSelect),
            self.query_one("#ram-input", RamInput),
            self.query_one("#disk-input", DiskInput),
            self.query_one("#cp-count", ControlPlaneCountSelect),
            self.query_one("#worker-count", WorkerCountInput),
            self.query_one("#bridge-select", BridgeSelect),
            self.query_one("#storage-select", StorageSelect),
            self.query_one("#node-check", NodeMultiCheck),
        ]

        # Monitor changes (simplified - in a real app would connect signals)
        # For now, validate on next button press and on field changes periodically
        # This is a simplified implementation

    def validate_form(self) -> List[str]:
        """Validate all form fields.

        Returns:
            List of error messages, empty if valid
        """
        errors = []

        try:
            # Cluster name
            name_input = self.query_one("#cluster-name-input", ClusterNameInput)
            name = name_input.query_one(Input).value
            if not name:
                errors.append("Cluster name is required")
            elif not WizardData.model_fields["cluster_name"].validate(name):
                errors.append("Cluster name must be alphanumeric with hyphens")

            # CPU, RAM, Disk
            cpu = self.query_one("#cpu-select", CpuSelect).value
            ram = self.query_one("#ram-input", RamInput).value
            disk = self.query_one("#disk-input", DiskInput).value

            if cpu < 1 or cpu > 16:
                errors.append("CPU cores must be between 1 and 16")

            if ram < 512 or ram > 131072:
                errors.append("RAM must be between 512MB and 131072MB")

            if disk < 8 or disk > 1024:
                errors.append("Disk size must be between 8GB and 1024GB")

            # Control plane and worker counts
            cp_count = self.query_one("#cp-count", ControlPlaneCountSelect).value
            worker_count = self.query_one("#worker-count", WorkerCountInput).value

            if cp_count not in [1, 3, 5]:
                errors.append("Control plane count must be 1, 3, or 5")

            if worker_count < 0:
                errors.append("Worker count cannot be negative")

            # Node selection
            selected_nodes = self.query_one("#node-check", NodeMultiCheck).selected_nodes
            if len(selected_nodes) < cp_count:
                errors.append(f"Select at least {cp_count} nodes for {cp_count} control plane nodes")

        except Exception as e:
            errors.append(f"Validation error: {str(e)}")

        return errors

    def get_form_data(self) -> dict:
        """Extract configuration from form fields.

        Returns:
            Dictionary with wizard data
        """
        cluster_name = self.query_one("#cluster-name-input", ClusterNameInput).query_one(Input).value
        ssh_key = self.query_one("#ssh-key-input", SSHKeyInput).query_one(TextArea).text

        cpu = self.query_one("#cpu-select", CpuSelect).value
        ram = self.query_one("#ram-input", RamInput).value
        disk = self.query_one("#disk-input", DiskInput).value

        cp_count = self.query_one("#cp-count", ControlPlaneCountSelect).value
        worker_count = self.query_one("#worker-count", WorkerCountInput).value

        bridge = self.query_one("#bridge-select", BridgeSelect).value
        storage = self.query_one("#storage-select", StorageSelect).value

        selected_nodes = self.query_one("#node-check", NodeMultiCheck).selected_nodes

        return {
            "cluster_name": cluster_name,
            "ssh_public_key": ssh_key,
            "vm_cpu_cores": cpu,
            "vm_ram_mb": ram,
            "vm_disk_gb": disk,
            "vm_bridge": bridge,
            "vm_storage": storage,
            "control_plane_count": cp_count,
            "worker_count": worker_count,
            "selected_nodes": selected_nodes,
            "wizard_started_at": self.wizard_data.wizard_started_at,  # preserve original start time
        }

    # Wizard navigation

    def on_wizard_nav_back(self) -> None:
        """Handle back button."""
        self.app.pop_screen()

    def on_wizard_nav_next(self) -> None:
        """Handle next button."""
        errors = self.validate_form()

        if errors:
            # Show errors in summary
            summary = self.query_one("#validation-summary", Static)
            error_text = "\n".join(f"- {e}" for e in errors)
            summary.update(f"[red]Errors:[/red]\n{error_text}")
            self.notify("Please fix validation errors", severity="error")
            return

        # Update wizard_data with form values
        form_data = self.get_form_data()
        for key, value in form_data.items():
            setattr(self.wizard_data, key, value)

        self.wizard_data.preflight_passed = True

        # Push review screen
        from .review import ReviewScreen
        review_screen = ReviewScreen(self.wizard_data)
        self.app.push_screen(review_screen)
