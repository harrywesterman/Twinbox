"""
Cluster DataTable widget for displaying cluster information.
"""

from datetime import datetime
from typing import List, Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.widgets import DataTable


class ClusterTable(DataTable):
    """A DataTable widget for displaying clusters."""

    DEFAULT_COLUMNS = [
        ("Name", 30),
        ("Status", 12),
        ("Management IP", 15),
        ("CP Nodes", 8),
        ("Workers", 8),
        ("Created", 20),
    ]

    def __init__(
        self,
        *,
        name: str = "ClusterTable",
        id: str = "cluster-table",
        **kwargs,
    ) -> None:
        """Initialize the ClusterTable."""
        super().__init__(name=name, id=id, **kwargs)
        self.cursor_type = "row"
        self._clusters: List[dict] = []

    def compose(self) -> ComposeResult:
        """Compose the widget."""
        yield from super().compose()

    def on_mount(self) -> None:
        """Set up columns when widget is mounted."""
        for col_name, width in self.DEFAULT_COLUMNS:
            self.add_column(col_name, width=width)

    def add_cluster(self, cluster: dict) -> None:
        """Add a cluster row to the table.

        Args:
            cluster: Dictionary with keys: name, status, management_ip, management_vm_id,
                     control_plane_count, worker_count, created_at
        """
        self._clusters.append(cluster)
        self._refresh_table()

    def update_clusters(self, clusters: List[dict]) -> None:
        """Replace all clusters in the table.

        Args:
            clusters: List of cluster dictionaries
        """
        self._clusters = clusters
        self._refresh_table()

    def _refresh_table(self) -> None:
        """Refresh the table display from _clusters data."""
        self.clear()

        for cluster in self._clusters:
            # Format status with color
            status_text = self._format_status(cluster["status"])

            # Format created date
            created = cluster.get("created_at")
            if isinstance(created, datetime):
                created_str = created.strftime("%Y-%m-%d %H:%M")
            else:
                created_str = str(created) if created else ""

            row = [
                cluster["name"],
                status_text,
                cluster.get("management_ip") or "",
                str(cluster.get("control_plane_count", 0)),
                str(cluster.get("worker_count", 0)),
                created_str,
            ]

            self.add_row(*row, key=cluster["id"])

    def _format_status(self, status: str) -> Text:
        """Format status with color badge.

        Args:
            status: Status string

        Returns:
            Rich Text object with colored status
        """
        status_colors = {
            "pending": "yellow",
            "installing": "blue",
            "deployed": "green",
            "failed": "red",
        }

        color = status_colors.get(status, "white")
        return Text(status.capitalize(), style=color)

    def get_selected_cluster(self) -> Optional[dict]:
        """Get the currently selected cluster data.

        Returns:
            Cluster dictionary or None if no selection
        """
        cursor_row = self.cursor_row
        if cursor_row is None or cursor_row >= len(self._clusters):
            return None

        return self._clusters[cursor_row]

    def get_selected_cluster_id(self) -> Optional[str]:
        """Get the ID of the selected cluster.

        Returns:
            Cluster ID or None
        """
        cluster = self.get_selected_cluster()
        return cluster["id"] if cluster else None

    def clear_clusters(self) -> None:
        """Remove all clusters from the table."""
        self._clusters.clear()
        self.clear(rows=True)
