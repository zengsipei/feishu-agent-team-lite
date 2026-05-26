import argparse
import asyncio
import json
import logging
import re
import sys

from lark_oapi.channel import FeishuChannel
from lark_oapi.core.enum import LogLevel

from .config import Settings
from .handoff import BotRosterClient, HandoffError, HandoffSender
from .registry import AgentApp, AgentAppRegistry


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send a Feishu bot-to-bot mention canary.")
    parser.add_argument("--from-agent", required=True, help="Agent id whose bot sends the canary.")
    parser.add_argument("--to-agent", required=True, help="Agent id whose bot is mentioned.")
    parser.add_argument("--chat-id", required=True, help="Target Feishu chat id.")
    parser.add_argument("--text", default="Bot-to-Bot mention canary.", help="Canary message text.")
    parser.add_argument("--title", default="", help="Optional Feishu post title.")
    parser.add_argument("--target-bot-id", default="", help="Optional pre-resolved target bot open_id for canary only.")
    parser.add_argument("--target-bot-name", default="", help="Optional pre-resolved target bot display name for canary only.")
    return parser.parse_args()


async def main_async() -> int:
    logging.basicConfig(level=logging.WARNING)
    args = parse_args()
    settings = Settings()
    registry = AgentAppRegistry(settings.agent_runtime_config_path)
    from_app = registry.get_app(args.from_agent)
    if from_app is None:
        print_json(
            {
                "ok": False,
                "from_agent": args.from_agent,
                "to_agent": args.to_agent,
                "error": "unknown_from_agent",
            }
        )
        return 2

    channel = build_channel(from_app)
    sender = HandoffSender(
        registry=registry,
        roster_client=BotRosterClient(channel.client),
    )

    try:
        if args.target_bot_id and args.target_bot_name:
            result, _target = await sender.send_to_known_bot(
                channel=channel,
                chat_id=args.chat_id,
                to_agent_id=args.to_agent,
                bot_id=args.target_bot_id,
                bot_name=args.target_bot_name,
                text=args.text,
                title=args.title,
            )
            target_source = "provided"
        else:
            result, _target = await sender.send(
                channel=channel,
                chat_id=args.chat_id,
                from_agent_id=args.from_agent,
                to_agent_id=args.to_agent,
                text=args.text,
                title=args.title,
            )
            target_source = "roster"
    except HandoffError as exc:
        error, message = classify_handoff_error(str(exc))
        print_json(
            {
                "ok": False,
                "from_agent": args.from_agent,
                "to_agent": args.to_agent,
                "error": error,
                "message": message,
            }
        )
        return 3

    print_json(
        {
            "ok": bool(getattr(result, "success", False)),
            "from_agent": args.from_agent,
            "to_agent": args.to_agent,
            "target_resolved": True,
            "target_source": target_source,
            "message_id_present": bool(getattr(result, "message_id", None)),
            "chunk_count": len(getattr(result, "chunk_ids", None) or []),
            "error": None if getattr(result, "success", False) else "send_failed",
        }
    )
    return 0 if getattr(result, "success", False) else 4


def build_channel(app: AgentApp) -> FeishuChannel:
    return FeishuChannel(
        app_id=app.app_id,
        app_secret=app.app_secret,
        log_level=LogLevel.WARNING,
    )


def print_json(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")


def sanitize_text(value: str) -> str:
    value = re.sub(r"\b(?:cli|oc|ou|om|omt)_[A-Za-z0-9_-]+\b", "<redacted>", value)
    value = re.sub(r"(app_secret|access_token|tenant_access_token)=\\S+", r"\1=<redacted>", value, flags=re.I)
    return value


def classify_handoff_error(value: str) -> tuple[str, str]:
    if "Access denied" in value and "im:chat.members:read" in value:
        return "missing_scope", "missing tenant scope: im:chat.members:read"
    return "handoff_error", sanitize_text(value)


def main() -> None:
    raise SystemExit(asyncio.run(main_async()))


if __name__ == "__main__":
    main()
