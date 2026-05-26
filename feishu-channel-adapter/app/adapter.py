import asyncio
import logging
from typing import Any

from lark_oapi.channel import (
    Events,
    FeishuChannel,
    InboundConfig,
    PolicyConfig,
    TransportConfig,
)
from lark_oapi.core.enum import LogLevel

from .comment_drive import DriveCommentClient
from .config import Settings
from .registry import AgentApp
from .runtime_client import RuntimeClient
from .serialization import attr, nested_attr, to_jsonable

logger = logging.getLogger(__name__)


class ChannelAdapter:
    def __init__(self, *, settings: Settings, apps: list[AgentApp]):
        self.settings = settings
        self.apps = apps
        self.runtime = RuntimeClient(
            base_url=settings.resolved_runtime_url,
            auth_token=settings.runtime_auth_token,
            timeout_seconds=settings.runtime_timeout_seconds,
        )
        self.channels: list[FeishuChannel] = []
        self.comment_clients: dict[str, DriveCommentClient] = {}
        self._stop_event = asyncio.Event()
        self._stopped = False

    async def start(self) -> None:
        if not self.apps:
            raise RuntimeError("No apps enabled for channel adapter")
        if len(self.apps) != 1:
            raise RuntimeError("ChannelAdapter must run exactly one app per worker process")

        for app in self.apps:
            channel = self._build_channel(app)
            self._register_handlers(channel, app)
            self.channels.append(channel)
            if self.settings.comment_fetch_enabled:
                self.comment_clients[app.app_id] = DriveCommentClient(app)

        logger.info("Starting %d Feishu Channel SDK connection(s)", len(self.channels))
        await asyncio.gather(
            *[
                channel.start_background(timeout=self.settings.channel_connect_timeout_seconds)
                for channel in self.channels
            ]
        )
        logger.info("Feishu Channel adapter started")

    async def run_forever(self) -> None:
        await self.start()
        await self._stop_event.wait()

    async def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True
        logger.info("Stopping Feishu Channel adapter")
        for channel in self.channels:
            try:
                await channel.disconnect()
            except Exception:
                logger.exception("Failed to disconnect a Feishu channel")
        await self.runtime.close()
        self._stop_event.set()

    def _build_channel(self, app: AgentApp) -> FeishuChannel:
        return FeishuChannel(
            app_id=app.app_id,
            app_secret=app.app_secret,
            log_level=to_lark_log_level(self.settings.log_level),
            transport=TransportConfig(kind=self.settings.channel_transport),
            policy=PolicyConfig(
                require_mention=self.settings.channel_require_mention,
                respond_to_mention_all=self.settings.channel_respond_to_mention_all,
            ),
            inbound=InboundConfig(drop_self_sent=self.settings.channel_drop_self_sent),
        )

    def _register_handlers(self, channel: FeishuChannel, app: AgentApp) -> None:
        async def on_message(message: Any) -> None:
            await self._handle_message(channel, app, message)

        async def on_comment(comment: Any) -> None:
            await self._handle_comment(app, comment)

        async def on_card_action(action: Any) -> None:
            await self._handle_card_action(app, action)

        async def on_reject(event: Any) -> None:
            logger.info(
                "Channel rejected event app_id=%s agent_id=%s payload=%s",
                app.app_id,
                app.agent_id,
                to_jsonable(event),
            )

        async def on_error(error: Any) -> None:
            logger.error(
                "Channel error app_id=%s agent_id=%s error=%s",
                app.app_id,
                app.agent_id,
                error,
            )

        channel.on(Events.MESSAGE, on_message)
        channel.on(Events.COMMENT, on_comment)
        channel.on(Events.CARD_ACTION, on_card_action)
        channel.on(Events.REJECT, on_reject)
        channel.on(Events.ERROR, on_error)

    async def _handle_message(self, channel: FeishuChannel, app: AgentApp, message: Any) -> None:
        payload = normalize_message(app, message)
        logger.info(
            "Forwarding message app_id=%s agent_id=%s chat_id=%s message_id=%s",
            app.app_id,
            app.agent_id,
            payload.get("chat_id"),
            payload.get("message_id"),
        )
        reply = await self.runtime.post_message(payload)
        await self._send_message_reply(channel, message, reply)

    async def _send_message_reply(self, channel: FeishuChannel, message: Any, reply: dict[str, Any]) -> None:
        status = reply.get("status")
        reply_text = (reply.get("reply_text") or "").strip()
        if status == "ignored" or not reply_text:
            return
        if status != "ok":
            logger.warning("Runtime returned status=%s reply=%s", status, reply)
        chat_id = attr(message, "chat_id") or nested_attr(message, "conversation", "chat_id")
        if not chat_id:
            logger.warning("Cannot reply because message has no chat_id: %s", to_jsonable(message))
            return
        message_id = attr(message, "message_id") or attr(message, "id")
        opts = {"reply_to": message_id} if message_id else None
        result = await channel.send(chat_id, {"markdown": reply_text}, opts)
        if not getattr(result, "success", False):
            logger.warning("Channel send failed result=%s", to_jsonable(result))

    async def _handle_comment(self, app: AgentApp, comment: Any) -> None:
        payload = await self._normalize_comment(app, comment)
        logger.info(
            "Forwarding comment app_id=%s agent_id=%s file_token=%s comment_id=%s",
            app.app_id,
            app.agent_id,
            payload.get("file_token"),
            payload.get("comment_id"),
        )
        reply = await self.runtime.post_comment(payload)
        if self.settings.comment_reply_enabled and reply.get("status") == "ok":
            logger.warning("COMMENT_REPLY_ENABLED is set, but comment reply write-back is not implemented yet")

    async def _normalize_comment(self, app: AgentApp, comment: Any) -> dict[str, Any]:
        payload = normalize_comment(app, comment)
        if not self.settings.comment_fetch_enabled:
            return payload
        client = self.comment_clients.get(app.app_id)
        if client is None:
            return payload
        try:
            text = await client.get_comment_text(
                file_token=payload["file_token"],
                file_type=payload["file_type"] or "docx",
                comment_id=payload["comment_id"],
            )
        except Exception:
            logger.exception(
                "Failed to enrich comment app_id=%s file_token=%s comment_id=%s",
                app.app_id,
                payload.get("file_token"),
                payload.get("comment_id"),
            )
            return payload
        if text:
            payload["text"] = text
        return payload

    async def _handle_card_action(self, app: AgentApp, action: Any) -> None:
        payload = normalize_card_action(app, action)
        logger.info(
            "Forwarding card action app_id=%s agent_id=%s chat_id=%s",
            app.app_id,
            app.agent_id,
            payload.get("chat_id"),
        )
        reply = await self.runtime.post_card_action(payload)
        if reply.get("status") == "error":
            logger.warning("Runtime card action error reply=%s", reply)


def normalize_message(app: AgentApp, message: Any) -> dict[str, Any]:
    message_id = attr(message, "message_id") or attr(message, "id")
    chat_id = attr(message, "chat_id") or nested_attr(message, "conversation", "chat_id")
    thread_id = attr(message, "reply_to_message_id") or nested_attr(message, "conversation", "thread_id") or message_id
    mentions = []
    for mention in attr(message, "mentions", []) or []:
        mentions.append(
            {
                "id": attr(mention, "open_id") or attr(mention, "user_id"),
                "name": attr(mention, "name"),
                "app_id": app.app_id if attr(mention, "is_bot", False) else None,
            }
        )

    return {
        "event_id": f"{app.app_id}:message:{message_id}",
        "message_id": message_id,
        "app_id": app.app_id,
        "agent_id": app.agent_id,
        "chat_id": chat_id,
        "chat_type": attr(message, "chat_type") or nested_attr(message, "conversation", "chat_type"),
        "thread_id": thread_id,
        "sender_id": attr(message, "sender_id") or nested_attr(message, "sender", "open_id"),
        "sender_name": attr(message, "sender_name") or nested_attr(message, "sender", "display_name"),
        "text": attr(message, "content_text", "") or "",
        "message_type": attr(message, "raw_content_type") or nested_attr(message, "content", "kind"),
        "mentions": mentions,
        "timestamp_ms": attr(message, "create_time"),
        "project_id": chat_id,
        "raw": to_jsonable(attr(message, "raw", {})),
    }


def normalize_comment(app: AgentApp, comment: Any) -> dict[str, Any]:
    file_token = attr(comment, "file_token")
    comment_id = attr(comment, "comment_id")
    operator = attr(comment, "operator")
    timestamp = attr(comment, "timestamp")
    return {
        "event_id": f"{app.app_id}:comment:{file_token}:{comment_id}",
        "comment_id": comment_id,
        "app_id": app.app_id,
        "agent_id": app.agent_id,
        "file_token": file_token,
        "file_type": attr(comment, "file_type"),
        "sender_id": attr(operator, "open_id"),
        "text": "",
        "project_id": file_token,
        "raw": {
            "timestamp": timestamp,
            "mentioned_bot": attr(comment, "mentioned_bot"),
            "reply_id": attr(comment, "reply_id"),
            "event": to_jsonable(attr(comment, "raw", {})),
        },
    }


def normalize_card_action(app: AgentApp, action: Any) -> dict[str, Any]:
    operator = attr(action, "operator")
    action_payload = attr(action, "action")
    chat_id = attr(action, "chat_id")
    message_id = attr(action, "message_id")
    user_id = attr(operator, "open_id")
    return {
        "event_id": f"{app.app_id}:card:{message_id}:{user_id}:{to_jsonable(action_payload)}",
        "app_id": app.app_id,
        "agent_id": app.agent_id,
        "chat_id": chat_id,
        "user_id": user_id,
        "action": to_jsonable(action_payload),
        "raw": to_jsonable(attr(action, "raw", {})),
    }


def to_lark_log_level(level: str) -> LogLevel:
    normalized = (level or "INFO").upper()
    return getattr(LogLevel, normalized, LogLevel.INFO)
