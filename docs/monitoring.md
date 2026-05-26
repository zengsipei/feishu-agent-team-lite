# Minimal Monitoring

The services expose one HTTP health surface and one file-based adapter worker status surface.

## What To Monitor

| Signal | Source | Expected |
| --- | --- | --- |
| Runtime HTTP health | `GET /health` | `ok=true` |
| Agent route table | `GET /v1/agents` with `CHANNEL_AUTH_TOKEN` | 8 agents, unique `agent_id` and `app_id` |
| Adapter workers | `feishu-channel-adapter/status/*.json` | 8 files, each `status=connected` |
| Runtime provider failures | runtime logs | no `ERROR`, retry storms, or `Runtime returned status=error` |
| Adapter worker failures | adapter logs | no `exited`, `failed`, `Traceback`, or `ERROR` |
| Docker container state | `docker compose ps` | runtime running and healthy, adapter running |

## Local Docker Check

```powershell
cd <repo>\services
.\monitor-services.ps1 `
  -Docker `
  -BaseUrl http://127.0.0.1:18080 `
  -AdapterStatusDir .\feishu-channel-adapter\status
```

JSON output for scheduled checks:

```powershell
.\monitor-services.ps1 `
  -Docker `
  -BaseUrl http://127.0.0.1:18080 `
  -AdapterStatusDir .\feishu-channel-adapter\status `
  -Json
```

The process exits `0` when healthy and `1` when any monitored signal fails.

## 1Panel Check

From `/opt/feishu-agent-team`:

```powershell
pwsh ./monitor-services.ps1 `
  -Docker `
  -BaseUrl http://127.0.0.1:8080 `
  -RuntimeEnvPath ./feishu-agent-runtime/.env `
  -AdapterStatusDir ./feishu-channel-adapter/status
```

If PowerShell is not available on the server, use the same signals manually:

```bash
curl -fsS http://127.0.0.1:8080/health
TOKEN=$(grep '^CHANNEL_AUTH_TOKEN=' feishu-agent-runtime/.env | cut -d= -f2-)
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/v1/agents
cat feishu-channel-adapter/status/*.json
docker compose -f docker-compose.full.yml ps
docker compose -f docker-compose.full.yml logs --tail=300 feishu-agent-runtime feishu-channel-adapter
```

## Suggested Alert Rules

Alert when any condition is true:

- Runtime `/health` cannot be reached for 2 consecutive checks.
- `/v1/agents` returns fewer or more than 8 agents.
- Any adapter worker status is not `connected`.
- Any adapter worker status file is older than the expected deployment start time after a restart.
- Runtime logs contain repeated `retrying` or `Runtime returned status=error`.
- Adapter logs contain `worker exited`, `Traceback`, `ERROR`, or `failed`.

## Recovery Order

1. Run `monitor-services.ps1 -Docker` and inspect failures.
2. Check `docker compose -f docker-compose.full.yml ps`.
3. Check `feishu-channel-adapter/status/*.json`.
4. Check runtime and adapter logs.
5. Restart only the adapter if runtime is healthy but workers are disconnected.
6. Restart both services if runtime is unhealthy or the shared config changed.

```bash
docker compose -f docker-compose.full.yml restart feishu-channel-adapter
docker compose -f docker-compose.full.yml restart
```
