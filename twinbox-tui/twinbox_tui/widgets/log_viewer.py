"""
Log Viewer widget based on RichLog.
"""

from typing import Dict, Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.widgets import RichLog


class LogViewer(RichLog):
    """Log viewer widget with level filtering and coloring."""

    LEVEL_COLORS: Dict[str, str] = {
        "DEBUG": "dim white",
        "INFO": "white",
        "WARNING": "yellow",
        "ERROR": "red",
        "SUCCESS": "green",
    }

    def __init__(
        self,
        *,
        id: str = "log-viewer",
        **kwargs,
    ) -> None:
        """Initialize the log viewer.

        Args:
            id: Widget ID
        """
        super().__init__(id=id, **kwargs)
        self._auto_scroll = True
        self._level_filter: Optional[str] = None
        self._lines: list = []  # Store all lines for filtering

    def add_log(self, level: str, step: str, message: str) -> None:
        """Add a log line to the viewer.

        Args:
            level: Log level (INFO, WARNING, ERROR, SUCCESS, DEBUG)
            step: Step name or context
            message: Log message
        """
        # Store line
        line_data = {"level": level, "step": step, "message": message}
        self._lines.append(line_data)

        # Apply filter
        if self._should_display(level):
            self._render_log(level, step, message)

    def _should_display(self, level: str) -> bool:
        """Check if a log level passes the current filter.

        Args:
            level: Log level

        Returns:
            True if should display
        """
        if not self._level_filter:
            return True
        return level == self._level_filter

    def _render_log(self, level: str, step: str, message: str) -> None:
        """Render a log line with appropriate formatting.

        Args:
            level: Log level
            step: Step name
            message: Log message
        """
        # Format: [LEVEL] Step: message
        color = self.LEVEL_COLORS.get(level, "white")
        timestamp = ""
        # You can add timestamp format if desired

        # Build formatted text
        level_text = Text(f"[{level}]", style=color)
        step_text = Text(f" {step}:", style="cyan")
        msg_text = Text(f" {message}", style=color)

        full_text = level_text + step_text + msg_text

        self.write(full_text)

    def clear_logs(self) -> None:
        """Clear all logs from display."""
        self._lines.clear()
        self.clear()

    def set_level_filter(self, level: Optional[str]) -> None:
        """Set level filter for displayed logs.

        Args:
            level: Level to filter by, or None to show all
        """
        self._level_filter = level
        self._apply_filter()

    def _apply_filter(self) -> None:
        """Re-apply filter to all stored lines."""
        self.clear()
        for line in self._lines:
            if self._should_display(line["level"]):
                self._render_log(line["level"], line["step"], line["message"])

    def toggle_auto_scroll(self) -> None:
        """Toggle auto-scroll to bottom on new logs."""
        self._auto_scroll = not self._auto_scroll

    @property
    def auto_scroll(self) -> bool:
        """Get auto-scroll state."""
        return self._auto_scroll

    def scroll_to_bottom(self) -> None:
        """Force scroll to bottom if auto-scroll is enabled."""
        if self._auto_scroll:
            self.scroll_end(animate=False)
