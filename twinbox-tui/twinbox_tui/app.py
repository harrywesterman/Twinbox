"""
Main Twinbox TUI Application.

Entry point for the Textual-based terminal UI.
"""

import asyncio
import signal
from pathlib import Path

from textual.app import App
from textual.widgets import Header, Footer

from .config import get_config
from .database import Database, init_db
from .state_manager import StateManager
from .screens.dashboard import DashboardScreen
from .screens.logs import LogViewerScreen
from .screens.wizard import WizardScreen


class TwinboxApp(App):
    """Main Twinbox TUI application."""

    CSS_PATH = "css/tui.css"
    TITLE = "Twinbox"
    SUB_TITLE = "Kubernetes on Proxmox"

    SCREENS = {
        "dashboard": DashboardScreen,
        "wizard": WizardScreen,
        "logs": LogViewerScreen,
    }

    def __init__(self):
        super().__init__()
        self.config = None
        self.db = None
        self.state_manager = None
        self._refresh_task = None

    def compose(self):
        """Compose the app layout."""
        yield Header()
        yield Footer()

    def on_mount(self) -> None:
        """Initialize application on mount."""
        # Load configuration
        self.config = get_config()

        # Initialize database
        init_db(self.config.database_path)
        self.db = Database(self.config.database_path)
        self.db.create_tables()

        # Initialize state manager
        self.state_manager = StateManager(self.db)

        # Set up signal handlers for graceful shutdown
        loop = asyncio.get_event_loop()
        loop.add_signal_handler(signal.SIGTERM, self._handle_signal)
        loop.add_signal_handler(signal.SIGINT, self._handle_signal)

        # Push the dashboard screen
        self.push_screen("dashboard")

        # Start auto-refresh on dashboard (will be started by the dashboard itself)
        # This is handled in DashboardScreen.on_mount()

    def _handle_signal(self) -> None:
        """Handle shutdown signals."""
        self.call_from_thread(self.shutdown)

    def shutdown(self) -> None:
        """Gracefully shut down the application."""
        self.exit()

    def action_new_deployment(self) -> None:
        """Start a new deployment wizard."""
        self.push_screen("wizard")

    def action_view_logs(self) -> None:
        """View deployment logs."""
        self.push_screen("logs")

    def action_help(self) -> None:
        """Show help screen."""
        self.notify("Keyboard shortcuts:\n"
                   "n - New deployment\n"
                   "v - View logs\n"
                   "r - Retry failed deployment\n"
                   "d - Delete selected cluster\n"
                   "F5 - Refresh\n"
                   "? - This help\n"
                   "q - Quit",
                   title="Help", timeout=10)

    def action_refresh(self) -> None:
        """Refresh current screen data."""
        current = self.screen
        if hasattr(current, "refresh_data"):
            current.refresh_data()
        else:
            self.notify("Refresh not available on this screen")

    def action_retry(self) -> None:
        """Retry the last deployment for selected cluster."""
        # This will be implemented when dashboard has selection handling
        self.notify("Retry not yet implemented")

    def action_delete_selected(self) -> None:
        """Delete the currently selected cluster."""
        # This will be implemented when dashboard has selection handling
        self.notify("Delete not yet implemented")


def main() -> None:
    """Main entry point."""
    app = TwinboxApp()
    app.run()


if __name__ == "__main__":
    main()
