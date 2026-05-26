# 1Panel Read-Only Pre-Check

Use this runbook before any formal 1Panel deployment or release. This stage is evidence collection only.

## Release Gate

| Gate | Status | Notes |
| --- | --- | --- |
| Local Docker adapter E2E | Pass | 8 Agent real visible Feishu `@` test passed in the test group. |
| Local Docker runtime/adapter monitoring | Pass | `monitor-services.ps1 -Docker` passed against the local Docker stack. |
| First project trial | Conditional pass | QA allowed the pre-deploy evidence checklist and server read-only pre-check. |
| 1Panel server read-only pre-check | Pending | Must be executed on the target server before deployment. |
| Formal deployment or release | Blocked | Requires reviewed evidence and explicit user approval. |
| Automatic multi-Agent rich mention relay | Blocked for unattended operation | Agents can write plain text/Markdown `@Agent`, but cannot yet emit a real Feishu rich-text mention that triggers the next Bot. |

## Forbidden Operations

Do not run these during this stage:

- `docker compose up`, `down`, `restart`, `pull`, or `build`
- `docker run`, `create`, `rm`, or container deletion
- 1Panel app start, stop, restart, recreate, redeploy, or settings writes
- writes to `.env`, `agent-runtime-config.json`, runtime data, adapter status, or server configuration
- publishing, release announcement, production traffic migration, or formal go-live
- printing or copying raw secrets, app secrets, tokens, `chat_id`, `open_id`, or `message_id` into reports

## Server Preconditions

The target server should already have the deployment directory prepared by the operator. The read-only script verifies presence and structure but does not create missing paths.

Recommended path:

```text
/opt/feishu-agent-team
```

Required private files on the server:

```text
config/agent-runtime-config.json
feishu-agent-runtime/.env
feishu-channel-adapter/.env
```

Runtime directories expected before first formal deployment:

```text
feishu-agent-runtime/data/
feishu-channel-adapter/status/
```

## Run The Read-Only Pre-Check

From the server deployment directory, prefer the Bash script on Linux/1Panel:

```bash
bash ./1panel-readonly-precheck.sh \
  --root-path . \
  --base-url http://127.0.0.1:8080 \
  --adapter-status-dir ./feishu-channel-adapter/status \
  --port-mode ReportOnly \
  --json
```

If PowerShell is already available, the equivalent command is:

```powershell
pwsh ./1panel-readonly-precheck.ps1 `
  -RootPath . `
  -BaseUrl http://127.0.0.1:8080 `
  -AdapterStatusDir ./feishu-channel-adapter/status `
  -PortMode ReportOnly `
  -Json
```

If the services are already running and the operator wants runtime/container state to be required:

```bash
bash ./1panel-readonly-precheck.sh \
  --root-path . \
  --base-url http://127.0.0.1:8080 \
  --adapter-status-dir ./feishu-channel-adapter/status \
  --require-compose-services \
  --require-runtime-health \
  --require-adapter-connected \
  --port-mode RequireListening \
  --json
```

```powershell
pwsh ./1panel-readonly-precheck.ps1 `
  -RootPath . `
  -BaseUrl http://127.0.0.1:8080 `
  -AdapterStatusDir ./feishu-channel-adapter/status `
  -RequireComposeServices `
  -RequireRuntimeHealth `
  -RequireAdapterConnected `
  -PortMode RequireListening `
  -Json
```

For a pre-deploy server where services have not been started yet, keep `ReportOnly` and do not require Compose services, runtime health, or adapter connectivity.

Optional provider connectivity probe:

```bash
bash ./1panel-readonly-precheck.sh \
  --root-path . \
  --network-probe-url https://api.openai.com/v1 \
  --json
```

```powershell
pwsh ./1panel-readonly-precheck.ps1 `
  -RootPath . `
  -NetworkProbeUrl https://api.openai.com/v1 `
  -Json
```

The script intentionally:

- checks env key presence but never prints values
- parses `agent-runtime-config.json` but only reports counts and uniqueness
- scans Docker logs by problem-pattern count without printing raw log lines
- records backup candidates without creating backup files
- exits `1` when required read-only checks fail

## Manual Fallback Checks

Use these only when PowerShell is unavailable. Keep outputs sanitized.

```bash
pwd
docker --version
docker compose version
docker compose -f docker-compose.full.yml config --quiet
docker compose -f docker-compose.full.yml ps
curl -fsS http://127.0.0.1:8080/health
ls -la config feishu-agent-runtime feishu-channel-adapter
find feishu-channel-adapter/status -maxdepth 1 -name '*.json' -type f | wc -l
docker compose -f docker-compose.full.yml logs --tail=200 feishu-agent-runtime feishu-channel-adapter | grep -E 'ERROR|WARNING|Traceback|Exception|failed|exited|retrying' | wc -l
```

Do not paste raw `.env`, raw runtime config, raw status files, or raw logs into the evidence package.

## Evidence Package Template

```markdown
# 1Panel Read-Only Pre-Check Evidence

- Task ID:
- Operator:
- Server:
- Deployment directory:
- Date/time:
- Runtime mode: pre-deploy / already-running
- Scope: read-only evidence collection only

## Commands Run

| Command summary | Result | Notes |
| --- | --- | --- |
| `bash ./1panel-readonly-precheck.sh ...` | pass/fail | Preferred on Linux/1Panel; JSON saved locally, secrets suppressed |
| `pwsh ./1panel-readonly-precheck.ps1 ...` | pass/fail | JSON saved locally, secrets suppressed |
| `pwsh ./monitor-services.ps1 -Docker ...` | pass/fail/not run | Run only if services are already running |

## Pre-Check Summary

| Area | Result | Evidence |
| --- | --- | --- |
| Host resources | pass/fail/not verified | OS, PowerShell, memory, disk summary |
| Docker/Compose | pass/fail/not verified | Docker and Compose version, config validation, `ps` summary |
| Port state | pass/fail/not verified | Required port policy and observed state |
| Directory layout | pass/fail/not verified | Required paths exist, ACL readable |
| Private env files | pass/fail/not verified | Required key names present; values suppressed |
| Runtime config | pass/fail/not verified | JSON parse ok, 8 apps, unique `agent_id` and `app_id`; secrets suppressed |
| Adapter status | pass/fail/not verified | 8 status files and connected count if services are running |
| Runtime health | pass/fail/not verified | `/health` only; no authenticated endpoint required |
| Logs | pass/fail/not verified | Problem-pattern counts only; raw logs suppressed |
| Network | pass/fail/not verified | Feishu Open Platform and optional model endpoint reachability |
| Backup/rollback prerequisites | pass/fail/not verified | Backup candidates identified; off-host backup target still operator-confirmed |

## Sanitized Script Output

Paste only sanitized summary fields:

```json
{
  "ok": true,
  "summary": {
    "pass": 0,
    "warn": 0,
    "fail": 0,
    "not_verified": 0
  }
}
```

## Risks And Blockers

- Formal deployment is still blocked until this evidence is reviewed and approved.
- Automatic multi-Agent relay is not fully unattended until real Feishu rich-text mention generation is implemented.
- Off-host backup target and rollback owner must be confirmed before deployment.

## Release Recommendation

- Recommended next stage:
- Conditions:
- Explicitly forbidden actions that remain forbidden:
```

## Sanitization Rules

Never include these in git, chat reports, screenshots, or evidence packages:

- `.env` values
- `app_secret`
- `CHANNEL_AUTH_TOKEN`
- `RUNTIME_AUTH_TOKEN`
- `OPENAI_API_KEY`
- raw `agent-runtime-config.json`
- real Feishu `chat_id`, `open_id`, `union_id`, `message_id`
- SQLite files, WAL files, raw logs, adapter raw status files
- private server IPs or internal hostnames unless the user explicitly approves sharing them

Use counts, booleans, timestamps, and status names instead of raw values.

## Next Stage Entry Criteria

All of these must be true before formal deployment work can be considered:

- read-only pre-check has no blocking failures
- evidence package has been reviewed and approved by the user
- off-host backup target and rollback owner are known
- server private files are present and permissions are acceptable
- Docker/Compose config validates on the target server
- formal deployment is explicitly requested after the evidence review

Even after server pre-check passes, the final release remains blocked until a post-deploy real Feishu 8 Agent E2E gate passes in the target environment.
