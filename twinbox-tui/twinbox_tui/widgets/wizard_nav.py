"""
Wizard navigation widget with back/next buttons and step indicator.
"""

from typing import Callable

from textual.app import ComposeResult
from textual.containers import Horizontal
from textual.widgets import Button, Static


class WizardNavigation(Horizontal):
    """Wizard navigation buttons with step indicator."""

    def __init__(
        self,
        current_step: int = 0,
        total_steps: int = 5,
        *,
        id: str = "wizard-nav",
        **kwargs,
    ) -> None:
        """Initialize the wizard navigation.

        Args:
            current_step: Current step index (0-based)
            total_steps: Total number of steps
            id: Widget ID
        """
        super().__init__(id=id, **kwargs)
        self._current_step = current_step
        self._total_steps = total_steps
        self._can_go_back = True
        self._can_go_forward = True

        # Callbacks
        self.on_back: Optional[Callable[[], None]] = None
        self.on_next: Optional[Callable[[], None]] = None

    def compose(self) -> ComposeResult:
        """Compose the navigation layout."""
        # Back button
        back_btn = Button(
            "Back",
            id="back-button",
            disabled=not self._can_go_back,
            variant="default",
        )
        back_btn.on_click = lambda _: self._handle_back()

        yield back_btn

        # Step indicator
        step_text = f"Step {self._current_step + 1} of {self._total_steps}"
        yield Static(step_text, id="step-indicator")

        # Next button
        next_btn = Button(
            "Next >",
            id="next-button",
            disabled=not self._can_go_forward,
            variant="primary",
        )
        next_btn.on_click = lambda _: self._handle_next()
        yield next_btn

    def on_mount(self) -> None:
        """Called when widget is mounted - re-apply button states."""
        # Re-apply button states to ensure they match the current _can_go_back/_can_go_forward
        # This handles the case where set_can_go_forward() was called before buttons were composed
        self._update_button_states()

    def update_step(self, step: int) -> None:
        """Update the current step indicator.

        Args:
            step: New step index (0-based)
        """
        self._current_step = step
        step_indicator = self.query_one("#step-indicator", Static)
        step_indicator.update(f"Step {step + 1} of {self._total_steps}")

        # Update button states
        self._update_button_states()

    def set_can_go_back(self, can_go: bool) -> None:
        """Set whether back navigation is allowed.

        Args:
            can_go: True to enable back button
        """
        self._can_go_back = can_go
        self._update_button_states()

    def set_can_go_forward(self, can_go: bool) -> None:
        """Set whether forward navigation is allowed.

        Args:
            can_go: True to enable next button
        """
        self._can_go_forward = can_go
        self._update_button_states()

    def _update_button_states(self) -> None:
        """Update button disabled states."""
        # Check if buttons exist (they might not be mounted yet)
        try:
            back_btn = self.query_one("#back-button", Button)
            next_btn = self.query_one("#next-button", Button)
        except Exception:
            # Buttons not yet mounted, skip update
            return

        back_btn.disabled = not self._can_go_back
        next_btn.disabled = not self._can_go_forward

    def _handle_back(self) -> None:
        """Handle back button click."""
        if self.on_back:
            self.on_back()

    def _handle_next(self) -> None:
        """Handle next button click."""
        if self.on_next:
            self.on_next()
