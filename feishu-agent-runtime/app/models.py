from typing import Any, Literal

from pydantic import BaseModel, Field


class Mention(BaseModel):
    id: str | None = None
    name: str | None = None
    app_id: str | None = None


class ChannelMessage(BaseModel):
    event_id: str | None = None
    message_id: str | None = None
    app_id: str | None = Field(default=None, description="Bot app id that received the message.")
    agent_id: str | None = Field(default=None, description="Runtime agent id, if the adapter already knows it.")
    chat_id: str
    chat_type: str | None = None
    thread_id: str | None = None
    sender_id: str | None = None
    sender_name: str | None = None
    text: str = ""
    message_type: str | None = None
    mentions: list[Mention] = Field(default_factory=list)
    timestamp_ms: int | None = None
    project_id: str | None = Field(default=None, description="Optional explicit project id. Defaults to chat_id.")
    reply_mode: Literal["plain", "handoff", "silent"] = "plain"
    raw: dict[str, Any] = Field(default_factory=dict)


class ChannelComment(BaseModel):
    event_id: str | None = None
    comment_id: str
    app_id: str | None = None
    agent_id: str | None = None
    file_token: str | None = None
    file_type: str | None = None
    sender_id: str | None = None
    text: str = ""
    project_id: str | None = None
    raw: dict[str, Any] = Field(default_factory=dict)


class CardAction(BaseModel):
    event_id: str | None = None
    app_id: str | None = None
    agent_id: str | None = None
    chat_id: str | None = None
    user_id: str | None = None
    action: dict[str, Any] = Field(default_factory=dict)
    raw: dict[str, Any] = Field(default_factory=dict)


class RuntimeReply(BaseModel):
    status: Literal["ok", "ignored", "error"]
    agent_id: str | None = None
    agent_name: str | None = None
    session_id: str | None = None
    response_id: str | None = None
    reply_text: str = ""
    handoff_to: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class AgentSummary(BaseModel):
    agent_id: str
    agent_name: str
    app_id: str
    source_memory_file: str
    resolved_prompt_file: str | None = None
