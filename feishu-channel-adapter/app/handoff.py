import json
import re
from dataclasses import dataclass
from typing import Any

from lark_oapi.channel import FeishuChannel
from lark_oapi.channel.types import OutboundPost, SendResult
from lark_oapi.core.enum import AccessTokenType, HttpMethod
from lark_oapi.core.model import BaseRequest

from .registry import AgentApp, AgentAppRegistry


class HandoffError(RuntimeError):
    pass


@dataclass(frozen=True)
class BotRosterMember:
    bot_id: str
    bot_name: str


@dataclass(frozen=True)
class ResolvedHandoffTarget:
    agent: AgentApp
    bot_id: str
    bot_name: str


class BotRosterClient:
    def __init__(self, client: Any):
        self.client = client

    async def list_bot_members(self, chat_id: str) -> list[BotRosterMember]:
        request = BaseRequest()
        request.http_method = HttpMethod.GET
        request.uri = "/open-apis/im/v1/chats/:chat_id/members/bots"
        request.paths["chat_id"] = chat_id
        request.token_types = {AccessTokenType.TENANT}

        response = await self.client.arequest(request)
        payload = _response_payload(response)
        if payload.get("code", 0) != 0:
            raise HandoffError(
                f"Failed to list chat bot members: code={payload.get('code')} msg={payload.get('msg', '')}"
            )

        items = payload.get("data", {}).get("items", [])
        if not isinstance(items, list):
            raise HandoffError("Unexpected chat bot member response shape")

        members: list[BotRosterMember] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            bot_id = str(item.get("bot_id") or "").strip()
            bot_name = str(item.get("bot_name") or "").strip()
            if bot_id and bot_name:
                members.append(BotRosterMember(bot_id=bot_id, bot_name=bot_name))
        return members


class GroupBotRosterResolver:
    def __init__(self, *, registry: AgentAppRegistry, roster_client: BotRosterClient):
        self.registry = registry
        self.roster_client = roster_client

    async def resolve(self, *, chat_id: str, to_agent_id: str, from_agent_id: str | None = None) -> ResolvedHandoffTarget:
        if from_agent_id and from_agent_id == to_agent_id:
            raise HandoffError("Refusing self-handoff")

        target_app = self.registry.get_app(to_agent_id)
        if target_app is None:
            raise HandoffError(f"Unknown handoff target agent: {to_agent_id}")

        names = {_normalize_name(name) for name in target_app.mention_names}
        names.discard("")
        if not names:
            raise HandoffError(f"No mention names configured for target agent: {to_agent_id}")

        members = await self.roster_client.list_bot_members(chat_id)
        for member in members:
            if _normalize_name(member.bot_name) in names:
                return ResolvedHandoffTarget(
                    agent=target_app,
                    bot_id=member.bot_id,
                    bot_name=member.bot_name,
                )

        raise HandoffError(f"Target agent bot is not present in the chat: {to_agent_id}")


class HandoffSender:
    def __init__(self, *, registry: AgentAppRegistry, roster_client: BotRosterClient):
        self.resolver = GroupBotRosterResolver(registry=registry, roster_client=roster_client)

    async def send(
        self,
        *,
        channel: FeishuChannel,
        chat_id: str,
        from_agent_id: str,
        to_agent_id: str,
        text: str,
        title: str = "",
    ) -> tuple[SendResult, ResolvedHandoffTarget]:
        target = await self.resolver.resolve(
            chat_id=chat_id,
            from_agent_id=from_agent_id,
            to_agent_id=to_agent_id,
        )
        result = await self.send_resolved(
            channel=channel,
            chat_id=chat_id,
            target=target,
            text=text,
            title=title,
        )
        return result, target

    async def send_resolved(
        self,
        *,
        channel: FeishuChannel,
        chat_id: str,
        target: ResolvedHandoffTarget,
        text: str,
        title: str = "",
    ) -> SendResult:
        body = text.strip()
        if not body:
            raise HandoffError("Handoff text is empty")

        result = await channel.send(chat_id, OutboundPost(post=_build_post(target, body, title=title)))
        return result

    async def send_to_known_bot(
        self,
        *,
        channel: FeishuChannel,
        chat_id: str,
        to_agent_id: str,
        bot_id: str,
        bot_name: str,
        text: str,
        title: str = "",
    ) -> tuple[SendResult, ResolvedHandoffTarget]:
        target_app = self.resolver.registry.get_app(to_agent_id)
        if target_app is None:
            raise HandoffError(f"Unknown handoff target agent: {to_agent_id}")
        target = ResolvedHandoffTarget(
            agent=target_app,
            bot_id=bot_id,
            bot_name=bot_name,
        )
        result = await self.send_resolved(
            channel=channel,
            chat_id=chat_id,
            target=target,
            text=text,
            title=title,
        )
        return result, target


def _build_post(target: ResolvedHandoffTarget, text: str, *, title: str = "") -> dict[str, Any]:
    return {
        "zh_cn": {
            "title": title,
            "content": [
                [
                    {
                        "tag": "at",
                        "user_id": target.bot_id,
                        "user_name": target.bot_name,
                    },
                    {
                        "tag": "text",
                        "text": f" {text}",
                    },
                ]
            ],
        }
    }


def _response_payload(response: Any) -> dict[str, Any]:
    raw = getattr(response, "raw", None)
    content = getattr(raw, "content", None)
    if isinstance(content, bytes):
        try:
            payload = json.loads(content.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise HandoffError("Invalid JSON response from Feishu") from exc
        if isinstance(payload, dict):
            return payload

    code = getattr(response, "code", None)
    msg = getattr(response, "msg", "") or ""
    return {"code": code, "msg": msg}


def _normalize_name(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip()).casefold()
