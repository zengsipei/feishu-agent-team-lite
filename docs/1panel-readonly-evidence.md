# 1Panel Read-Only Pre-Check Evidence

- Task ID: agent-team-1panel-readonly-precheck-20260526
- Operator: Codex local workspace
- Date/time: 2026-05-26 Asia/Shanghai
- Scope: read-only evidence collection only
- Target server: read-only pre-check executed; no blocking failures found
- Local verification mode: Docker runtime/adapter already running
- Next stage: Manual 1Panel Deploy Gate
- Formal deployment: blocked

## Release Gate State

| Gate | State | Evidence |
| --- | --- | --- |
| Local Docker adapter 8 Agent E2E | Pass | Completed before this evidence package. |
| Local Docker runtime/adapter monitor | Pass | `monitor-services.ps1 -Docker` re-check passed locally; raw output is not included because it contains real app IDs and local paths. |
| Project trial QA | Conditional pass | Allows only 1Panel evidence checklist and server read-only pre-check. |
| Local Bash read-only pre-check script | Pass | `pass=16`, `warn=0`, `fail=0`, `not_verified=2`; strict JSON parse passed. |
| Local PowerShell read-only pre-check script | Pass | `pass=16`, `warn=0`, `fail=0`, `not_verified=2`. |
| Local running-service strict pre-check | Pass | Bash and PowerShell both passed with `--require-compose-services`, runtime health required, adapter connected required, and local mapped port `18080` required listening. |
| Target 1Panel server read-only pre-check | Conditional pass | `pass=13`, `warn=1`, `fail=0`, `not_verified=4`; `ok=true`; no blocking failures reported by the read-only pre-check. |
| Manual 1Panel Deploy Gate | Blocked | Allows only a human-operated 1Panel deployment window after evidence review, off-host backup/rollback confirmation, and explicit user approval. It does not authorize Agent-run server operations or remote CI/CD deployment. |
| Formal deployment/release | Blocked | Requires the Manual 1Panel Deploy Gate to open before any deployment action. |

## Commands Run Locally

| Command summary | Result | Sanitization |
| --- | --- | --- |
| `bash ./1panel-readonly-precheck.sh --root-path . --base-url http://127.0.0.1:18080 --adapter-status-dir ./feishu-channel-adapter/status --port-mode ReportOnly --json` | Pass | Env values, app secrets, app IDs, raw status content, and raw logs suppressed; output validated with a strict JSON parser. |
| `pwsh -NoProfile -File ./1panel-readonly-precheck.ps1 -RootPath . -BaseUrl http://127.0.0.1:18080 -AdapterStatusDir ./feishu-channel-adapter/status -PortMode ReportOnly -Json` | Pass | Env values, app secrets, app IDs, raw status content, and raw logs suppressed. |
| `bash ./1panel-readonly-precheck.sh --root-path . --base-url http://127.0.0.1:18080 --adapter-status-dir ./feishu-channel-adapter/status --ports 18080 --require-compose-services --require-runtime-health --require-adapter-connected --port-mode RequireListening --json` | Pass | `pass=16`, `warn=0`, `fail=0`, `not_verified=2`; running Docker services were only read. |
| `pwsh -NoProfile -File ./1panel-readonly-precheck.ps1 -RootPath . -BaseUrl http://127.0.0.1:18080 -AdapterStatusDir ./feishu-channel-adapter/status -Ports 18080 -RequireComposeServices -RequireRuntimeHealth -RequireAdapterConnected -PortMode RequireListening -Json` | Pass | `pass=16`, `warn=0`, `fail=0`, `not_verified=2`; Windows Docker Desktop port exposure was verified with read-only TCP connect fallback after listener table lookup. |
| `pwsh -NoProfile -File ./monitor-services.ps1 -Docker -BaseUrl http://127.0.0.1:18080 -AdapterStatusDir ./feishu-channel-adapter/status -Json` | Pass | Raw output excluded from evidence because it includes real app IDs and local paths. |
| `pwsh -NoProfile -File ./1panel-readonly-precheck.ps1 ... -Json | python ./1panel-summarize-precheck.py - ...` | Pass | Generated a Markdown evidence block containing only counts, statuses, non-sensitive service names, and suppressed-value markers. |
| PowerShell parser check for `1panel-readonly-precheck.ps1`, `smoke-services.ps1`, and `monitor-services.ps1` | Pass | Syntax only. |
| `python -m py_compile ./1panel-summarize-precheck.py` | Pass | Summarizer syntax/import validation only. |
| `bash -n ./1panel-readonly-precheck.sh` | Pass | Bash syntax only. |
| `git diff --check` | Pass | No whitespace or patch formatting issues. |
| Sensitive pattern scan over README, docs, and service scripts | Pass | Matches were limited to variable names or example commands; no real private IDs or secret values found. |

## Local Pre-Check Summary

| Area | Result | Evidence |
| --- | --- | --- |
| Host resources | Pass | OS, PowerShell, memory, and disk summary collected without writes. |
| Directory layout | Pass | Required directories exist; ACLs were read only; no write test performed. |
| Runtime env | Pass | Required key names present; values suppressed. |
| Adapter env | Pass | Required key names present; values suppressed. |
| Runtime config | Pass | JSON parse ok; 8 apps; 8 `agent_id`; 8 `app_id`; duplicate groups `0`; secret values suppressed. |
| Docker/Compose | Pass | Docker and Compose available; compose config validates; 2 containers observed locally. |
| Port state | Pass | `ReportOnly` passed for local pre-check; strict local running-service check also passed with port `18080` required listening. |
| Runtime health | Pass | Local `/health` reachable at `http://127.0.0.1:18080`. |
| Network connectivity | Pass | Feishu Open Platform probe reached the target and received an HTTP response. |
| Adapter status | Pass | 8 status files, 8 connected, 0 bad JSON; app IDs suppressed. |
| Logs | Pass | Compose logs scanned by problem-pattern count; raw log lines suppressed; count `0`. |
| Backup inventory | Pass | Backup candidates identified; no backup file created. |
| Off-host backup target | Not verified | Requires operator confirmation on the server. |
| Formal deploy approval | Not verified | Still blocked until user reviews server evidence and explicitly approves deployment. |

## Target Server Read-Only Evidence

Source summary:

- Source: target-reportonly-precheck
- Server label: target-1panel
- Deployment directory label: feishu-agent-team
- Runtime mode: pre-deploy
- Generated at: 2026-05-26T21:20:55+08:00
- Overall ok: true
- Expected agent count: 8
- Port mode: ReportOnly
- Raw env values, app IDs, app secrets, status file bodies, response bodies, and logs: suppressed

| pass | warn | fail | not_verified |
| --- | --- | --- | --- |
| 13 | 1 | 0 | 4 |

### Target Key Evidence

| Area | Result | Sanitized Evidence |
| --- | --- | --- |
| Host resources | Pass | Memory total `23975 MB`, available `15082 MB`; disk free `78.88 GB`, used `112.83 GB`. |
| Directory layout | Pass | 6 paths checked, 6 exist, 6 ACL-readable; write test not performed. |
| Runtime env | Pass | 4 required keys present, 0 missing, 0 blank; values suppressed. |
| Adapter env | Pass | 4 required keys present, 0 missing, 0 blank; values suppressed. |
| Runtime config | Pass | 8 apps, 8 `agent_id`, 8 `app_id`, duplicate groups `0`; secrets suppressed. |
| Docker/Compose | Pass | Compose file and CLI are present; `docker compose config` passed; `compose ps` reported no associated containers. |
| Port state | Pass | Port `8080` observed as listening via `ss`; policy was `ReportOnly`. |
| Runtime health | Not verified | Runtime health endpoint is not reachable. |
| Network | Pass | Feishu Open Platform reached and returned an HTTP response. |
| Adapter status | Warn | 0 status files, expected 8; 0 connected; app IDs suppressed. |
| Logs | Pass | 2 services checked, problem line count `0`; raw logs suppressed. |
| Backup inventory | Pass | 7 backup candidates checked, 4 exist; contents suppressed. |
| Off-host backup target | Not verified | Operator confirmation still required. |
| Formal deploy approval | Not verified | Still blocked until evidence is reviewed, backup/rollback ownership is confirmed, and the user explicitly opens the Manual 1Panel Deploy Gate. |

### Target Blocking Failures

- None reported by the pre-check.

### Target Warnings

| Area | Name | Summary |
| --- | --- | --- |
| adapter | worker status files | Adapter worker status files are incomplete or not all connected. |

### Target Not Verified

| Area | Name | Summary |
| --- | --- | --- |
| docker | compose ps | No Compose containers are currently associated with this file. |
| network | runtime health | Runtime health endpoint is not reachable. |
| rollback | external backup target | Operator must confirm the off-host backup target and rollback owner before deployment. |
| release_gate | formal deploy | Formal deployment remains blocked until sanitized evidence is reviewed and the Manual 1Panel Deploy Gate is explicitly opened. |

### Target Re-Check Command

Before any deployment action is approved, rerun the read-only summary command if private files, Compose settings, backup ownership, or server state changes:

```bash
bash ./1panel-readonly-precheck.sh \
  --root-path . \
  --base-url http://127.0.0.1:8080 \
  --adapter-status-dir ./feishu-channel-adapter/status \
  --port-mode ReportOnly \
  --json \
  | python3 ./1panel-summarize-precheck.py - \
      --source-label target-reportonly-precheck \
      --server-label target-1panel \
      --deployment-label feishu-agent-team \
      --runtime-mode pre-deploy
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

- Formal deployment and release are still blocked until the Manual 1Panel Deploy Gate opens.
- The target 1Panel server read-only pre-check now reports no blocking failures.
- Adapter worker status is still a warning because services are not running and no status files exist in pre-deploy mode.
- Runtime health is not verified because the runtime service is not running in pre-deploy mode.
- Compose containers are not associated with the file yet; this is expected before formal deployment but remains unverified runtime state.
- Off-host backup target and rollback owner remain operator-confirmed items.
- The next stage is not remote CI/CD access. Release Agent may coordinate Feishu approvals or GitHub workflows for other systems, but must not operate this 1Panel server.
- Agents still cannot emit real Feishu rich-text mentions for automatic multi-Agent relay; unattended cross-Agent handoff requires later orchestration work.

## Forbidden Actions Still In Effect

- Do not run `docker compose up`, `down`, `restart`, `pull`, or `build`.
- Do not start, stop, restart, recreate, or redeploy in 1Panel.
- Do not write `.env`, runtime config, runtime data, adapter status, or server settings.
- Do not publish or announce release readiness.
- Do not paste raw secrets, tokens, app secrets, real Feishu IDs, SQLite files, status files, or raw logs into git or chat reports.

## Recommendation

The read-only evidence can move to review. The recommended next stage is Manual 1Panel Deploy Gate. Do not proceed to formal deployment until off-host backup/rollback ownership is confirmed and the user explicitly opens that gate. Until then, deployment, restart, recreate, build, pull, and production configuration write operations remain forbidden.
