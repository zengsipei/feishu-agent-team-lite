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


if __name__ == "__main__":
    unittest.main()
