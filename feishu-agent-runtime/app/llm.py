import asyncio
import json
import logging
from typing import Protocol

import httpx

from .agents import AgentConfig

logger = logging.getLogger(__name__)


def build_completion_user_message(*, user_text: str, metadata: dict) -> str:
    metadata_json = json.dumps(metadata, ensure_ascii=False, default=str)
    available_agent_ids = metadata.get("available_agent_ids", [])
    available_agent_ids_json = json.dumps(available_agent_ids, ensure_ascii=False, default=str)
    return (
        f"Project context metadata: {metadata_json}\n\n"
        "Operating contract:\n"
        "- Feishu is the business system of record. Treat Feishu chats, Docs, Base records, tasks, approvals, "
        "and workflows as the source of project facts.\n"
        "- Prefer Feishu-native orchestration: Docs for durable memory/specs, Base for work items/rosters, "
        "Task for todos, and Approval/Workflow for gated processes.\n"
        "- This runtime is stateless orchestration for replies and handoffs. Do not invent local project state, "
        "hidden files, or private execution results.\n"
        "- Feishu Agents do not have repository, filesystem, PowerShell, shell, Docker, GitHub, or server access "
        "unless the current message explicitly provides completed operator evidence from those tools.\n"
        "- If work is blocked by missing execution access, missing Feishu-owned context, or missing user approval, "
        'say "状态：Blocked" in reply_text, set handoff to null, and ask the human/Codex operator for the specific '
        "external action or Feishu context needed.\n"
        "- Do not hand off back to the sender or to another Agent just to solve the same missing access/context "
        "blocker. If the blocker already appears in recent context, stop the chain with handoff null.\n"
        "- Every handoff.text must be self-contained: include task id, objective, Feishu context reference if present, "
        "known facts, blocker state, and the exact next output expected. Do not rely on the next Agent seeing prior @ messages.\n\n"
        "Runtime response contract, required:\n"
        "- Return only one valid JSON object. Do not wrap it in Markdown fences. Do not add prose outside JSON.\n"
        '- Schema: {"reply_text":"...","handoff":null} or '
        '{"reply_text":"...","handoff":{"to_agent_id":"architect","text":"..."}}.\n'
        "- reply_text is the current agent's visible reply.\n"
        "- handoff.to_agent_id must be one of metadata.available_agent_ids only.\n"
        "- handoff.text is the task payload for the next agent. Do not include Feishu <at> tags, @Agent trigger text, "
        "open_id, app_id, or bot_id. The channel adapter will send the real rich-text @.\n"
        "- If no next agent should continue, set handoff to null.\n"
        f"- Available handoff target agent ids: {available_agent_ids_json}\n\n"
        f"User message:\n{user_text}"
    )


class LLMClient(Protocol):
    async def complete(
        self,
        *,
        agent: AgentConfig,
        user_text: str,
        history: list[dict],
        metadata: dict,
    ) -> str:
        ...


class OpenAICompatibleClient:
    def __init__(
        self,
        *,
        api_key: str,
        base_url: str,
        model: str,
        timeout_seconds: float,
        max_retries: int,
        retry_backoff_seconds: float,
    ):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout_seconds = timeout_seconds
        self.max_retries = max(0, max_retries)
        self.retry_backoff_seconds = max(0.0, retry_backoff_seconds)

    async def complete(
        self,
        *,
        agent: AgentConfig,
        user_text: str,
        history: list[dict],
        metadata: dict,
    ) -> str:
        messages = [{"role": "system", "content": agent.system_prompt}]
        for item in history[:-1]:
            role = item["role"]
            if role not in {"user", "assistant"}:
                continue
            messages.append({"role": role, "content": item["content"]})
        messages.append(
            {
                "role": "user",
                "content": build_completion_user_message(user_text=user_text, metadata=metadata),
            }
        )

        request = {
            "model": self.model,
            "messages": messages,
            "temperature": 0.2,
        }
        last_exc: Exception | None = None
        for attempt in range(self.max_retries + 1):
            try:
                async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                    resp = await client.post(
                        f"{self.base_url}/chat/completions",
                        headers={
                            "Authorization": f"Bearer {self.api_key}",
                            "Content-Type": "application/json",
                        },
                        json=request,
                    )
                    resp.raise_for_status()
                    data = resp.json()
                    return data["choices"][0]["message"]["content"]
            except (httpx.TransportError, httpx.TimeoutException) as exc:
                last_exc = exc
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code not in {408, 409, 425, 429, 500, 502, 503, 504}:
                    raise
                last_exc = exc

            if attempt >= self.max_retries:
                break
            delay = self.retry_backoff_seconds * (2**attempt)
            logger.warning(
                "OpenAI-compatible request failed, retrying attempt=%s/%s error=%s",
                attempt + 1,
                self.max_retries,
                type(last_exc).__name__,
            )
            await asyncio.sleep(delay)

        if last_exc is not None:
            raise last_exc
        raise RuntimeError("OpenAI-compatible request failed")
