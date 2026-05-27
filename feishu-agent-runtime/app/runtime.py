import json
import logging
from dataclasses import replace
from typing import Any

from .agents import AgentConfig, AgentRegistry
from .control_plane import (
    AgentControlPlane,
    AgentRunRecord,
    ControlPlanePrompt,
    NullControlPlane,
    PromptProposal,
)
from .llm import LLMClient
from .models import CardAction, ChannelComment, ChannelMessage, RuntimeHandoff, RuntimeReply
from .store import RuntimeStore

logger = logging.getLogger(__name__)


class AgentRuntime:
    def __init__(
        self,
        *,
        registry: AgentRegistry,
        store: RuntimeStore,
        llm: LLMClient,
        max_context_messages: int,
        control_plane: AgentControlPlane | None = None,
    ):
        self.registry = registry
        self.store = store
        self.llm = llm
        self.max_context_messages = max_context_messages
        self.control_plane = control_plane or NullControlPlane()

    def _resolve_agent(self, agent_id: str | None, app_id: str | None) -> AgentConfig | None:
        return self.registry.get(agent_id=agent_id, app_id=app_id)

    async def close(self) -> None:
        await self.control_plane.close()

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
        available_agent_ids = [
            item.agent_id
            for item in self.registry.list_agents()
            if item.agent_id != agent.agent_id
        ]
        control_prompt = await self.control_plane.get_prompt(agent)
        prompt_source = "runtime_config"
        prompt_version = None
        effective_agent = agent
        if control_prompt is not None:
            effective_agent = replace(agent, system_prompt=control_prompt.text)
            prompt_source = control_prompt.source
            prompt_version = control_prompt.version
        try:
            raw_reply_text = await self.llm.complete(
                agent=effective_agent,
                user_text=msg.text,
                history=history,
                metadata={
                    "project_id": project_id,
                    "chat_id": msg.chat_id,
                    "thread_id": msg.thread_id,
                    "sender_id": msg.sender_id,
                    "reply_mode": msg.reply_mode,
                    "available_agent_ids": available_agent_ids,
                    "prompt_source": prompt_source,
                    "prompt_version": prompt_version,
                },
            )
        except Exception as exc:
            logger.exception("LLM completion failed agent_id=%s message_id=%s", agent.agent_id, msg.message_id)
            await self.control_plane.record_run(
                AgentRunRecord(
                    run_id=msg.message_id or msg.event_id or session_id,
                    agent_id=agent.agent_id,
                    project_id=project_id,
                    event_type=event_type,
                    status="error",
                    reply_summary=f"LLM completion failed: {type(exc).__name__}",
                    prompt_source=prompt_source,
                    prompt_version=prompt_version,
                )
            )
            return RuntimeReply(
                status="error",
                agent_id=agent.agent_id,
                agent_name=agent.agent_name,
                session_id=session_id,
                reply_text="模型服务暂时不可用，请稍后重试。",
                metadata={
                    "project_id": project_id,
                    "error": type(exc).__name__,
                    "prompt_source": prompt_source,
                    "prompt_version": prompt_version,
                    "prompt_proposal_created": False,
                },
            )
        reply_text, handoff, proposal, envelope_parsed = parse_reply_envelope_with_proposal(
            raw_reply_text,
            current_agent_id=agent.agent_id,
            available_agent_ids=set(available_agent_ids),
        )
        response_id = str(
            self.store.add_message(
                session_id=session_id,
                role="assistant",
                content=reply_text,
                source_type="runtime",
                metadata={
                    "agent_id": agent.agent_id,
                    "handoff": handoff.model_dump() if handoff else None,
                    "prompt_proposal": bool(proposal),
                    "envelope_parsed": envelope_parsed,
                    "prompt_source": prompt_source,
                    "prompt_version": prompt_version,
                },
            )
        )
        await self.control_plane.record_run(
            AgentRunRecord(
                run_id=response_id,
                agent_id=agent.agent_id,
                project_id=project_id,
                event_type=event_type,
                status="ok",
                handoff_to=handoff.to_agent_id if handoff else None,
                reply_summary=reply_text,
                prompt_source=prompt_source,
                prompt_version=prompt_version,
            )
        )
        if proposal is not None:
            await self.control_plane.propose_prompt(agent=agent, proposal=proposal, run_id=response_id)
        return RuntimeReply(
            status="ok",
            agent_id=agent.agent_id,
            agent_name=agent.agent_name,
            session_id=session_id,
            response_id=response_id,
            reply_text=reply_text,
            handoff_to=handoff.to_agent_id if handoff else None,
            handoff=handoff,
            metadata={
                "project_id": project_id,
                "prompt_source": prompt_source,
                "prompt_version": prompt_version,
                "prompt_proposal_created": proposal is not None,
            },
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


def parse_reply_envelope(
    raw_text: str,
    *,
    current_agent_id: str,
    available_agent_ids: set[str],
) -> tuple[str, RuntimeHandoff | None, bool]:
    reply_text, handoff, _proposal, parsed = parse_reply_envelope_with_proposal(
        raw_text,
        current_agent_id=current_agent_id,
        available_agent_ids=available_agent_ids,
    )
    return reply_text, handoff, parsed


def parse_reply_envelope_with_proposal(
    raw_text: str,
    *,
    current_agent_id: str,
    available_agent_ids: set[str],
) -> tuple[str, RuntimeHandoff | None, PromptProposal | None, bool]:
    text = (raw_text or "").strip()
    if not text:
        return "", None, None, False

    json_text = strip_json_code_fence(text)
    try:
        payload = json.loads(json_text)
    except json.JSONDecodeError:
        return text, None, None, False

    if not isinstance(payload, dict):
        return text, None, None, False

    reply_text = payload.get("reply_text")
    if not isinstance(reply_text, str):
        return text, None, None, False

    handoff = parse_handoff(
        payload.get("handoff"),
        current_agent_id=current_agent_id,
        available_agent_ids=available_agent_ids,
    )
    proposal = parse_prompt_proposal(payload.get("prompt_proposal"))
    return reply_text.strip(), handoff, proposal, True


def strip_json_code_fence(text: str) -> str:
    if not text.startswith("```") or not text.endswith("```"):
        return text

    lines = text.splitlines()
    if len(lines) < 3:
        return text

    opener = lines[0].strip().lower()
    if opener not in {"```", "```json"}:
        return text

    return "\n".join(lines[1:-1]).strip()


def parse_handoff(
    value: Any,
    *,
    current_agent_id: str,
    available_agent_ids: set[str],
) -> RuntimeHandoff | None:
    if value in (None, False):
        return None
    if not isinstance(value, dict):
        return None

    to_agent_id = value.get("to_agent_id")
    text = value.get("text")
    if not isinstance(to_agent_id, str) or not isinstance(text, str):
        return None

    to_agent_id = to_agent_id.strip()
    text = text.strip()
    if not to_agent_id or not text or to_agent_id == current_agent_id:
        return None
    if to_agent_id not in available_agent_ids:
        return None

    return RuntimeHandoff(to_agent_id=to_agent_id, text=text)


def parse_prompt_proposal(value: Any) -> PromptProposal | None:
    if value in (None, False):
        return None
    if not isinstance(value, dict):
        return None

    title = value.get("title")
    reason = value.get("reason")
    prompt_text = value.get("prompt_text")
    if not isinstance(prompt_text, str):
        return None

    prompt_text = prompt_text.strip()
    if not prompt_text:
        return None

    return PromptProposal(
        title=title.strip() if isinstance(title, str) and title.strip() else "Prompt proposal",
        reason=reason.strip() if isinstance(reason, str) else "",
        prompt_text=prompt_text,
    )
