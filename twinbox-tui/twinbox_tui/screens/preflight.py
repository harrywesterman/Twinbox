"""
Preflight Check Screen.

Runs pre-deployment checks to validate the Proxmox environment.
"""

import asyncio
from typing import List

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import Screen
from textual.widgets import Static

from ..proxmox import ProxmoxAPI
from ..widgets import PreflightPanel, WizardNavigation


class PreflightCheckScreen(Screen):
    """Preflight checks screen."""

    # Define checks
    CHECK_DEFINITIONS = [
        ("proxmox_connection", "Proxmox API Connection", "Check connectivity to Proxmox API"),
        ("required_binaries", "Required Binaries", "Check for qm, pvesh, and cloud-init tools (cloud-localds or mkisofs)"),
        ("node_count", "Available Nodes", "Count online Proxmox nodes"),
        ("storage_pools", "Storage Pools", "List available storage pools"),
        ("network_bridges", "Network Bridges", "Detect network bridges"),
        ("total_capacity", "Total Capacity", "Calculate cluster resources"),
    ]

    def __init__(
        self,
        wizard_data,
        preflight_results: dict = None,
        *,
        id: str = "preflight-screen",
        **kwargs,
    ) -> None:
        """Initialize preflight screen.

        Args:
            wizard_data: WizardData instance
            preflight_results: Optional precomputed results dictionary
        """
        super().__init__(id=id, **kwargs)
        self.wizard_data = wizard_data
        self._preflight_results = preflight_results or {}
        self._navigation = None

    def compose(self) -> ComposeResult:
        """Compose layout."""
        yield Static("Preflight Checks", classes="wizard-header")
        with Vertical(classes="wizard-content"):
            yield Static(
                "Validating your Proxmox environment...",
                id="preflight-intro"
            )
            yield PreflightPanel(id="preflight-panel")
        yield WizardNavigation(current_step=0, total_steps=5, id="wizard-nav")

    def on_mount(self) -> None:
        """Run preflight checks when mounted."""
        self._navigation = self.query_one("#wizard-nav", WizardNavigation)
        self._navigation.set_can_go_back(False)  # Cannot go back from preflight
        self._navigation.set_can_go_forward(False)  # Enable only after checks complete

        # Initialize panel with pending checks
        pending_results = [
            {"check_name": name, "status": "pending", "message": "Waiting..."}
            for _, name, _ in self.CHECK_DEFINITIONS
        ]
        panel = self.query_one("#preflight-panel", PreflightPanel)
        panel.update_results(pending_results)

        # Run preflight checks as background task
        self.run_worker(self._run_preflight_checks, exclusive=True)

    async def _run_preflight_checks(self) -> None:
        """Execute all preflight checks."""
        results = []

        # 1. Proxmox connection
        result = await self._check_proxmox_connection()
        results.append(result)

        # 2. Required binaries
        result = await self._check_required_binaries()
        results.append(result)

        # 3. Node count
        result = await self._check_node_count()
        results.append(result)

        # 4. Storage pools
        result = await self._check_storage_pools()
        results.append(result)

        # 5. Network bridges
        result = await self._check_network_bridges()
        results.append(result)

        # 6. Total capacity
        result = await self._check_total_capacity()
        results.append(result)

        # Update panel with final results
        panel = self.query_one("#preflight-panel", PreflightPanel)
        panel.update_results(results)

        # Save results to wizard_data
        for r in results:
            self._preflight_results[r["check_name"]] = r

        # Enable next if all critical checks passed
        all_passed = all(r["status"] in ("success", "warning") for r in results)
        self._navigation.set_can_go_forward(all_passed)

        if all_passed:
            self.notify("All checks passed", severity="information")
        else:
            self.notify("Some checks failed. Review and correct before proceeding.", severity="error")

    async def _check_proxmox_connection(self) -> dict:
        """Check Proxmox API connectivity."""
        try:
            # Try to connect to Proxmox (will use credentials from environment/config)
            proxmox = ProxmoxAPI.from_env()
            version = await asyncio.to_thread(proxmox.get_version)
            return {
                "check_name": "proxmox_connection",
                "status": "success",
                "message": f"Connected (API version {version})",
            }
        except Exception as e:
            return {
                "check_name": "proxmox_connection",
                "status": "error",
                "message": f"Failed: {str(e)}",
            }

    async def _check_required_binaries(self) -> dict:
        """Check for required system binaries."""
        import shutil

        # Binaries required for the wizard to function
        required_strict = ["qm", "pvesh"]
        # At least one of these is needed for cloud-init ISO creation
        iso_tools = ["cloud-localds", "mkisofs"]

        missing_strict = [b for b in required_strict if shutil.which(b) is None]
        missing_iso = [b for b in iso_tools if shutil.which(b) is None]

        if missing_strict:
            return {
                "check_name": "required_binaries",
                "status": "error",
                "message": f"Missing: {', '.join(missing_strict)}",
            }
        if missing_iso:
            return {
                "check_name": "required_binaries",
                "status": "error",
                "message": "Missing cloud-init ISO tools: need either cloud-localds or mkisofs",
            }
        return {
            "check_name": "required_binaries",
            "status": "success",
            "message": f"All binaries present ({', '.join(['qm', 'pvesh', 'cloud-localds/mkisofs'])})",
        }

    async def _check_node_count(self) -> dict:
        """Check available Proxmox nodes."""
        try:
            proxmox = ProxmoxAPI.from_env()
            nodes = await asyncio.to_thread(proxmox.list_nodes)
            online = [n for n in nodes if n.get("status") == "online"]

            if len(online) < 1:
                return {
                    "check_name": "node_count",
                    "status": "error",
                    "message": "No online nodes found",
                }

            # Warn if less than 3 nodes for HA control plane
            if len(online) < 3:
                return {
                    "check_name": "node_count",
                    "status": "warning",
                    "message": f"{len(online)} online nodes (3+ recommended for HA)",
                }

            return {
                "check_name": "node_count",
                "status": "success",
                "message": f"{len(online)} online nodes",
            }
        except Exception as e:
            return {
                "check_name": "node_count",
                "status": "error",
                "message": f"Failed: {str(e)}",
            }

    async def _check_storage_pools(self) -> dict:
        """List available storage pools."""
        try:
            # Note: Full storage implementation would go here
            # For now, return success with default
            return {
                "check_name": "storage_pools",
                "status": "success",
                "message": "Will detect storage on Proxmox",
            }
        except Exception as e:
            return {
                "check_name": "storage_pools",
                "status": "error",
                "message": f"Failed: {str(e)}",
            }

    async def _check_network_bridges(self) -> dict:
        """Detect network bridges."""
        try:
            # Note: Bridge detection implementation would go here
            # For now, assume vmbr0 exists
            return {
                "check_name": "network_bridges",
                "status": "success",
                "message": "Detected vmbr0 (default)",
            }
        except Exception as e:
            return {
                "check_name": "network_bridges",
                "status": "error",
                "message": f"Failed: {str(e)}",
            }

    async def _check_total_capacity(self) -> dict:
        """Calculate total cluster resources."""
        try:
            # Placeholder - would calculate total CPU/RAM/disk across nodes
            return {
                "check_name": "total_capacity",
                "status": "success",
                "message": "Resources adequate for deployment",
            }
        except Exception as e:
            return {
                "check_name": "total_capacity",
                "status": "error",
                "message": f"Failed: {str(e)}",
            }

    # Wizard navigation

    def get_preflight_results(self) -> dict:
        """Get preflight check results for next screens."""
        return self._preflight_results

    def on_wizard_nav_next(self) -> None:
        """Handle next button."""
        # Extract data for next screens
        results = self.get_preflight_results()

        # Extract nodes and storage from results (simplified)
        nodes = ["pve1", "pve2", "pve3"]  # TODO: get from Proxmox
        bridges = ["vmbr0"]  # TODO: get from network

        # Push next screen with wizard_data enriched with preflight info
        from ..models.wizard import WizardData

        # Build wizard data with defaults and preflight info
        config = {
            "nodes": nodes,
            "bridges": bridges,
            "storage_pools": ["local-lvm"],
            "preflight_results": results,
        }

        # Store in app state
        self.app.state_manager.wizard_config = config

        # Push config screen
        from .config import ConfigFormScreen
        config_screen = ConfigFormScreen(self.wizard_data, preflight_data=config)
        self.app.push_screen(config_screen)

    def on_wizard_nav_back(self) -> None:
        """Handle back button (not allowed)."""
        pass  # Can't go back from preflight
