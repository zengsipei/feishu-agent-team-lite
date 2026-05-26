# Real Project Trial Runbook

Use this after local Docker E2E and server preflight pass. One Feishu group is one project workspace; the 8 Agent Apps are reusable team roles and can join multiple project groups.

## Preconditions

- Runtime and adapter are running in the intended environment.
- `monitor-services.ps1 -Docker` passes.
- All 8 Bot Apps are added to the project group.
- The group owner knows that Agent replies are visible to the group.
- The first trial task is small, real, and safe to process in chat.

## Project Group Setup

For each project group:

| Field | Value |
| --- | --- |
| Project name | `<project-name>` |
| Feishu group | `<group-name>` |
| Chat ID | `<oc_xxx>` |
| Owner | `<person/team>` |
| Start date | `<yyyy-mm-dd>` |

Invite all 8 Bot Apps:

- R&D Dispatcher
- Product Agent
- Architect Agent
- Coding Agent
- Review Agent
- QA Agent
- Docs Memory Agent
- Release Agent

Run the E2E check from [Agent Team E2E Runbook](./e2e-runbook.md) in the project group before sending real work.

## First Trial Task Shape

Pick a task that has:

- Clear business goal.
- Small implementation or design scope.
- No production secrets in the chat prompt.
- A visible acceptance criterion.
- A natural handoff path through at least 3 roles.

Good examples:

- Draft a small API design and review tradeoffs.
- Decompose a bug fix into implementation and QA checks.
- Review an existing change and produce release notes.

Avoid:

- Large ambiguous rewrites.
- Secrets, credentials, private customer data, or incident details.
- Tasks that require destructive production actions.

## Initial Dispatcher Prompt

Send this to the project group as the authorized user:

```text
@R&D Dispatcher
项目：<project-name>
任务：<one-sentence task>
背景：<brief context>
目标：<expected outcome>
约束：<time/scope/tech constraints>
验收标准：
1. <criterion>
2. <criterion>

请先拆解任务，明确需要哪些 Agent 参与，并通过真实 @ 交接给下一位 Agent。
```

Pass criteria for the first trial:

- Dispatcher replies with task decomposition and next Agent handoff.
- At least one specialist Agent responds to a real `@` handoff.
- The conversation keeps project context in the same group.
- No Agent replies from the wrong `app_id`.
- The trial produces one concrete artifact: design note, task list, review finding list, QA matrix, docs note, or release checklist.

## Observation Checklist

During the trial, watch:

- Does Dispatcher choose the right next role?
- Does each specialist stay within its role?
- Are handoffs explicit and visible as real `@Agent` mentions?
- Do replies remain concise enough for group chat?
- Does the runtime preserve enough context without cross-project leakage?
- Do monitor checks stay green while messages are flowing?

## Stop Conditions

Pause the trial if:

- Any Agent replies from an unexpected `app_id`.
- A worker disconnects or runtime returns `status=error`.
- The task starts requiring secrets or destructive operations.
- The group gets duplicate replies for the same mention.

## Trial Report Template

```markdown
# Project Agent Team Trial Report

- Project:
- Group:
- Date:
- Runtime mode:
- Initial task:
- Agents involved:
- Result:
- Artifacts produced:
- Issues:
- Follow-up changes:
```

## Next Action

To start a real trial, provide:

- Project group name or `chat_id`.
- Whether all 8 Bot Apps are already in the group.
- The first small task to send to `@R&D Dispatcher`.
