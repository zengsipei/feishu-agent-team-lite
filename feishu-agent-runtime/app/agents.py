import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AgentConfig:
    agent_id: str
    agent_name: str
    app_id: str
    app_secret: str
    source_memory_file: str
    resolved_prompt_file: str | None
    system_prompt: str


class AgentRegistry:
    def __init__(self, runtime_config_path: Path):
        self.runtime_config_path = runtime_config_path
        self._by_agent_id: dict[str, AgentConfig] = {}
        self._by_app_id: dict[str, AgentConfig] = {}
        self.reload()

    def reload(self) -> None:
        if not self.runtime_config_path.exists():
            raise FileNotFoundError(f"Runtime config not found: {self.runtime_config_path}")

        data = json.loads(self.runtime_config_path.read_text(encoding="utf-8"))
        by_agent_id: dict[str, AgentConfig] = {}
        by_app_id: dict[str, AgentConfig] = {}

        for item in data.get("apps", []):
            config = AgentConfig(
                agent_id=item["agent_id"],
                agent_name=item["agent_name"],
                app_id=item["app_id"],
                app_secret=item.get("app_secret", ""),
                source_memory_file=item.get("source_memory_file", ""),
                resolved_prompt_file=item.get("resolved_prompt_file"),
                system_prompt=item.get("system_prompt", ""),
            )
            by_agent_id[config.agent_id] = config
            by_app_id[config.app_id] = config

        self._by_agent_id = by_agent_id
        self._by_app_id = by_app_id

    def list_agents(self) -> list[AgentConfig]:
        return list(self._by_agent_id.values())

    def get(self, agent_id: str | None = None, app_id: str | None = None) -> AgentConfig | None:
        if agent_id:
            return self._by_agent_id.get(agent_id)
        if app_id:
            return self._by_app_id.get(app_id)
        return None
