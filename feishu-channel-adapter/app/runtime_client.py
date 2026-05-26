from typing import Any

import httpx


class RuntimeClient:
    def __init__(self, *, base_url: str, auth_token: str | None, timeout_seconds: float):
        headers = {}
        if auth_token:
            headers["Authorization"] = f"Bearer {auth_token}"
        self._client = httpx.AsyncClient(base_url=base_url, headers=headers, timeout=timeout_seconds)

    async def close(self) -> None:
        await self._client.aclose()

    async def post_message(self, payload: dict[str, Any]) -> dict[str, Any]:
        response = await self._client.post("/v1/channel/messages", json=payload)
        response.raise_for_status()
        return response.json()

    async def post_comment(self, payload: dict[str, Any]) -> dict[str, Any]:
        response = await self._client.post("/v1/channel/comments", json=payload)
        response.raise_for_status()
        return response.json()

    async def post_card_action(self, payload: dict[str, Any]) -> dict[str, Any]:
        response = await self._client.post("/v1/channel/card-actions", json=payload)
        response.raise_for_status()
        return response.json()
