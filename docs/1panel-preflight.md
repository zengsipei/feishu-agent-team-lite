# 1Panel Preflight Checklist

Use this checklist before moving the local Agent team services to a 1Panel-managed server.

This checklist enters the **Manual 1Panel Deploy Gate** only after read-only evidence is reviewed, off-host backup/rollback ownership is confirmed, and the user explicitly approves a deployment window. The gate is not remote CI/CD access and does not authorize Agent-run server operations.

## Deployment Goal

Run two long-lived services:

- `feishu-agent-runtime`: agent routing, session store, OpenAI-compatible Chat Completions calls.
- `feishu-channel-adapter`: Feishu Channel SDK WebSocket workers, one worker per Bot App.

The adapter has no HTTP port. Its health is determined by process status, logs, and `status/*.json` worker files.

## Source Package

Deploy from the `services` git repository. The deployment source should include at least these verified baseline commits:

```text
b4da4f1 Harden OpenAI-compatible runtime retries
2342f73 Add local service status checks
08037c4 Add Feishu agent runtime services
```

Tracked files to upload or pull on the server:

```text
docker-compose.full.yml
README.md
1panel-readonly-precheck.sh
1panel-readonly-precheck.ps1
1panel-summarize-precheck.py
monitor-services.ps1
smoke-services.ps1
docs/
feishu-agent-runtime/
feishu-channel-adapter/
```

Do not upload local-only generated directories:

```text
.local-run/
feishu-agent-runtime/.venv/
feishu-channel-adapter/.venv/
feishu-agent-runtime/data/
feishu-channel-adapter/status/
```

## Read-Only Gate Before Deployment

Before opening the 1Panel Compose setup, complete the read-only pre-check and evidence package in [1Panel Read-Only Pre-Check](./1panel-readonly-precheck.md).

This gate is mandatory because the current release status only allows:

```text
1Panel deployment evidence checklist + server read-only pre-check
```

It still forbids:

- formal deployment or release
- 1Panel start/stop/restart/recreate
- `docker compose up`, `down`, `restart`, `pull`, or `build`
- writes to `.env`, `agent-runtime-config.json`, runtime data, adapter status, or server settings
- printing raw secrets, tokens, app secrets, real private Feishu IDs, SQLite files, or raw logs

Run from the server deployment directory. Prefer Bash on Linux/1Panel:

```bash
bash ./1panel-readonly-precheck.sh \
  --root-path . \
  --base-url http://127.0.0.1:8080 \
  --adapter-status-dir ./feishu-channel-adapter/status \
  --port-mode ReportOnly \
  --json
```

Generate the Markdown evidence block from the JSON instead of pasting raw JSON into git:

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

PowerShell fallback:

```powershell
pwsh ./1panel-readonly-precheck.ps1 `
  -RootPath . `
  -BaseUrl http://127.0.0.1:8080 `
  -AdapterStatusDir ./feishu-channel-adapter/status `
  -PortMode ReportOnly `
  -Json
```

Do not continue to `1Panel Compose Setup` until the sanitized evidence package has no blocking failures and the user explicitly opens the Manual 1Panel Deploy Gate. Use [Manual 1Panel Deploy Gate](./1panel-manual-deploy-gate.md) to capture the required human confirmations and post-deploy evidence.

## Secret Files

These files are required on the server but must stay outside git:

```text
/opt/feishu-agent-team/config/agent-runtime-config.json
/opt/feishu-agent-team/feishu-agent-runtime/.env
/opt/feishu-agent-team/feishu-channel-adapter/.env
```

`agent-runtime-config.json` contains Bot App Secrets. Generate it locally from the repository root:

```powershell
python .agents\teams\code-rd-agent-team\build-runtime-config.py
```

Then upload:

```text
.agents/teams/code-rd-agent-team/.runtime/agent-runtime-config.json
```

to:

```text
/opt/feishu-agent-team/config/agent-runtime-config.json
```

## Server Directory

Recommended layout:

```text
/opt/feishu-agent-team/
  docker-compose.full.yml
  config/
    agent-runtime-config.json
  docs/
  feishu-agent-runtime/
    Dockerfile
    requirements.txt
    app/
    .env
    data/
  feishu-channel-adapter/
    Dockerfile
    requirements.txt
    app/
    .env
    status/
  monitor-services.ps1
  smoke-services.ps1
```

Create runtime directories before first start:

```bash
mkdir -p /opt/feishu-agent-team/config
mkdir -p /opt/feishu-agent-team/feishu-agent-runtime/data
mkdir -p /opt/feishu-agent-team/feishu-channel-adapter/status
```

## Environment Files

Generate one shared token:

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

Set the same value in both services:

```env
# feishu-agent-runtime/.env
CHANNEL_AUTH_TOKEN=<same-token>

# feishu-channel-adapter/.env
RUNTIME_AUTH_TOKEN=<same-token>
```

Runtime must use an OpenAI-compatible Chat Completions endpoint:

```env
OPENAI_API_KEY=...
OPENAI_BASE_URL=https://api.openai.com/v1
OPENAI_MODEL=gpt-4.1-mini
OPENAI_TIMEOUT_SECONDS=90
OPENAI_MAX_RETRIES=2
OPENAI_RETRY_BACKOFF_SECONDS=1
```

Adapter production settings:

```env
RUNTIME_BASE_URL=http://feishu-agent-runtime:8080
AGENT_RUNTIME_CONFIG_PATH=/app/config/agent-runtime-config.json
ADAPTER_STATUS_DIR=/app/status
CHANNEL_TRANSPORT=ws
CHANNEL_REQUIRE_MENTION=true
CHANNEL_RESPOND_TO_MENTION_ALL=false
CHANNEL_DROP_SELF_SENT=true
LOG_LEVEL=WARNING
```

## 1Panel Compose Setup

Only start this section after the Manual 1Panel Deploy Gate is opened. A human operator performs the 1Panel action; Release Agent may coordinate approvals and external Feishu/GitHub workflows, but must not operate the server directly. Keep the deploy result in the evidence template from [Manual 1Panel Deploy Gate](./1panel-manual-deploy-gate.md).

In 1Panel:

1. Open `Containers` / `Compose`.
2. Create a Compose app from an existing file.
3. Set workdir to `/opt/feishu-agent-team`.
4. Select `docker-compose.full.yml`.
5. Start the app.

Runtime exposes host port `${HOST_PORT:-8080}`. Adapter does not need a host port.

## Post-Deploy Checks

Runtime health:

```bash
curl http://127.0.0.1:8080/health
```

List agents without printing secrets:

```bash
TOKEN=$(grep '^CHANNEL_AUTH_TOKEN=' feishu-agent-runtime/.env | cut -d= -f2-)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/v1/agents
```

Adapter workers:

```bash
cat feishu-channel-adapter/status/*.json
```

Every worker should have:

```text
status = connected
```

Run the smoke script from the deployment directory if PowerShell is available:

```powershell
pwsh ./smoke-services.ps1 `
  -BaseUrl http://127.0.0.1:8080 `
  -RuntimeEnvPath ./feishu-agent-runtime/.env `
  -AdapterStatusDir ./feishu-channel-adapter/status
```

Run the monitor check:

```powershell
pwsh ./monitor-services.ps1 `
  -Docker `
  -BaseUrl http://127.0.0.1:8080 `
  -RuntimeEnvPath ./feishu-agent-runtime/.env `
  -AdapterStatusDir ./feishu-channel-adapter/status
```

## Final E2E Gate

After 1Panel deploy, run the same real group test in [E2E runbook](./e2e-runbook.md):

- Create or select one project group.
- Add all 8 Bot Apps.
- Send one real `@Agent` test prompt per Agent.
- Confirm each reply `sender.id` equals the expected `app_id`.

Do not consider the server migration complete until all 8 real `@` replies pass.

After the final E2E gate passes, start the first project trial with [Real Project Trial Runbook](./project-trial-runbook.md).

## Backup

Back up these files:

```text
config/agent-runtime-config.json
feishu-agent-runtime/data/runtime.sqlite3
feishu-agent-runtime/data/runtime.sqlite3-wal
feishu-agent-runtime/data/runtime.sqlite3-shm
```

For clean SQLite backups, pause the Compose app or use SQLite online backup tooling.
