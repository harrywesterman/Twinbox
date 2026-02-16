"""
Preflight Check Panel widget.

Displays a grid of check results with status icons.
"""

from typing import List, Dict

from textual.app import ComposeResult
from textual.containers import Grid
from textual.widgets import Static


class PreflightPanel(Grid):
    """Panel displaying preflight check results in a grid."""

    # Status icons
    ICONS = {
        "pending": "⏳",
        "running": "⟳",
        "success": "✓",
        "warning": "⚠",
        "error": "✗",
    }

    def __init__(
        self,
        *,
        id: str = "preflight-panel",
        **kwargs,
    ) -> None:
        """Initialize the preflight panel."""
        super().__init__(id=id, **kwargs)
        self._results: Dict[str, dict] = {}

    def on_mount(self) -> None:
        """Set up grid layout when mounted."""
        self.styles.grid_size_columns = 2
        self.styles.grid_gap = (1, 1)

    def update_results(self, results: List[dict]) -> None:
        """Update the display with new check results.

        Args:
            results: List of check result dicts with keys:
                     check_name, passed, message, status (pending/running/etc)
        """
        self._results = {r["check_name"]: r for r in results}
        self._refresh_grid()

    def _refresh_grid(self) -> None:
        """Refresh grid display from stored results."""
        self.remove_children()

        for check_name, result in self._results.items():
            # Create row with label, status icon, and message
            status = result.get("status", "pending")
            icon = self.ICONS.get(status, "?")
            message = result.get("message", "")

            # Label (check name)
            label = Static(f"{icon} {check_name.replace('_', ' ').title()}", classes="check-name")

            # Details (message)
            details = Static(message or "", classes="check-details")
            details.styles.text_style = "italic"

            # Apply status color
            color_map = {
                "success": "green",
                "error": "red",
                "warning": "yellow",
                "running": "blue",
                "pending": "white",
            }
            color = color_map.get(status, "white")
            label.styles.color = color

            self.mount(label)
            self.mount(details)

    def set_check_status(self, check_name: str, status: str, message: str = "") -> None:
        """Update a single check's status.

        Args:
            check_name: Check identifier
            status: New status (pending/running/success/warning/error)
            message: Optional message
        """
        if check_name not in self._results:
            return

        self._results[check_name]["status"] = status
        if message:
            self._results[check_name]["message"] = message

        self._refresh_grid()

    def clear_results(self) -> None:
        """Clear all check results."""
        self._results.clear()
        self.remove_children()
