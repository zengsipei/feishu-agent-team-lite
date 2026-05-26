# Manual 1Panel Deploy Gate

Use this runbook after the target server read-only pre-check has no blocking failures. This gate authorizes a human operator to perform the 1Panel deployment action; it does not authorize Agent-run server operations, SSH automation, remote CI/CD deployment, or direct container control by Agents.

## Current Gate Status

| Item | State | Notes |
| --- | --- | --- |
| Target read-only pre-check | Conditional pass | Pre-deploy sanitized evidence reported `pass=13`, `warn=1`, `fail=0`, `not_verified=4`, `ok=true`. |
| Target running-service strict pre-check | Pass | Post-deploy sanitized evidence reported `pass=16`, `warn=0`, `fail=0`, `not_verified=2`, `ok=true`. |
| Blocking failures | None reported | Target private files and Compose config were present and valid in the supplied evidence. |
| Off-host backup target | Confirmed | External backup volume mounted at `/opt/1panel/apps/feishu-agent-team-lite`; confirmed by `zengsipei`. |
| Rollback owner | Confirmed | `zengsipei`. |
| Deploy operator | Confirmed | `zengsipei`. |
| Manual 1Panel Deploy Gate | Approved and completed | Approval captured for `feishu-agent-team`; target running-service evidence shows Compose containers, runtime health, and adapter workers are running. |
| Post-deploy real Feishu E2E | Pass | Batch `E8-234504`; 8 sent, 8 replies, 8 app sender matches, 8 real mentions, 0 failures. |
| Release state | Ready for project trial | Strict pre-check, backup/rollback ownership, deployment approval, and real Feishu E2E are complete. |

## Required Human Confirmation

Before opening the gate, capture these confirmations in chat or private release notes. Do not include secrets, raw env values, raw runtime config, app secrets, or real Feishu private IDs.

```text
Off-host backup target: <confirmed target label, not secret path details>
Rollback owner: <human owner>
Deploy operator: <human operator>
Deployment window: <date/time and timezone>
Approval: I approve opening the Manual 1Panel Deploy Gate for feishu-agent-team.
```

Captured confirmation:

```text
Off-host backup target: confirmed; external backup volume mounted at /opt/1panel/apps/feishu-agent-team-lite
Rollback owner: zengsipei
Deploy operator: zengsipei
Deployment window: 2026-05-26T22:31:42+08:00
Approval: I approve opening the Manual 1Panel Deploy Gate for feishu-agent-team.
```

## What The Gate Allows

After approval, the human operator may use 1Panel to:

- create or update the Compose app from the existing deployment directory
- select `docker-compose.full.yml`
- start the Compose app
- perform a human-directed rollback if the rollback owner decides it is required

Runtime exposes host port `${HOST_PORT:-8080}`. The adapter has no public HTTP port; its running state is verified through worker status files, logs, and real Feishu replies.

## What Remains Forbidden For Agents

Release Agent and runtime Agents must not:

- SSH into the 1Panel server
- write `.env`, `agent-runtime-config.json`, runtime data, adapter status, or server settings
- run `docker compose up`, `down`, `restart`, `pull`, `build`, or direct container commands
- start, stop, restart, recreate, or redeploy the 1Panel app
- paste raw secrets, app secrets, tokens, status files, SQLite files, raw logs, or real Feishu IDs into chat or git
- announce broader production readiness beyond this project-trial gate without separate approval

## Human 1Panel Action

In 1Panel:

1. Open `Containers` / `Compose`.
2. Create or update a Compose app from the existing file.
3. Set workdir to the deployment directory, for example `/opt/feishu-agent-team`.
4. Select `docker-compose.full.yml`.
5. Start the app.

Do not change private file content during this step unless a separate, explicit configuration change has been approved.

## Post-Deploy Strict Evidence

After the human operator starts the app, run the strict read-only pre-check from the deployment directory:

```bash
bash ./1panel-readonly-precheck.sh \
  --root-path . \
  --base-url http://127.0.0.1:8080 \
  --adapter-status-dir ./feishu-channel-adapter/status \
  --require-compose-services \
  --require-runtime-health \
  --require-adapter-connected \
  --port-mode RequireListening \
  --json \
  | python3 ./1panel-summarize-precheck.py - \
      --source-label target-strict-precheck \
      --server-label target-1panel \
      --deployment-label feishu-agent-team \
      --runtime-mode already-running
```

Expected strict evidence:

| Area | Required result |
| --- | --- |
| Compose services | Pass |
| Runtime health | Pass |
| Port state | Pass with `RequireListening` |
| Adapter status | 8 status files and 8 connected workers |
| Logs | Pass or zero problem lines |
| Secrets | Suppressed |

If PowerShell is available, also run:

```powershell
pwsh ./monitor-services.ps1 `
  -Docker `
  -BaseUrl http://127.0.0.1:8080 `
  -RuntimeEnvPath ./feishu-agent-runtime/.env `
  -AdapterStatusDir ./feishu-channel-adapter/status `
  -Json
```

Do not paste raw JSON if it contains local paths or app IDs. Paste only the sanitized Markdown summary from `1panel-summarize-precheck.py`, or summarize counts and pass/fail states.

## Post-Deploy Real Feishu E2E

After strict server checks pass:

1. Use the same test project group from the E2E runbook, or a new project group with all 8 Bot Apps invited.
2. Send one visible real `@Agent` test prompt per Agent.
3. Confirm every reply comes from the expected Bot App route.
4. Record only sanitized results: agent id, pass/fail, timestamp, and failure summary if any.

The server migration is not complete until all 8 real `@` replies pass in the target environment.

Current result: server migration gate is complete for project trial. Batch `E8-234504` passed 8/8 real `@Agent` replies with expected app routes.

## Failure Handling

If strict evidence or E2E fails:

- do not announce release readiness
- do not continue project trial traffic
- preserve sanitized evidence and failure summaries
- let the Rollback Owner decide whether to roll back, retry, or pause
- keep rollback operations human-operated through 1Panel

## Evidence Return Template

```markdown
# Manual 1Panel Deploy Gate Result

- Deployment window:
- Deploy operator:
- Rollback owner:
- Off-host backup target: confirmed / not confirmed
- Human 1Panel action: completed / not completed
- Strict pre-check: pass / fail
- Runtime health: pass / fail
- Adapter workers: <connected>/<expected>
- Problem log count:
- Real Feishu 8 Agent E2E: pass / fail / not run
- Release state: blocked / ready for project trial

## Sanitized Notes

- <counts and failure summaries only>
```
