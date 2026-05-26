import logging
from typing import Any

import lark_oapi as lark
from lark_oapi.api.drive.v1 import (
    BatchQueryFileCommentRequest,
    BatchQueryFileCommentRequestBody,
)

from .registry import AgentApp

logger = logging.getLogger(__name__)


class DriveCommentClient:
    def __init__(self, app: AgentApp):
        self._client = (
            lark.Client.builder()
            .app_id(app.app_id)
            .app_secret(app.app_secret)
            .build()
        )

    async def get_comment_text(self, *, file_token: str, file_type: str, comment_id: str) -> str:
        request = (
            BatchQueryFileCommentRequest.builder()
            .file_token(file_token)
            .file_type(file_type)
            .user_id_type("open_id")
            .request_body(
                BatchQueryFileCommentRequestBody.builder()
                .comment_ids([comment_id])
                .build()
            )
            .build()
        )
        response = await self._client.drive.v1.file_comment.abatch_query(request)
        if not response.success():
            logger.warning(
                "Drive comment fetch failed app_id=%s file_token=%s comment_id=%s code=%s msg=%s",
                app_id_for_log(self._client),
                file_token,
                comment_id,
                response.code,
                response.msg,
            )
            return ""
        items = getattr(getattr(response, "data", None), "items", None) or []
        if not items:
            return ""
        comment = items[0]
        return render_comment(comment)


def render_comment(comment: Any) -> str:
    parts = []
    quote = getattr(comment, "quote", None)
    if quote:
        parts.append(f"引用: {quote}")
    replies = getattr(getattr(comment, "reply_list", None), "replies", None) or []
    for reply in replies:
        text = render_reply(reply)
        if text:
            parts.append(text)
    return "\n".join(parts).strip()


def render_reply(reply: Any) -> str:
    content = getattr(reply, "content", None)
    elements = getattr(content, "elements", None) or []
    chunks = []
    for element in elements:
        element_type = getattr(element, "type", None)
        if element_type == "text_run" and getattr(element, "text_run", None):
            chunks.append(getattr(element.text_run, "text", "") or "")
        elif element_type == "person" and getattr(element, "person", None):
            chunks.append(f"@{getattr(element.person, 'name', '') or getattr(element.person, 'user_id', '')}")
        elif element_type == "docs_link" and getattr(element, "docs_link", None):
            chunks.append(getattr(element.docs_link, "url", "") or "")
    return "".join(chunks).strip()


def app_id_for_log(client: Any) -> str:
    config = getattr(client, "config", None)
    return getattr(config, "app_id", "") or ""
