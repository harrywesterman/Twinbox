"""
Reusable form field widgets for the wizard.
"""

from typing import Callable, List, Optional

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import (
    Button,
    Checkbox,
    Input,
    Label,
    Select,
    TextArea,
)


class FormField(Vertical):
    """Base class for form fields with label."""

    def __init__(self, field_id: str, label: str, help_text: str = "", **kwargs) -> None:
        """Initialize a form field.

        Args:
            field_id: Widget ID for the input
            label: Field label text
            help_text: Optional helper/description text
        """
        super().__init__(**kwargs)
        self.field_id = field_id
        self.label_text = label
        self.help_text = help_text

    def compose(self) -> ComposeResult:
        """Compose the field layout."""
        yield Label(self.label_text, classes="field-label")
        yield self._create_input()


class ClusterNameInput(Vertical):
    """Cluster name input with validation."""

    def __init__(self, value: str = "", **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value
        self._on_change: Optional[Callable[[str], None]] = None

    def compose(self) -> ComposeResult:
        yield Label("Cluster Name", classes="field-label")
        input_widget = Input(value=self._value, id="cluster-name", placeholder="my-cluster")
        yield input_widget

    def on_input_changed(self, event: Input.Changed) -> None:
        """Handle input change."""
        self._value = event.value
        if self._on_change:
            self._on_change(event.value)

    @property
    def value(self) -> str:
        return self._value

    def set_change_callback(self, callback: Callable[[str], None]) -> None:
        self._on_change = callback


class SSHKeyInput(Vertical):
    """SSH public key text area."""

    def __init__(self, value: str = "", **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value

    def compose(self) -> ComposeResult:
        yield Label("SSH Public Key", classes="field-label")
        yield TextArea(value=self._value, language="ssh", id="ssh-pubkey")

    @property
    def value(self) -> str:
        return self.query_one(TextArea).text


class CpuSelect(Vertical):
    """CPU cores selector."""

    def __init__(self, value: int = 2, min_val: int = 1, max_val: int = 16, **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value
        self._min = min_val
        self._max = max_val
        self._options = [(str(i), str(i)) for i in range(min_val, max_val + 1)]

    def compose(self) -> ComposeResult:
        yield Label("CPU Cores", classes="field-label")
        yield Select(
            options=self._options,
            value=str(self._value),
            id="cpu-cores",
        )

    @property
    def value(self) -> int:
        select = self.query_one(Select)
        return int(select.value) if select.value else self._value

    def set_on_change(self, callback: Callable[[int], None]) -> None:
        select = self.query_one(Select)
        select.watch_value = lambda old, new: callback(int(new) if new else 0)


class RamInput(Vertical):
    """RAM input in MB."""

    def __init__(self, value: int = 4096, **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value

    def compose(self) -> ComposeResult:
        yield Label("RAM (MB)", classes="field-label")
        yield Input(value=str(self._value), id="ram-input", type="integer")

    @property
    def value(self) -> int:
        input_widget = self.query_one(Input)
        try:
            return int(input_widget.value)
        except ValueError:
            return 4096


class DiskInput(Vertical):
    """Disk size input in GB."""

    def __init__(self, value: int = 32, **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value

    def compose(self) -> ComposeResult:
        yield Label("Disk Size (GB)", classes="field-label")
        yield Input(value=str(self._value), id="disk-input", type="integer")

    @property
    def value(self) -> int:
        input_widget = self.query_one(Input)
        try:
            return int(input_widget.value)
        except ValueError:
            return 32


class ControlPlaneCountSelect(Vertical):
    """Control plane count selector."""

    def __init__(self, value: int = 3, **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value
        self._options = [("1", "1"), ("3", "3"), ("5", "5")]

    def compose(self) -> ComposeResult:
        yield Label("Control Plane Nodes", classes="field-label")
        yield Select(
            options=self._options,
            value=str(self._value),
            id="cp-count",
        )

    @property
    def value(self) -> int:
        select = self.query_one(Select)
        return int(select.value) if select.value else self._value


class WorkerCountInput(Vertical):
    """Worker count input."""

    def __init__(self, value: int = 0, **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value

    def compose(self) -> ComposeResult:
        yield Label("Worker Nodes", classes="field-label")
        yield Input(value=str(self._value), id="worker-count", type="integer")

    @property
    def value(self) -> int:
        input_widget = self.query_one(Input)
        try:
            return int(input_widget.value)
        except ValueError:
            return 0


class NodeMultiCheck(Vertical):
    """Multi-checkbox for node selection."""

    def __init__(self, nodes: List[str] = None, **kwargs) -> None:
        super().__init__(**kwargs)
        self._nodes = nodes or []
        self._selected = set()

    def compose(self) -> ComposeResult:
        yield Label("Select Proxmox Nodes", classes="field-label")
        for node in self.nodes:
            checkbox = Checkbox(node, value=True, id=f"node-{node}")
            checkbox.watch_value = lambda old, new, n=node: self._on_toggle(n, new)
            yield checkbox

    def _on_toggle(self, node: str, checked: bool) -> None:
        if checked:
            self._selected.add(node)
        else:
            self._selected.discard(node)

    @property
    def selected_nodes(self) -> List[str]:
        return list(self._selected)

    @property
    def all_nodes(self) -> List[str]:
        return self._nodes.copy()


class BridgeSelect(Vertical):
    """Network bridge selector."""

    def __init__(self, value: str = "vmbr0", **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value

    def compose(self) -> ComposeResult:
        yield Label("Network Bridge", classes="field-label")
        # Default option, can be populated dynamically
        yield Select(options=[("vmbr0", "vmbr0")], value=self._value, id="bridge-select")

    @property
    def value(self) -> str:
        select = self.query_one(Select)
        return select.value or self._value

    def set_options(self, bridges: List[str]) -> None:
        """Update available bridges.

        Args:
            bridges: List of bridge names
        """
        select = self.query_one(Select)
        options = [(b, b) for b in bridges]
        select.set_options(options)


class StorageSelect(Vertical):
    """Storage pool selector."""

    def __init__(self, value: str = "local-lvm", **kwargs) -> None:
        super().__init__(**kwargs)
        self._value = value

    def compose(self) -> ComposeResult:
        yield Label("Storage Pool", classes="field-label")
        yield Select(options=[("local-lvm", "local-lvm")], value=self._value, id="storage-select")

    @property
    def value(self) -> str:
        select = self.query_one(Select)
        return select.value or self._value

    def set_options(self, storage_pools: List[str]) -> None:
        """Update available storage pools.

        Args:
            storage_pools: List of storage pool names
        """
        select = self.query_one(Select)
        options = [(s, s) for s in storage_pools]
        select.set_options(options)
