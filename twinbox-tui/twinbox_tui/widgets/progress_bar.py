"""
Progress Bar widget with percentage display.
"""

from textual.app import ComposeResult
from textual.widgets import ProgressBar, Static


class HorizontalProgressBar(ProgressBar):
    """Progress bar with percentage label."""

    def __init__(
        self,
        total: float = 100.0,
        show_percentage: bool = True,
        *,
        id: str = "progress-bar",
        **kwargs,
    ) -> None:
        """Initialize the progress bar.

        Args:
            total: Total value for 100%
            show_percentage: Whether to show percentage label
            id: Widget ID
        """
        super().__init__(total=total, show_bar=True, **kwargs)
        self._show_percentage = show_percentage
        self._percentage_label: Optional[Static] = None

    def compose(self) -> ComposeResult:
        """Compose the widget."""
        yield from super().compose()
        if self._show_percentage:
            self._percentage_label = Static("0%", id="percentage")
            yield self._percentage_label

    def set_progress(self, value: float) -> None:
        """Set the progress value.

        Args:
            value: Progress value (0-100)
        """
        clamped = max(0.0, min(float(self.total), value))
        self.progress = clamped

        if self._show_percentage and self._percentage_label:
            percentage = int((clamped / self.total) * 100)
            self._percentage_label.update(f"{percentage}%")

    def reset(self) -> None:
        """Reset progress to zero."""
        self.progress = 0.0
        if self._show_percentage and self._percentage_label:
            self._percentage_label.update("0%")
