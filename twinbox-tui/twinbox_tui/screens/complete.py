"""
Deployment Completion Screen.

Shows final deployment status and next steps.
"""

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import Screen
from textual.widgets import Button, Static

from ..widgets import WizardNavigation


class CompletionScreen(Screen):
    """Deployment completion screen."""

    def __init__(
        self,
        deployment_id: str,
        cluster_id: str,
        *,
        id: str = "complete-screen",
        **kwargs,
    ) -> None:
        """Initialize completion screen.

        Args:
            deployment_id: Deployment UUID
            cluster_id: Cluster UUID
        """
        super().__init__(id=id, **kwargs)
        self.deployment_id = deployment_id
        self.cluster_id = cluster_id

    def compose(self) -> ComposeResult:
        """Compose layout."""
        # Icon will be set in on_mount
        yield Static("⏳", id="status-icon", classes="icon")

        yield Static(id="heading", classes="heading")

        with Vertical(id="details", classes="details"):
            # Details filled in on mount
            pass

        with Vertical(id="actions", classes="actions"):
            # Action buttons filled in on mount
            pass

    def on_mount(self) -> None:
        """Display completion status."""
        deployment = self.app.state_manager.get_deployment(self.deployment_id)
        cluster = self.app.state_manager.get_cluster(self.cluster_id)

        if not deployment:
            self._show_error("Deployment not found")
            return

        status = deployment["status"]
        success = status == "success"

        # Update icon and heading
        icon = self.query_one("#status-icon", Static)
        heading = self.query_one("#heading", Static)

        if success:
            icon.update("✅")
            heading.update("Deployment Successful!")
            heading.styles.color = "green"
        else:
            icon.update("❌")
            heading.update("Deployment Failed")
            heading.styles.color = "red"

        # Populate details
        details_container = self.query_one("#details", Vertical)
        details_container.remove_children()

        if success:
            ip = cluster.get("management_ip", "Pending IP retrieval") if cluster else "Unknown"
            details = [
                Static("Management VM ready!", classes="detail-item"),
                Static(f"IP Address: {ip}", classes="detail-item"),
                Static(f"Web UI: http://{ip}:8080", classes="detail-item"),
                Static("Kubeconfig: Generated", classes="detail-item"),
                Static("", classes="spacer"),
                Static("Next steps:", classes="detail-subheader"),
                Static("1. Open the web UI to monitor your cluster", classes="detail-item"),
                Static("2. Access applications via the ingress", classes="detail-item"),
                Static("3. Use talosctl/kubectl with generated kubeconfig", classes="detail-item"),
            ]
        else:
            error = deployment.get("error_message", "Unknown error")
            details = [
                Static("Deployment did not complete successfully", classes="detail-item"),
                Static(f"Error: {error}", classes="detail-item error"),
                Static("", classes="spacer"),
                Static("Troubleshooting:", classes="detail-subheader"),
                Static("• Check the logs for detailed error messages", classes="detail-item"),
                Static("• Verify Proxmox connectivity and resources", classes="detail-item"),
                Static("• Retry the deployment after fixing issues", classes="detail-item"),
            ]

        for detail in details_container.mount(*details):
            details_container.mount(detail)

        # Populate actions
        actions_container = self.query_one("#actions", Vertical)
        actions_container.remove_children()

        if success:
            btn_web = Button("Open Web UI", id="btn-web", variant="primary")
            btn_web.on_click = lambda _: self._open_web_ui(cluster)

            btn_logs = Button("View Logs", id="btn-logs", variant="default")
            btn_logs.on_click = lambda _: self._action_view_logs()

            btn_another = Button("Deploy Another", id="btn-another", variant="default")
            btn_another.on_click = lambda _: self._action_deploy_another()

            actions_container.mount(btn_web)
            actions_container.mount(btn_logs)
            actions_container.mount(btn_another)
        else:
            btn_retry = Button("Retry", id="btn-retry", variant="primary")
            btn_retry.on_click = lambda _: self._action_retry()

            btn_logs = Button("View Full Logs", id="btn-logs", variant="default")
            btn_logs.on_click = lambda _: self._action_view_logs()

            btn_dashboard = Button("Back to Dashboard", id="btn-dashboard", variant="default")
            btn_dashboard.on_click = lambda _: self._action_back_to_dashboard()

            actions_container.mount(btn_retry)
            actions_container.mount(btn_logs)
            actions_container.mount(btn_dashboard)

    def _open_web_ui(self, cluster: dict) -> None:
        """Open web UI in browser.

        Args:
            cluster: Cluster dictionary with management_ip
        """
        ip = cluster.get("management_ip") if cluster else None
        if ip:
            import webbrowser
            url = f"http://{ip}:8080"
            webbrowser.open(url)
            self.notify(f"Opening {url}", severity="information")
        else:
            self.notify("IP address not yet available", severity="warning")

    def _action_view_logs(self) -> None:
        """Go to logs screen."""
        self.app.push_screen("logs")

    def _action_deploy_another(self) -> None:
        """Start a new deployment."""
        self.app.pop_screen()  # Back to dashboard
        self.app.action_new_deployment()

    def _action_retry(self) -> None:
        """Retry the failed deployment."""
        # This would reset the deployment and go back to review
        self.notify("Retry not implemented", severity="warning")

    def _action_back_to_dashboard(self) -> None:
        """Return to dashboard."""
        self.app.pop_screen()

    def _show_error(self, message: str) -> None:
        """Show error state.

        Args:
            message: Error message
        """
        icon = self.query_one("#status-icon", Static)
        heading = self.query_one("#heading", Static)

        icon.update("⚠")
        heading.update("Error")
        heading.styles.color = "yellow"

        details = self.query_one("#details", Vertical)
        details.mount(Static(f"Error: {message}", classes="error"))

        # Show back to dashboard button
        actions = self.query_one("#actions", Vertical)
        btn = Button("Back to Dashboard", id="btn-dashboard", variant="default")
        btn.on_click = lambda _: self._action_back_to_dashboard()
        actions.mount(btn)
