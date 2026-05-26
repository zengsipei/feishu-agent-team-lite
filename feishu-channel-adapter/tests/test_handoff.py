import unittest
from types import SimpleNamespace
from unittest.mock import patch

from app.adapter import ChannelAdapter
from app.handoff import BotRosterMember, GroupBotRosterResolver, HandoffError
from app.registry import AgentApp


class FakeRegistry:
    def __init__(self, apps: list[AgentApp]):
        self.apps = {app.agent_id: app for app in apps}

    def get_app(self, agent_id: str) -> AgentApp | None:
        return self.apps.get(agent_id)


class FakeRosterClient:
    def __init__(self, members: list[BotRosterMember]):
        self.members = members

    async def list_bot_members(self, chat_id: str) -> list[BotRosterMember]:
        return self.members


class FakeChannel:
    def __init__(self):
        self.client = object()
        self.sent = []

    async def send(self, chat_id, body, opts=None):
        self.sent.append((chat_id, body, opts))
        return SimpleNamespace(success=True)


class FailingHandoffSender:
    async def send(self, **_kwargs):
        raise HandoffError("missing scope")


class RosterResolverTests(unittest.IsolatedAsyncioTestCase):
    async def test_resolves_target_by_mention_name_case_insensitive(self) -> None:
        app = AgentApp(
            agent_id="architect",
            agent_name="Architect Agent",
            app_id="app-fake",
            app_secret="secret",
            mention_names=("Architect Agent",),
        )
        resolver = GroupBotRosterResolver(
            registry=FakeRegistry([app]),
            roster_client=FakeRosterClient(
                [
                    BotRosterMember(bot_id="bot_1", bot_name="architect agent"),
                    BotRosterMember(bot_id="bot_2", bot_name="Coding Agent"),
                ]
            ),
        )

        target = await resolver.resolve(
            chat_id="chat",
            from_agent_id="rd-dispatcher",
            to_agent_id="architect",
        )

        self.assertEqual(target.agent.agent_id, "architect")
        self.assertEqual(target.bot_id, "bot_1")

    async def test_rejects_self_handoff_before_roster_lookup(self) -> None:
        app = AgentApp(
            agent_id="architect",
            agent_name="Architect Agent",
            app_id="app-fake",
            app_secret="secret",
            mention_names=("Architect Agent",),
        )
        resolver = GroupBotRosterResolver(
            registry=FakeRegistry([app]),
            roster_client=FakeRosterClient([]),
        )

        with self.assertRaisesRegex(HandoffError, "self-handoff"):
            await resolver.resolve(
                chat_id="chat",
                from_agent_id="architect",
                to_agent_id="architect",
            )

    async def test_unknown_target_is_rejected(self) -> None:
        resolver = GroupBotRosterResolver(
            registry=FakeRegistry([]),
            roster_client=FakeRosterClient([]),
        )

        with self.assertRaisesRegex(HandoffError, "Unknown handoff target"):
            await resolver.resolve(
                chat_id="chat",
                from_agent_id="rd-dispatcher",
                to_agent_id="architect",
            )


class AdapterHandoffTests(unittest.IsolatedAsyncioTestCase):
    async def test_handoff_failure_does_not_block_primary_reply(self) -> None:
        adapter = object.__new__(ChannelAdapter)
        adapter.registry = object()
        channel = FakeChannel()
        app = AgentApp(
            agent_id="rd-dispatcher",
            agent_name="R&D Dispatcher",
            app_id="app-fake",
            app_secret="secret",
        )
        message = SimpleNamespace(chat_id="chat", message_id="message")
        reply = {
            "status": "ok",
            "agent_id": "rd-dispatcher",
            "reply_text": "收到",
            "handoff": {"to_agent_id": "architect", "text": "请继续"},
        }

        with (
            patch("app.adapter.HandoffSender", return_value=FailingHandoffSender()),
            self.assertLogs("app.adapter", level="WARNING") as logs,
        ):
            await adapter._send_message_reply(channel, app, message, reply)

        self.assertEqual(len(channel.sent), 1)
        self.assertEqual(channel.sent[0][0], "chat")
        self.assertEqual(channel.sent[0][1], {"markdown": "收到"})
        self.assertEqual(channel.sent[0][2], {"reply_to": "message"})
        self.assertIn("Agent handoff failed", "\n".join(logs.output))


if __name__ == "__main__":
    unittest.main()
