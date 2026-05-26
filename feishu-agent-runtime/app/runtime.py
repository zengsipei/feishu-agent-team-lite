import logging

from .agents import AgentConfig, AgentRegistry
from .llm import LLMClient
from .models import CardAction, ChannelComment, ChannelMessage, RuntimeReply
from .store import RuntimeStore

logger = logging.getLogger(__name__)


class AgentRuntime:
    def __init__(self, *, registry: AgentRegistry, store: RuntimeStore, llm: LLMClient, max_context_messages: int):
        self.registry = registry
        self.store = store
        self.llm = llm
        self.max_context_messages = max_context_messages

    def _resolve_agent(self, agent_id: str | None, app_id: str | None) -> AgentConfig | None:
        return self.registry.get(agent_id=agent_id, app_id=app_id)

    async def _handle_text_event(self, msg: ChannelMessage, *, event_type: str) -> RuntimeReply:
        agent = self._resolve_agent(msg.agent_id, msg.app_id)
        if agent is None:
            return RuntimeReply(
                status="error",
                reply_text="Unknown agent. Provide a known app_id or agent_id.",
                metadata={"app_id": msg.app_id, "agent_id": msg.agent_id},
            )

        project_id = msg.project_id or msg.chat_id
        is_new_event = self.store.record_event(
            event_id=msg.event_id or msg.message_id,
            event_type=event_type,
            project_id=project_id,
            chat_id=msg.chat_id,
            agent_id=agent.agent_id,
            payload=msg.model_dump(),
        )
        if not is_new_event:
            return RuntimeReply(
                status="ignored",
                agent_id=agent.agent_id,
                agent_name=agent.agent_name,
                reply_text="Duplicate event ignored.",
            )

        session_id = self.store.session_id_for(
            project_id=project_id,
            chat_id=msg.chat_id,
            thread_id=msg.thread_id,
            sender_id=msg.sender_id,
            agent_id=agent.agent_id,
        )
        self.store.upsert_session(
            session_id=session_id,
            project_id=project_id,
            chat_id=msg.chat_id,
            thread_id=msg.thread_id,
            sender_id=msg.sender_id,
            agent_id=agent.agent_id,
            metadata={"chat_type": msg.chat_type},
        )
        self.store.add_message(
            session_id=session_id,
            role="user",
            content=msg.text,
            source_id=msg.message_id,
            metadata={"sender_id": msg.sender_id, "sender_name": msg.sender_name},
        )
        history = self.store.recent_messages(session_id, self.max_context_messages)
        try:
            reply_text = await self.llm.complete(
                agent=agent,
                user_text=msg.text,
                history=history,
                metadata={
                    "project_id": project_id,
                    "chat_id": msg.chat_id,
                    "thread_id": msg.thread_id,
                    "sender_id": msg.sender_id,
                    "reply_mode": msg.reply_mode,
                },
            )
        except Exception as exc:
            logger.exception("LLM completion failed agent_id=%s message_id=%s", agent.agent_id, msg.message_id)
            return RuntimeReply(
                status="error",
                agent_id=agent.agent_id,
                agent_name=agent.agent_name,
                session_id=session_id,
                reply_text="模型服务暂时不可用，请稍后重试。",
                metadata={"project_id": project_id, "error": type(exc).__name__},
            )
        response_id = str(
            self.store.add_message(
                session_id=session_id,
                role="assistant",
                content=reply_text,
                source_type="runtime",
                metadata={"agent_id": agent.agent_id},
            )
        )
        return RuntimeReply(
            status="ok",
            agent_id=agent.agent_id,
            agent_name=agent.agent_name,
            session_id=session_id,
            response_id=response_id,
            reply_text=reply_text,
            metadata={"project_id": project_id},
        )

    async def handle_message(self, msg: ChannelMessage) -> RuntimeReply:
        return await self._handle_text_event(msg, event_type="message")

    async def handle_comment(self, comment: ChannelComment) -> RuntimeReply:
        agent = self._resolve_agent(comment.agent_id, comment.app_id)
        if agent is None:
            return RuntimeReply(status="error", reply_text="Unknown agent.")

        project_id = comment.project_id or comment.file_token or "comment"
        chat_id = comment.file_token or "comment"
        msg = ChannelMessage(
            event_id=comment.event_id,
            message_id=comment.comment_id,
            app_id=comment.app_id,
            agent_id=comment.agent_id,
            chat_id=chat_id,
            thread_id=comment.comment_id,
            sender_id=comment.sender_id,
            text=comment.text,
            project_id=project_id,
            raw=comment.raw,
        )
        return await self._handle_text_event(msg, event_type="comment")

    async def handle_card_action(self, action: CardAction) -> RuntimeReply:
        agent = self._resolve_agent(action.agent_id, action.app_id)
        if agent is None:
            return RuntimeReply(status="error", reply_text="Unknown agent.")

        self.store.record_event(
            event_id=action.event_id,
            event_type="card_action",
            project_id=action.chat_id,
            chat_id=action.chat_id,
            agent_id=agent.agent_id,
            payload=action.model_dump(),
        )
        return RuntimeReply(
            status="ok",
            agent_id=agent.agent_id,
            agent_name=agent.agent_name,
            reply_text="Card action recorded.",
            metadata={"action": action.action},
        )
