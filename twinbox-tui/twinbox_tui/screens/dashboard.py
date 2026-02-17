"""
Dashboard screen for Twinbox TUI.

Main screen showing cluster list and action buttons.
"""

from datetime import datetime
from typing import List

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Header, Static

from ..state_manager import StateManager
from ..widgets import ClusterTable


class DashboardScreen(Screen):
    """Main dashboard screen."""

    BINDINGS = [
        ("n", "new_deployment", "New"),
        ("v", "view_logs", "Logs"),
        ("r", "retry", "Retry"),
        ("d", "delete", "Delete"),
        ("f5", "refresh", "Refresh"),
        ("?", "help", "Help"),
        ("q", "quit", "Quit"),
    ]

    def __init__(self, *args, **kwargs):
        """Initialize dashboard."""
        super().__init__(*args, **kwargs)
        self.state_manager = None
        self._last_refresh = None

    def compose(self) -> ComposeResult:
        """Compose the dashboard layout."""
        yield Header()
        with Horizontal():
            # Main content area
            with Vertical(classes="main-content"):
                yield Static("Clusters", classes="heading")
                yield ClusterTable(id="cluster-table")
                yield Static("", id="status-bar")
            # Sidebar
            with Vertical(classes="sidebar"):
                yield Static("Actions", classes="heading")
                yield Button("New Deployment", id="btn-new", classes="sidebar-button primary")
                yield Button("View Logs", id="btn-logs", classes="sidebar-button")
                yield Button("Retry", id="btn-retry", classes="sidebar-button", disabled=True)
                yield Button("Delete", id="btn-delete", classes="sidebar-button danger", disabled=True)
                yield Button("Refresh", id="btn-refresh", classes="sidebar-button")
                yield Button("Help", id="btn-help", classes="sidebar-button")
                yield Static()
                yield Static("Twinbox TUI", classes="subtitle")
                yield Static("Kubernetes on Proxmox", classes="version")
                yield Static()
                yield Static("Press F5 to refresh", classes="help-text")
                yield Static("n: New  v: Logs  r: Retry  d: Delete", classes="help-text")
        yield Footer()

    def on_mount(self) -> None:
        """Initialize on mount."""
        # Get state_manager from app
        if not self.state_manager:
            self.state_manager = self.app.state_manager

        self.refresh_data()

        # Set up auto-refresh every 30 seconds
        self.set_interval(30, self.refresh_data)

    def refresh_data(self) -> None:
        """Refresh cluster data from database."""
        clusters = self.state_manager.get_all_clusters()

        # Transform for table
        table_data = []
        for cluster in clusters:
            table_data.append({
                "id": cluster["id"],
                "name": cluster["name"],
                "status": cluster["status"],
                "management_ip": cluster.get("management_ip") or "",
                "management_vm_id": cluster.get("management_vm_id"),
                "control_plane_count": cluster.get("config", {}).get("control_plane_count", 0),
                "worker_count": cluster.get("config", {}).get("worker_count", 0),
                "created_at": cluster["created_at"],
            })

        table = self.query_one("#cluster-table", ClusterTable)
        table.update_clusters(table_data)

        # Update status bar
        self._last_refresh = datetime.utcnow()
        status_bar = self.query_one("#status-bar", Static)
        count = len(clusters)
        status_text = f"Last refresh: {self._last_refresh.strftime('%H:%M:%S')} | Total clusters: {count}"
        status_bar.update(status_text)

        # Update button states based on selection
        self._update_action_buttons()

    def on_data_table_row_selected(self, event: ClusterTable.RowSelected) -> None:
        """Handle row selection."""
        self._update_action_buttons()

    def _update_action_buttons(self) -> None:
        """Update action button states based on cluster selection."""
        table = self.query_one("#cluster-table", ClusterTable)
        cluster = table.get_selected_cluster()

        retry_btn = self.query_one("#btn-retry")
        delete_btn = self.query_one("#btn-delete")

        if cluster:
            # Enable retry only if cluster failed
            retry_btn.disabled = cluster["status"] != "failed"
            delete_btn.disabled = False
        else:
            retry_btn.disabled = True
            delete_btn.disabled = True

    # Action handlers

    def action_new_deployment(self) -> None:
        """Start new deployment wizard."""
        self.app.push_screen("wizard")

    def action_view_logs(self) -> None:
        """View logs."""
        self.app.push_screen("logs")

    def action_retry(self) -> None:
        """Retry selected cluster deployment."""
        table = self.query_one("#cluster-table", ClusterTable)
        cluster = table.get_selected_cluster()
        if cluster:
            self.notify("Retry not yet implemented", severity="warning")
        else:
            self.notify("No cluster selected", severity="warning")

    def action_delete(self) -> None:
        """Delete selected cluster."""
        table = self.query_one("#cluster-table", ClusterTable)
        cluster = table.get_selected_cluster()
        if cluster:
            self.app.call_from_thread(self._confirm_delete, cluster)
        else:
            self.notify("No cluster selected", severity="warning")

    def action_refresh(self) -> None:
        """Refresh data."""
        self.refresh_data()
        self.notify("Refreshed")

    def action_help(self) -> None:
        """Show help."""
        self.app.action_help()

    def _confirm_delete(self, cluster: dict) -> None:
        """Show delete confirmation dialog."""
        # For now, just delete directly - could add dialog
        try:
            self.state_manager.delete_cluster(cluster["id"])
            self.refresh_data()
            self.notify(f"Deleted cluster {cluster['name']}", severity="information")
        except Exception as e:
            self.notify(f"Failed to delete: {e}", severity="error")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks."""
        button_id = event.button.id
        if button_id == "btn-new":
            self.action_new_deployment()
        elif button_id == "btn-logs":
            self.action_view_logs()
        elif button_id == "btn-retry":
            self.action_retry()
        elif button_id == "btn-delete":
            self.action_delete()
        elif button_id == "btn-refresh":
            self.action_refresh()
        elif button_id == "btn-help":
            self.action_help()
