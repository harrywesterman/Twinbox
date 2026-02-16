"""
Configuration management for Twinbox TUI.

Uses pydantic-settings for environment-based configuration with sensible defaults.
"""

from pathlib import Path
from typing import Optional

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class TUIConfig(BaseSettings):
    """Application configuration with environment variable overrides."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # Database
    database_path: Path = Field(
        default=Path.home() / ".local" / "share" / "twinbox" / "tui-state.db",
        description="Path to SQLite state database",
    )

    # Logging
    log_dir: Path = Field(
        default=Path.home() / ".local" / "share" / "twinbox" / "logs",
        description="Directory for deployment logs",
    )
    log_level: str = Field(default="INFO", description="Logging level")

    # SSH
    ssh_timeout: int = Field(default=30, description="SSH connection timeout in seconds")
    ssh_port: int = Field(default=22, description="SSH port")
    ssh_user: str = Field(default="twinbox", description="Default SSH username")
    ssh_max_retries: int = Field(default=3, description="Max SSH retry attempts")

    # Deployment
    default_cores: int = Field(default=2, ge=1, le=16, description="Default VM CPU cores")
    default_ram_mb: int = Field(default=4096, ge=512, le=131072, description="Default VM RAM in MB")
    default_disk_gb: int = Field(default=32, ge=8, le=1024, description="Default VM disk size in GB")
    default_bridge: str = Field(default="vmbr0", description="Default network bridge")
    default_storage: str = Field(default="local-lvm", description="Default storage pool")

    # wizard defaults
    wizard_default_cp_count: int = Field(default=3, description="Default control plane count")
    wizard_default_worker_count: int = Field(default=0, description="Default worker count")

    # Proxmox
    proxmox_verify_ssl: bool = Field(default=False, description="Verify Proxmox SSL certificates")
    proxmox_timeout: int = Field(default=30, description="Proxmox API timeout in seconds")

    @field_validator("database_path", "log_dir", mode="before")
    @classmethod
    def ensure_directories(cls, v: Path) -> Path:
        """Ensure parent directories exist for paths."""
        if isinstance(v, Path):
            v.parent.mkdir(parents=True, exist_ok=True)
        return v

    @field_validator("log_level")
    @classmethod
    def validate_log_level(cls, v: str) -> str:
        """Validate log level is one of the standard levels."""
        allowed = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
        normalized = v.upper()
        if normalized not in allowed:
            raise ValueError(f"log_level must be one of {allowed}, got {v}")
        return normalized


def get_config() -> TUIConfig:
    """
    Get application configuration.

    Creates necessary directories on first access.
    """
    config = TUIConfig()
    # Ensure directories exist
    config.database_path.parent.mkdir(parents=True, exist_ok=True)
    config.log_dir.mkdir(parents=True, exist_ok=True)
    return config
