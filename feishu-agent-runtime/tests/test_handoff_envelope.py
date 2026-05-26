import unittest

from app.runtime import parse_reply_envelope


class HandoffEnvelopeTests(unittest.TestCase):
    def test_plain_text_is_not_treated_as_envelope(self) -> None:
        reply_text, handoff, parsed = parse_reply_envelope(
            "普通回复",
            current_agent_id="rd-dispatcher",
            available_agent_ids={"architect"},
        )

        self.assertEqual(reply_text, "普通回复")
        self.assertIsNone(handoff)
        self.assertFalse(parsed)

    def test_valid_handoff_envelope_is_parsed(self) -> None:
        reply_text, handoff, parsed = parse_reply_envelope(
            '{"reply_text":"收到","handoff":{"to_agent_id":"architect","text":"请继续"}}',
            current_agent_id="rd-dispatcher",
            available_agent_ids={"architect", "coding"},
        )

        self.assertEqual(reply_text, "收到")
        self.assertIsNotNone(handoff)
        self.assertEqual(handoff.to_agent_id, "architect")
        self.assertEqual(handoff.text, "请继续")
        self.assertTrue(parsed)

    def test_json_code_fence_is_accepted(self) -> None:
        reply_text, handoff, parsed = parse_reply_envelope(
            '```json\n{"reply_text":"收到","handoff":{"to_agent_id":"architect","text":"请继续"}}\n```',
            current_agent_id="rd-dispatcher",
            available_agent_ids={"architect"},
        )

        self.assertEqual(reply_text, "收到")
        self.assertIsNotNone(handoff)
        self.assertEqual(handoff.to_agent_id, "architect")
        self.assertTrue(parsed)

    def test_unknown_handoff_target_is_dropped(self) -> None:
        reply_text, handoff, parsed = parse_reply_envelope(
            '{"reply_text":"收到","handoff":{"to_agent_id":"unknown","text":"请继续"}}',
            current_agent_id="rd-dispatcher",
            available_agent_ids={"architect"},
        )

        self.assertEqual(reply_text, "收到")
        self.assertIsNone(handoff)
        self.assertTrue(parsed)

    def test_self_handoff_is_dropped(self) -> None:
        _reply_text, handoff, parsed = parse_reply_envelope(
            '{"reply_text":"收到","handoff":{"to_agent_id":"rd-dispatcher","text":"请继续"}}',
            current_agent_id="rd-dispatcher",
            available_agent_ids={"rd-dispatcher", "architect"},
        )

        self.assertIsNone(handoff)
        self.assertTrue(parsed)

    def test_invalid_json_falls_back_to_plain_text(self) -> None:
        raw = '{"reply_text":"收到",'
        reply_text, handoff, parsed = parse_reply_envelope(
            raw,
            current_agent_id="rd-dispatcher",
            available_agent_ids={"architect"},
        )

        self.assertEqual(reply_text, raw)
        self.assertIsNone(handoff)
        self.assertFalse(parsed)


if __name__ == "__main__":
    unittest.main()
