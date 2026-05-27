import json
import tempfile
import unittest
from pathlib import Path

from app.agents import AgentConfig, AgentRegistry
from app.config import Settings
from app.control_plane import AgentRunRecord, ControlPlanePrompt, FeishuBaseControlPlane, PromptProposal
from app.main import build_control_plane
from app.models import ChannelMessage
from app.runtime import AgentRuntime
from app.store import RuntimeStore


class FakeLLM:
    def __init__(self, reply: str):
        self.reply = reply
        self.calls = []

    async def complete(self, *, agent, user_text, history, metadata):
        self.calls.append(
            {
                "agent": agent,
                "user_text": user_text,
                "history": history,
                "metadata": metadata,
            }
        )
        return self.reply


class FailingLLM:
    async def complete(self, *, agent, user_text, history, metadata):
        raise RuntimeError("provider unavailable")


class FakeControlPlane:
    def __init__(self, prompt: ControlPlanePrompt | None = None):
        self.prompt = prompt
        self.runs: list[AgentRunRecord] = []
        self.proposals: list[tuple[AgentConfig, PromptProposal, str | None]] = []
        self.closed = False

    async def get_prompt(self, agent):
        return self.prompt

    async def record_run(self, run):
        self.runs.append(run)

    async def propose_prompt(self, *, agent, proposal, run_id):
        self.proposals.append((agent, proposal, run_id))

    async def close(self):
        self.closed = True


class FakeHttpClient:
    async def aclose(self):
        return None


class ControlPlaneRuntimeTests(unittest.IsolatedAsyncioTestCase):
    def make_runtime(self, *, llm_reply: str, control_plane: FakeControlPlane | None = None):
        temp_dir = tempfile.TemporaryDirectory()
        root = Path(temp_dir.name)
        config_path = root / "agent-runtime-config.json"
        config_path.write_text(
            json.dumps(
                {
                    "apps": [
                        {
                            "agent_id": "coding",
                            "agent_name": "Coding Agent",
                            "app_id": "app-coding",
                            "source_memory_file": "agents/coding.md",
                            "resolved_prompt_file": "resolved/coding.md",
                            "system_prompt": "local prompt",
                        },
                        {
                            "agent_id": "review",
                            "agent_name": "Review Agent",
                            "app_id": "app-review",
                            "source_memory_file": "agents/review.md",
                            "resolved_prompt_file": "resolved/review.md",
                            "system_prompt": "review prompt",
                        },
                    ]
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        runtime = AgentRuntime(
            registry=AgentRegistry(config_path),
            store=RuntimeStore(root / "runtime.sqlite3"),
            llm=FakeLLM(llm_reply),
            max_context_messages=8,
            control_plane=control_plane,
        )
        self.addCleanup(temp_dir.cleanup)
        return runtime

    async def test_uses_control_plane_prompt_without_mutating_registry(self) -> None:
        control = FakeControlPlane(
            ControlPlanePrompt(
                text="feishu prompt",
                source="feishu_base",
                version="v1",
            )
        )
        runtime = self.make_runtime(
            llm_reply='{"reply_text":"收到","handoff":null}',
            control_plane=control,
        )

        reply = await runtime.handle_message(
            ChannelMessage(
                event_id="event-1",
                message_id="message-1",
                agent_id="coding",
                chat_id="project-1",
                sender_id="sender-1",
                text="hello",
                project_id="project-1",
            )
        )

        self.assertEqual(reply.status, "ok")
        self.assertEqual(reply.metadata["prompt_source"], "feishu_base")
        self.assertEqual(reply.metadata["prompt_version"], "v1")
        self.assertEqual(runtime.llm.calls[0]["agent"].system_prompt, "feishu prompt")
        self.assertEqual(runtime.registry.get(agent_id="coding").system_prompt, "local prompt")
        self.assertEqual(len(control.runs), 1)
        self.assertEqual(control.runs[0].agent_id, "coding")
        self.assertEqual(control.runs[0].prompt_source, "feishu_base")
        self.assertEqual(control.runs[0].prompt_version, "v1")

    async def test_prompt_proposal_creates_candidate_only(self) -> None:
        control = FakeControlPlane()
        runtime = self.make_runtime(
            llm_reply=(
                '{"reply_text":"建议候选已提交","handoff":null,'
                '"prompt_proposal":{"title":"Tighten Coding Agent","reason":"更短",'
                '"prompt_text":"作为 Coding Agent，先确认执行权限。"}}'
            ),
            control_plane=control,
        )

        reply = await runtime.handle_message(
            ChannelMessage(
                event_id="event-2",
                message_id="message-2",
                agent_id="coding",
                chat_id="project-1",
                sender_id="sender-1",
                text="please improve yourself",
                project_id="project-1",
            )
        )

        self.assertEqual(reply.status, "ok")
        self.assertTrue(reply.metadata["prompt_proposal_created"])
        self.assertEqual(runtime.registry.get(agent_id="coding").system_prompt, "local prompt")
        self.assertEqual(len(control.proposals), 1)
        agent, proposal, run_id = control.proposals[0]
        self.assertEqual(agent.agent_id, "coding")
        self.assertEqual(proposal.title, "Tighten Coding Agent")
        self.assertEqual(proposal.reason, "更短")
        self.assertEqual(proposal.prompt_text, "作为 Coding Agent，先确认执行权限。")
        self.assertEqual(run_id, reply.response_id)

    async def test_llm_error_reports_control_plane_prompt_source(self) -> None:
        control = FakeControlPlane(
            ControlPlanePrompt(
                text="feishu prompt",
                source="feishu_base",
                version="v1",
            )
        )
        runtime = self.make_runtime(
            llm_reply='{"reply_text":"unused","handoff":null}',
            control_plane=control,
        )
        runtime.llm = FailingLLM()

        reply = await runtime.handle_message(
            ChannelMessage(
                event_id="event-3",
                message_id="message-3",
                agent_id="coding",
                chat_id="project-1",
                sender_id="sender-1",
                text="hello",
                project_id="project-1",
            )
        )

        self.assertEqual(reply.status, "error")
        self.assertEqual(reply.metadata["prompt_source"], "feishu_base")
        self.assertEqual(reply.metadata["prompt_version"], "v1")
        self.assertFalse(reply.metadata["prompt_proposal_created"])
        self.assertEqual(len(control.runs), 1)
        self.assertEqual(control.runs[0].status, "error")
        self.assertEqual(control.runs[0].prompt_source, "feishu_base")
        self.assertEqual(control.runs[0].prompt_version, "v1")


class ControlPlaneConfigTests(unittest.TestCase):
    def test_disabled_control_plane_uses_null_adapter(self) -> None:
        control_plane = build_control_plane(Settings(control_plane_enabled=False))

        self.assertEqual(type(control_plane).__name__, "NullControlPlane")

    def test_enabled_control_plane_requires_all_runtime_keys(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "CONTROL_PLANE_APP_ID"):
            build_control_plane(
                Settings(
                    control_plane_enabled=True,
                    control_plane_app_id="",
                    control_plane_app_secret="",
                    control_plane_base_token="",
                    control_plane_agents_table_id="",
                    control_plane_prompt_versions_table_id="",
                    control_plane_agent_runs_table_id="",
                )
            )


class FeishuBaseControlPlaneProtocolTests(unittest.IsolatedAsyncioTestCase):
    def make_control_plane(self) -> FeishuBaseControlPlane:
        control = object.__new__(FeishuBaseControlPlane)
        control.base_url = "https://open.feishu.cn"
        control.app_id = "app-id"
        control.app_secret = "app-secret"
        control.base_token = "base-token"
        control.agents_table_id = "tbl_agents"
        control.prompt_versions_table_id = "tbl_prompts"
        control.agent_runs_table_id = "tbl_runs"
        control.client = FakeHttpClient()
        control._tenant_token = None
        control._tenant_token_expires_at = 0.0
        return control

    async def test_list_records_uses_lark_cli_base_v3_shape(self) -> None:
        control = self.make_control_plane()
        calls = []

        async def fake_request(method, path, *, json_body=None, params=None):
            calls.append({"method": method, "path": path, "json_body": json_body, "params": params})
            return {"data": {"items": [{"fields": {"Agent ID": "coding"}}]}}

        control._request = fake_request
        try:
            records = await control._list_records("tbl_agents")
        finally:
            await control.close()

        self.assertEqual(records, [{"fields": {"Agent ID": "coding"}}])
        self.assertEqual(calls[0]["method"], "GET")
        self.assertEqual(calls[0]["path"], "/open-apis/base/v3/bases/base-token/tables/tbl_agents/records")
        self.assertEqual(calls[0]["params"], {"limit": 200, "offset": 0})
        self.assertIsNone(calls[0]["json_body"])

    async def test_list_records_paginates_with_feishu_limit(self) -> None:
        control = self.make_control_plane()
        calls = []

        async def fake_request(method, path, *, json_body=None, params=None):
            calls.append({"method": method, "path": path, "json_body": json_body, "params": params})
            if params["offset"] == 0:
                return {
                    "data": {
                        "items": [{"fields": {"Agent ID": "coding"}}],
                        "has_more": True,
                    }
                }
            return {
                "data": {
                    "items": [{"fields": {"Agent ID": "review"}}],
                    "has_more": False,
                }
            }

        control._request = fake_request
        try:
            records = await control._list_records("tbl_agents")
        finally:
            await control.close()

        self.assertEqual(
            records,
            [
                {"fields": {"Agent ID": "coding"}},
                {"fields": {"Agent ID": "review"}},
            ],
        )
        self.assertEqual(calls[0]["params"], {"limit": 200, "offset": 0})
        self.assertEqual(calls[1]["params"], {"limit": 200, "offset": 1})

    async def test_list_records_accepts_base_v3_matrix_shape(self) -> None:
        control = self.make_control_plane()

        async def fake_request(method, path, *, json_body=None, params=None):
            return {
                "data": {
                    "fields": ["Agent ID", "Status", "Current Prompt", "Current Prompt Version"],
                    "data": [["coding", [{"name": "Active"}], "feishu prompt", "v1"]],
                    "record_id_list": ["rec-1"],
                }
            }

        control._request = fake_request
        try:
            records = await control._list_records("tbl_agents")
        finally:
            await control.close()

        self.assertEqual(
            records,
            [
                {
                    "record_id": "rec-1",
                    "fields": {
                        "Agent ID": "coding",
                        "Status": [{"name": "Active"}],
                        "Current Prompt": "feishu prompt",
                        "Current Prompt Version": "v1",
                    },
                }
            ],
        )

    async def test_create_record_sends_field_mapping_as_body(self) -> None:
        control = self.make_control_plane()
        calls = []
        fields = {"Run ID": "run-1", "Agent ID": "coding", "Status": "ok"}

        async def fake_request(method, path, *, json_body=None, params=None):
            calls.append({"method": method, "path": path, "json_body": json_body, "params": params})
            return {"data": {"record_id": "rec-1"}}

        control._request = fake_request
        try:
            await control._create_record("tbl_runs", fields)
        finally:
            await control.close()

        self.assertEqual(calls[0]["method"], "POST")
        self.assertEqual(calls[0]["path"], "/open-apis/base/v3/bases/base-token/tables/tbl_runs/records")
        self.assertEqual(calls[0]["json_body"], fields)
        self.assertIsNone(calls[0]["params"])


if __name__ == "__main__":
    unittest.main()
