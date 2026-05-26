# Agent Team E2E Runbook

This runbook verifies that 8 Feishu Agent Apps can complete real `@Agent` message loops in a project group, and that each incoming event is routed by the correct `app_id`.

The values below are templates. Keep tenant-specific `chat_id`, `open_id`, `message_id`, and real Bot `app_id` values in your private deployment notes, not in this public repository.

## Test Group

| Field | Value |
| --- | --- |
| Chat name | `<your-test-project-group>` |
| Chat ID | `<oc_xxx>` |
| Operator identity | `--as user` |
| Runtime URL | `http://127.0.0.1:18080` |

In Codex environments, clear `HERMES_HOME` before running `lark-cli`:

```powershell
Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
```

## Agent Mapping Template

| Agent ID | Display name | App ID | Mention ID in test group |
| --- | --- | --- | --- |
| `rd-dispatcher` | R&D Dispatcher | `<cli_xxx>` | `<ou_xxx>` |
| `product` | Product Agent | `<cli_xxx>` | `<ou_xxx>` |
| `architect` | Architect Agent | `<cli_xxx>` | `<ou_xxx>` |
| `coding` | Coding Agent | `<cli_xxx>` | `<ou_xxx>` |
| `review` | Review Agent | `<cli_xxx>` | `<ou_xxx>` |
| `qa` | QA Agent | `<cli_xxx>` | `<ou_xxx>` |
| `docs-memory` | Docs Memory Agent | `<cli_xxx>` | `<ou_xxx>` |
| `release` | Release Agent | `<cli_xxx>` | `<ou_xxx>` |

## Before Sending Real Messages

Messages sent by `lark-cli im +messages-send` are visible in the group. Confirm these three fields before sending:

- Recipient: `<your-test-project-group>` / `<oc_xxx>`
- Sending identity: `--as user`
- Content: one `@Agent` test prompt per Agent

Manual Feishu UI testing is acceptable. Make sure each `@Agent` is a real mention chip, not plain text.

## Local Service Smoke Check

Run this before real `@` tests:

```powershell
cd <repo>\services
.\smoke-services.ps1
```

Expected:

- `/health` returns `ok = true`.
- `/v1/agents` returns 8 agents.
- `app_id` values are present and unique.
- Adapter status has 8 workers and each one is `connected`.
- Recent local stderr logs contain no `ERROR` or `WARNING`.

If you keep a private expected app map file, use:

```powershell
.\smoke-services.ps1 -ExpectedAppMapPath .\private-agent-app-map.json
```

Expected map shape:

```json
[
  {"agent_id": "rd-dispatcher", "app_id": "cli_xxx"},
  {"agent_id": "product", "app_id": "cli_xxx"}
]
```

## Real Feishu @ Test

Send one visible message per Agent. Use this exact content shape:

```text
@<Agent Display Name> 请只用一句话回复：<Agent Display Name> 路由和系统提示词测试通过。
```

PowerShell example for one Agent:

```powershell
Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
lark-cli im +messages-send `
  --chat-id <oc_xxx> `
  --msg-type text `
  --content '{"text":"<at user_id=\"<ou_xxx>\">Architect Agent</at> 请只用一句话回复：Architect Agent 路由和系统提示词测试通过。"}' `
  --as user
```

Fetch recent messages:

```powershell
Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
lark-cli im +chat-messages-list `
  --chat-id <oc_xxx> `
  --page-size 50 `
  --sort desc `
  --format json `
  --as user
```

Pass criteria for each Agent:

- The user message includes the intended `mentions[].id`.
- The Agent reply has `reply_to` equal to the user request `message_id`.
- The Agent reply `sender.sender_type` is `app`.
- The Agent reply `sender.id` equals the expected `app_id`.
- The reply content follows the requested one-sentence confirmation.

## E2E Record Template

| Agent ID | Request message | Reply message | Reply sender app_id | Result |
| --- | --- | --- | --- | --- |
| `rd-dispatcher` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |
| `product` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |
| `architect` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |
| `coding` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |
| `review` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |
| `qa` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |
| `docs-memory` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |
| `release` | `<om_xxx>` | `<om_xxx>` | `<cli_xxx>` | pass/fail |

## Troubleshooting

Use the local status script first:

```powershell
.\status-local-services.ps1 -Tail 180
```

Common failures:

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Worker missing or not `connected` | Channel SDK worker failed to start or lost WebSocket | Check `.local-run/adapter.err.log`, then restart adapter. |
| Reply sender `app_id` is wrong | App config or worker routing mismatch | Check `.runtime/agent-runtime-config.json`, `/v1/agents`, and adapter status files. |
| Runtime returns `error` | Model provider failed after retries | Check `.local-run/runtime.err.log` and provider `.env` values. |
| User message has no `mentions[]` | Sent plain text instead of real `@` mention | Re-send using Feishu UI mention chip or `--content` with `<at user_id="...">`. |
