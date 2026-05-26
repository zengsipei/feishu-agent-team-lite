import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AgentApp:
    agent_id: str
    agent_name: str
    app_id: str
    app_secret: str
    bot_open_id: str = ""
    mention_names: tuple[str, ...] = ()


class AgentAppRegistry:
    def __init__(self, path: Path):
        self.path = path
        self._apps: list[AgentApp] = []
        self.reload()

    def reload(self) -> None:
        if not self.path.exists():
            raise FileNotFoundError(f"Runtime config not found: {self.path}")
        data = json.loads(self.path.read_text(encoding="utf-8"))
        apps = []
        for item in data.get("apps", []):
            app = AgentApp(
                agent_id=item["agent_id"],
                agent_name=item["agent_name"],
                app_id=item["app_id"],
                app_secret=item.get("app_secret", ""),
                bot_open_id=str(item.get("bot_open_id") or item.get("bot_id") or "").strip(),
                mention_names=_mention_names(item),
            )
            if not app.app_secret:
                raise ValueError(f"Missing app_secret for agent {app.agent_id} / app {app.app_id}")
            apps.append(app)
        if not apps:
            raise ValueError(f"No apps found in runtime config: {self.path}")
        self._apps = apps

    def list_apps(self, *, enabled_app_ids: set[str], enabled_agent_ids: set[str]) -> list[AgentApp]:
        apps = self._apps
        if enabled_app_ids:
            apps = [app for app in apps if app.app_id in enabled_app_ids]
        if enabled_agent_ids:
            apps = [app for app in apps if app.agent_id in enabled_agent_ids]
        return apps

    def get_app(self, agent_id: str) -> AgentApp | None:
        for app in self._apps:
            if app.agent_id == agent_id:
                return app
        return None


def _mention_names(item: dict) -> tuple[str, ...]:
    names: list[str] = []
    raw_names = item.get("mention_names", [])
    if isinstance(raw_names, str):
        raw_names = [raw_names]
    for value in [item.get("agent_name"), *list(raw_names or [])]:
        if not isinstance(value, str):
            continue
        name = value.strip()
        if name and name not in names:
            names.append(name)
    return tuple(names)
