"""
Log Viewer Screen.

Standalone screen for viewing deployment logs with filtering.
"""

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Button, Select, Static

from ..widgets import LogViewer


class LogViewerScreen(Screen):
    """Log viewer screen."""

    def __init__(self, *, id: str = "logs-screen", **kwargs) -> None:
        """Initialize log viewer screen."""
        super().__init__(id=id, **kwargs)

    def compose(self) -> ComposeResult:
        """Compose layout."""
        yield Static("Deployment Logs", classes="wizard-header")

        # Toolbar with filters
        with Horizontal(id="log-toolbar"):
            yield Static("Filter: ", classes="filter-label")
            yield Select(
                options=[
                    ("All Levels", "ALL"),
                    ("INFO", "INFO"),
                    ("SUCCESS", "SUCCESS"),
                    ("WARNING", "WARNING"),
                    ("ERROR", "ERROR"),
                ],
                value="ALL",
                id="level-filter",
            )
            yield Button("Clear", id="btn-clear", variant="default")
            yield Button("Export", id="btn-export", variant="default")
            yield Button("Close", id="btn-close", variant="primary")

        # Log viewer
        yield LogViewer(id="log-viewer")

        # Footer with deployment info
        yield Static("", id="log-footer")

    def on_mount(self) -> None:
        """Load logs on mount."""
        self._load_deployments()

    def _load_deployments(self) -> None:
        """Load deployment list and most recent logs."""
        state_manager = self.app.state_manager
        deployments = []

        # Get all clusters and their deployments
        clusters = state_manager.get_all_clusters()
        for cluster in clusters:
            cluster_deployments = state_manager.db.list_deployments_for_cluster(cluster["id"])
            for dep in cluster_deployments:
                deployments.append({
                    "id": dep.id,
                    "cluster_name": cluster["name"],
                    "started_at": dep.started_at,
                    "status": dep.status,
                })

        # For now, show logs from the most recent deployment
        if deployments:
            latest = max(deployments, key=lambda d: d["started_at"])
            deployment_id = latest["id"]
            self._load_logs(deployment_id)

            footer = self.query_one("#log-footer", Static)
            footer.update(f"Showing logs for: {latest['cluster_name']} ({latest['started_at']})")
        else:
            self.query_one("#log-viewer", LogViewer).add_log("INFO", "System", "No deployments found.")

    def _load_logs(self, deployment_id: str) -> None:
        """Load logs for a specific deployment.

        Args:
            deployment_id: Deployment UUID
        """
        log_viewer = self.query_one("#log-viewer", LogViewer)
        log_viewer.clear_logs()

        logs = self.app.state_manager.get_logs(deployment_id, limit=500)
        for log in logs:
            log_viewer.add_log(
                level=log["level"],
                step="Deployment",
                message=log["message"],
            )

        log_viewer.scroll_to_bottom()

    def on_select_changed(self, event: Select.Changed) -> None:
        """Handle filter changes."""
        if event.select.id == "level-filter":
            level = event.value if event.value != "ALL" else None
            self._apply_filter(level)

    def _apply_filter(self, level: str = None) -> None:
        """Apply log level filter.

        Args:
            level: Level to filter by, or None for all
        """
        log_viewer = self.query_one("#log-viewer", LogViewer)
        log_viewer.set_level_filter(level)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle toolbar button clicks."""
        button_id = event.button.id
        if button_id == "btn-clear":
            self._action_clear()
        elif button_id == "btn-export":
            self._action_export()
        elif button_id == "btn-close":
            self.app.pop_screen()

    def _action_clear(self) -> None:
        """Clear all logs from display."""
        self.query_one("#log-viewer", LogViewer).clear_logs()

    def _action_export(self) -> None:
        """Export logs to file."""
        self.notify("Export not yet implemented", severity="warning")

    def action_close(self) -> None:
        """Close log viewer."""
        self.app.pop_screen()
