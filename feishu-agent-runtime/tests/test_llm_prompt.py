import unittest

from app.llm import build_completion_user_message


class LLMOutputContractPromptTests(unittest.TestCase):
    def test_requires_strict_json_handoff_contract(self) -> None:
        prompt = build_completion_user_message(
            user_text="请继续交给架构师",
            metadata={
                "project_id": "chat-1",
                "available_agent_ids": ["architect", "coding"],
            },
        )

        self.assertIn("Return only one valid JSON object", prompt)
        self.assertIn('"reply_text"', prompt)
        self.assertIn('"handoff"', prompt)
        self.assertIn('"to_agent_id"', prompt)
        self.assertIn('"architect"', prompt)
        self.assertIn('"coding"', prompt)

    def test_delegates_real_mentions_to_channel_adapter(self) -> None:
        prompt = build_completion_user_message(
            user_text="handoff",
            metadata={"available_agent_ids": ["architect"]},
        )

        self.assertIn("The channel adapter will send the real rich-text @", prompt)
        self.assertIn("Do not include Feishu <at> tags", prompt)
        self.assertIn("open_id, app_id, or bot_id", prompt)

    def test_blocks_missing_execution_access_without_handoff(self) -> None:
        prompt = build_completion_user_message(
            user_text="请修改仓库文件",
            metadata={"available_agent_ids": ["rd-dispatcher", "coding"]},
        )

        self.assertIn("Feishu is the business system of record", prompt)
        self.assertIn("Prefer Feishu-native orchestration", prompt)
        self.assertIn("repository, filesystem, PowerShell, shell, Docker, GitHub, or server access", prompt)
        self.assertIn("状态：Blocked", prompt)
        self.assertIn("set handoff to null", prompt)
        self.assertIn("Do not hand off back to the sender", prompt)
        self.assertIn("Do not rely on the next Agent seeing prior @ messages", prompt)


if __name__ == "__main__":
    unittest.main()
