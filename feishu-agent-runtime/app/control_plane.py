import logging
import time
from dataclasses import dataclass
from typing import Any, Protocol

import httpx

from .agents import AgentConfig

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ControlPlanePrompt:
    text: str
    source: str
    version: str | None = None
    record_id: str | None = None


@dataclass(frozen=True)
class PromptProposal:
    title: str
    reason: str
    prompt_text: str


@dataclass(frozen=True)
class AgentRunRecord:
    run_id: str
    agent_id: str
    project_id: str | None
    event_type: str
    status: str
    reply_summary: str
    handoff_to: str | None = None
    prompt_source: str | None = None
    prompt_version: str | None = None


class FeishuControlPlaneError(RuntimeError):
    pass


class AgentControlPlane(Protocol):
    async def get_prompt(self, agent: AgentConfig) -> ControlPlanePrompt | None:
        ...

    async def record_run(self, run: AgentRunRecord) -> None:
        ...

    async def propose_prompt(self, *, agent: AgentConfig, proposal: PromptProposal, run_id: str | None) -> None:
        ...

    async def close(self) -> None:
        ...


class NullControlPlane:
    async def get_prompt(self, agent: AgentConfig) -> ControlPlanePrompt | None:
        return None

    async def record_run(self, run: AgentRunRecord) -> None:
        return None

    async def propose_prompt(self, *, agent: AgentConfig, proposal: PromptProposal, run_id: str | None) -> None:
        return None

    async def close(self) -> None:
        return None


class FeishuBaseControlPlane:
    def __init__(
        self,
        *,
        base_url: str,
        app_id: str,
        app_secret: str,
        base_token: str,
        agents_table_id: str,
        prompt_versions_table_id: str,
        agent_runs_table_id: str,
        timeout_seconds: float,
    ):
        self.base_url = base_url.rstrip("/")
        self.app_id = app_id
        self.app_secret = app_secret
        self.base_token = base_token
        self.agents_table_id = agents_table_id
        self.prompt_versions_table_id = prompt_versions_table_id
        self.agent_runs_table_id = agent_runs_table_id
        self.client = httpx.AsyncClient(timeout=timeout_seconds)
        self._tenant_token: str | None = None
        self._tenant_token_expires_at = 0.0

    @property
    def enabled(self) -> bool:
        return all(
            [
                self.app_id,
                self.app_secret,
                self.base_token,
                self.agents_table_id,
                self.prompt_versions_table_id,
                self.agent_runs_table_id,
            ]
        )

    async def get_prompt(self, agent: AgentConfig) -> ControlPlanePrompt | None:
        if not self.enabled:
            return None
        try:
            records = await self._list_records(self.agents_table_id)
        except Exception:
            logger.exception("Failed to read Feishu Control Plane prompt agent_id=%s", agent.agent_id)
            return None

        for record in records:
            fields = _fields(record)
            if _text(fields.get("Agent ID")).strip() != agent.agent_id:
                continue
            if _text(fields.get("Status")).strip().casefold() not in {"active", "enabled"}:
                continue
            prompt = _text(fields.get("Current Prompt")).strip()
            if not prompt:
                return None
            return ControlPlanePrompt(
                text=prompt,
                source="feishu_base",
                version=_text(fields.get("Current Prompt Version")).strip() or None,
                record_id=str(record.get("record_id") or "") or None,
            )
        return None

    async def record_run(self, run: AgentRunRecord) -> None:
        if not self.enabled:
            return
        fields = {
            "Run ID": run.run_id,
            "Agent ID": run.agent_id,
            "Project ID": run.project_id or "",
            "Event Type": run.event_type,
            "Status": run.status,
            "Handoff To": run.handoff_to or "",
            "Reply Summary": _clip(run.reply_summary, 1000),
            "Prompt Source": run.prompt_source or "",
            "Prompt Version": run.prompt_version or "",
        }
        try:
            await self._create_record(self.agent_runs_table_id, fields)
        except Exception:
            logger.exception("Failed to write Feishu Control Plane run agent_id=%s run_id=%s", run.agent_id, run.run_id)

    async def propose_prompt(self, *, agent: AgentConfig, proposal: PromptProposal, run_id: str | None) -> None:
        if not self.enabled:
            return
        fields = {
            "Agent ID": agent.agent_id,
            "Title": proposal.title or f"{agent.agent_id} prompt proposal",
            "Status": "Proposed",
            "Prompt Text": proposal.prompt_text,
            "Change Reason": proposal.reason,
            "Source Run ID": run_id or "",
        }
        try:
            await self._create_record(self.prompt_versions_table_id, fields)
        except Exception:
            logger.exception("Failed to write Feishu prompt proposal agent_id=%s run_id=%s", agent.agent_id, run_id)

    async def close(self) -> None:
        await self.client.aclose()

    async def _tenant_access_token(self) -> str:
        now = time.time()
        if self._tenant_token and now < self._tenant_token_expires_at - 300:
            return self._tenant_token

        payload = {"app_id": self.app_id, "app_secret": self.app_secret}
        response = await self.client.post(
            f"{self.base_url}/open-apis/auth/v3/tenant_access_token/internal",
            json=payload,
            headers={"Content-Type": "application/json; charset=utf-8"},
        )
        data = self._response_json(response)
        if response.status_code >= 400:
            raise FeishuControlPlaneError(
                "Feishu tenant token request failed "
                f"http_status={response.status_code} code={data.get('code')} msg={self._safe_message(data.get('msg'))}"
            )
        if data.get("code") != 0:
            raise FeishuControlPlaneError(
                f"Feishu tenant token request failed code={data.get('code')} msg={self._safe_message(data.get('msg'))}"
            )
        token = str(data.get("tenant_access_token") or "")
        if not token:
            raise FeishuControlPlaneError("Feishu tenant token response did not include tenant_access_token")
        self._tenant_token = token
        self._tenant_token_expires_at = now + int(data.get("expire") or 7200)
        return token

    async def _request(self, method: str, path: str, *, json_body: dict | None = None, params: dict | None = None) -> dict:
        token = await self._tenant_access_token()
        response = await self.client.request(
            method,
            f"{self.base_url}{path}",
            params=params,
            json=json_body,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json; charset=utf-8",
            },
        )
        data = self._response_json(response)
        if response.status_code >= 400:
            raise FeishuControlPlaneError(
                "Feishu request failed "
                f"http_status={response.status_code} code={data.get('code')} msg={self._safe_message(data.get('msg'))}"
            )
        if data.get("code") != 0:
            raise FeishuControlPlaneError(
                f"Feishu request failed code={data.get('code')} msg={self._safe_message(data.get('msg'))}"
            )
        return data

    def _response_json(self, response: httpx.Response) -> dict[str, Any]:
        try:
            data = response.json()
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    def _safe_message(self, value: Any) -> str:
        text = _clip(_text(value), 300)
        for secret in (
            self.app_id,
            self.app_secret,
            self.base_token,
            self.agents_table_id,
            self.prompt_versions_table_id,
            self.agent_runs_table_id,
            self._tenant_token or "",
        ):
            if secret:
                text = text.replace(secret, "<redacted>")
        return text

    async def _list_records(self, table_id: str) -> list[dict[str, Any]]:
        data = await self._request(
            "GET",
            f"/open-apis/base/v3/bases/{self.base_token}/tables/{table_id}/records",
            params={"limit": 500, "offset": 0},
        )
        response_data = data.get("data", {})
        if not isinstance(response_data, dict):
            return []

        items = response_data.get("items")
        if items is None:
            items = response_data.get("records")
        if items is None:
            items = _records_from_matrix(
                fields=response_data.get("fields"),
                rows=response_data.get("data"),
                record_ids=response_data.get("record_id_list"),
            )
        if items is None or not isinstance(items, list):
            return []
        return [item for item in items if isinstance(item, dict)]

    async def _create_record(self, table_id: str, fields: dict[str, Any]) -> dict:
        return await self._request(
            "POST",
            f"/open-apis/base/v3/bases/{self.base_token}/tables/{table_id}/records",
            json_body=fields,
        )


def _fields(record: dict[str, Any]) -> dict[str, Any]:
    fields = record.get("fields", {})
    return fields if isinstance(fields, dict) else {}


def _records_from_matrix(*, fields: Any, rows: Any, record_ids: Any) -> list[dict[str, Any]] | None:
    if not isinstance(fields, list) or not isinstance(rows, list):
        return None

    names = [_text(field).strip() for field in fields]
    if not names:
        return []

    records: list[dict[str, Any]] = []
    record_id_list = record_ids if isinstance(record_ids, list) else []
    for index, row in enumerate(rows):
        if not isinstance(row, list):
            continue
        mapped = {
            name: row[column_index]
            for column_index, name in enumerate(names)
            if name and column_index < len(row)
        }
        record: dict[str, Any] = {"fields": mapped}
        if index < len(record_id_list) and record_id_list[index]:
            record["record_id"] = record_id_list[index]
        records.append(record)
    return records


def _text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        return "".join(_text(item) for item in value)
    if isinstance(value, dict):
        if "text" in value:
            return _text(value.get("text"))
        if "name" in value:
            return _text(value.get("name"))
        if "value" in value:
            return _text(value.get("value"))
    return str(value)


def _clip(value: str, limit: int) -> str:
    text = value or ""
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."
