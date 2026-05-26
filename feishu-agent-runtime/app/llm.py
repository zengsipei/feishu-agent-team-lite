import asyncio
import logging
from typing import Protocol

import httpx

from .agents import AgentConfig

logger = logging.getLogger(__name__)


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
                "content": (
                    f"Project context metadata: {metadata}\n\n"
                    "Response format: normally return plain text. If another agent should continue, "
                    "return only strict JSON like "
                    '{"reply_text":"...","handoff":{"to_agent_id":"architect","text":"..."}}. '
                    "The handoff field may be null. Use only metadata.available_agent_ids for to_agent_id.\n\n"
                    f"User message:\n{user_text}"
                ),
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
