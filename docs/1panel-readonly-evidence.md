# 1Panel Read-Only Pre-Check Evidence

- Task ID: agent-team-1panel-readonly-precheck-20260526
- Operator: Codex local workspace
- Date/time: 2026-05-26 Asia/Shanghai
- Scope: read-only evidence collection only
- Target server: pending operator execution
- Local verification mode: Docker runtime/adapter already running
- Formal deployment: blocked

## Release Gate State

| Gate | State | Evidence |
| --- | --- | --- |
| Local Docker adapter 8 Agent E2E | Pass | Completed before this evidence package. |
| Local Docker runtime/adapter monitor | Pass | `monitor-services.ps1 -Docker` re-check passed locally; raw output is not included because it contains real app IDs and local paths. |
| Project trial QA | Conditional pass | Allows only 1Panel evidence checklist and server read-only pre-check. |
| Local Bash read-only pre-check script | Pass | `pass=16`, `warn=0`, `fail=0`, `not_verified=2`; strict JSON parse passed. |
| Local PowerShell read-only pre-check script | Pass | `pass=16`, `warn=0`, `fail=0`, `not_verified=2`. |
| Target 1Panel server read-only pre-check | Pending | Must be run on `/opt/feishu-agent-team` or the chosen deployment directory. |
| Formal deployment/release | Blocked | Requires reviewed server evidence and explicit user approval. |

## Commands Run Locally

| Command summary | Result | Sanitization |
| --- | --- | --- |
| `bash ./1panel-readonly-precheck.sh --root-path . --base-url http://127.0.0.1:18080 --adapter-status-dir ./feishu-channel-adapter/status --port-mode ReportOnly --json` | Pass | Env values, app secrets, app IDs, raw status content, and raw logs suppressed; output validated with a strict JSON parser. |
| `pwsh -NoProfile -File ./1panel-readonly-precheck.ps1 -RootPath . -BaseUrl http://127.0.0.1:18080 -AdapterStatusDir ./feishu-channel-adapter/status -PortMode ReportOnly -Json` | Pass | Env values, app secrets, app IDs, raw status content, and raw logs suppressed. |
| `pwsh -NoProfile -File ./monitor-services.ps1 -Docker -BaseUrl http://127.0.0.1:18080 -AdapterStatusDir ./feishu-channel-adapter/status -Json` | Pass | Raw output excluded from evidence because it includes real app IDs and local paths. |
| PowerShell parser check for `1panel-readonly-precheck.ps1`, `smoke-services.ps1`, and `monitor-services.ps1` | Pass | Syntax only. |

## Local Pre-Check Summary

| Area | Result | Evidence |
| --- | --- | --- |
| Host resources | Pass | OS, PowerShell, memory, and disk summary collected without writes. |
| Directory layout | Pass | Required directories exist; ACLs were read only; no write test performed. |
| Runtime env | Pass | Required key names present; values suppressed. |
| Adapter env | Pass | Required key names present; values suppressed. |
| Runtime config | Pass | JSON parse ok; 8 apps; 8 `agent_id`; 8 `app_id`; duplicate groups `0`; secret values suppressed. |
| Docker/Compose | Pass | Docker and Compose available; compose config validates; 2 containers observed locally. |
| Port state | Pass | Port policy was `ReportOnly`; no server write action. |
| Runtime health | Pass | Local `/health` reachable at `http://127.0.0.1:18080`. |
| Network connectivity | Pass | Feishu Open Platform probe reached the target and received an HTTP response. |
| Adapter status | Pass | 8 status files, 8 connected, 0 bad JSON; app IDs suppressed. |
| Logs | Pass | Compose logs scanned by problem-pattern count; raw log lines suppressed; count `0`. |
| Backup inventory | Pass | Backup candidates identified; no backup file created. |
| Off-host backup target | Not verified | Requires operator confirmation on the server. |
| Formal deploy approval | Not verified | Still blocked until user reviews server evidence and explicitly approves deployment. |

## Target Server Evidence Still Required

Run from the target deployment directory, without starting, restarting, recreating, or modifying services:

```bash
bash ./1panel-readonly-precheck.sh \
  --root-path . \
  --base-url http://127.0.0.1:8080 \
  --adapter-status-dir ./feishu-channel-adapter/status \
  --port-mode ReportOnly \
  --json
```

```powershell
pwsh ./1panel-readonly-precheck.ps1 `
  -RootPath . `
  -BaseUrl http://127.0.0.1:8080 `
  -AdapterStatusDir ./feishu-channel-adapter/status `
  -PortMode ReportOnly `
  -Json
```

If the target services are already running and the operator wants runtime state enforced:

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

## Required Server Evidence Fields

| Field | Required State |
| --- | --- |
| Host resources | CPU/memory/disk summary captured; no writes performed. |
| Docker/Compose | CLI available; compose config validates. |
| Port policy | Either free before deployment or listening if services are already running; operator records which mode was used. |
| Private files | Required file presence and key names checked; values suppressed. |
| Runtime config | 8 apps, unique `agent_id`, unique `app_id`; secrets suppressed. |
| Adapter status | 8 connected only if services are already running; otherwise marked not verified. |
| Logs | Problem-pattern counts only; no raw logs pasted. |
| Backup/rollback | Off-host backup target and rollback owner confirmed before deployment approval. |

## Risks And Blockers

- Formal deployment and release are still blocked.
- The target 1Panel server has not yet produced read-only evidence in this repository.
- Off-host backup target and rollback owner remain operator-confirmed items.
- Agents still cannot emit real Feishu rich-text mentions for automatic multi-Agent relay; unattended cross-Agent handoff requires later orchestration work.

## Forbidden Actions Still In Effect

- Do not run `docker compose up`, `down`, `restart`, `pull`, or `build`.
- Do not start, stop, restart, recreate, or redeploy in 1Panel.
- Do not write `.env`, runtime config, runtime data, adapter status, or server settings.
- Do not publish or announce release readiness.
- Do not paste raw secrets, tokens, app secrets, real Feishu IDs, SQLite files, status files, or raw logs into git or chat reports.

## Recommendation

Proceed only to target-server read-only evidence collection. Do not proceed to formal deployment until the server evidence package has no blocking failures, backup/rollback ownership is confirmed, and the user explicitly approves the next stage.
