from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    service_name: str = "feishu-channel-adapter"
    environment: str = "production"
    log_level: str = "WARNING"

    runtime_base_url: str = "http://127.0.0.1:8080"
    runtime_auth_token: str | None = None
    runtime_timeout_seconds: float = 120.0

    agent_runtime_config_path: Path = Path("./config/agent-runtime-config.json")
    adapter_status_dir: Path = Path("../.local-run/adapter-status")

    channel_transport: Literal["ws"] = "ws"
    channel_connect_timeout_seconds: float = 30.0
    channel_require_mention: bool = True
    channel_respond_to_mention_all: bool = False
    channel_drop_self_sent: bool = True

    enabled_app_ids: str = ""
    enabled_agent_ids: str = ""
    worker_agent_id: str = ""

    comment_fetch_enabled: bool = False
    comment_reply_enabled: bool = False

    handoff_loop_guard_enabled: bool = True
    handoff_loop_guard_ttl_seconds: int = 600
    handoff_loop_guard_max_count: int = 1

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    @staticmethod
    def _csv_set(value: str) -> set[str]:
        return {item.strip() for item in value.split(",") if item.strip()}

    @property
    def enabled_app_id_set(self) -> set[str]:
        return self._csv_set(self.enabled_app_ids)

    @property
    def enabled_agent_id_set(self) -> set[str]:
        return self._csv_set(self.enabled_agent_ids)

    @property
    def resolved_runtime_url(self) -> str:
        return self.runtime_base_url.rstrip("/")


@lru_cache
def get_settings() -> Settings:
    return Settings()
