# Feishu Agent Team Services

这里包含两个长期运行服务：

- `feishu-agent-runtime`：Agent 执行、路由、会话隔离、持久化、模型调用。
- `feishu-channel-adapter`：飞书 Channel SDK 长连接、事件标准化、回复发送。

推荐部署形态：

```text
Feishu
  <-> feishu-channel-adapter
  <-> feishu-agent-runtime
  <-> model backend
```

## 共享配置

两个服务共用同一份：

```text
services/config/agent-runtime-config.json
```

该文件包含 App Secret，不要提交到 Git，也不要放到公开目录。

`agent-runtime-config.json` 的来源链路：

1. 在部署前用 `lark-cli`/团队注册脚本创建或选择 8 个飞书 Bot App，并获取每个应用的 `client_id` / `client_secret`。
2. 凭证先落到 `.agents/teams/code-rd-agent-team/.runtime/app-credentials.json`。
3. 再运行 `.agents/teams/code-rd-agent-team/build-runtime-config.py`，把 App 凭证、`agents/*.md` 系统提示词和通用协议合并为 `.runtime/agent-runtime-config.json`。
4. 服务容器只读取生成后的 `agent-runtime-config.json`，容器内不需要安装或登录 `lark-cli`。

生成运行配置：

```powershell
python .agents\teams\code-rd-agent-team\build-runtime-config.py
```

从仓库根目录复制：

```powershell
New-Item -ItemType Directory -Force services\config | Out-Null
Copy-Item .agents\teams\code-rd-agent-team\.runtime\agent-runtime-config.json services\config\agent-runtime-config.json
```

脱敏结构示例：

```json
{
  "generated_at": "2026-05-26T08:00:00+08:00",
  "note": "Contains app_secret values. Do not commit or share this file.",
  "apps": [
    {
      "agent_id": "rd-dispatcher",
      "agent_name": "R&D Dispatcher",
      "app_id": "cli_fake_rd_dispatcher",
      "app_secret": "fake-secret-from-lark-cli",
      "source_memory_file": "agents/00-rd-dispatcher.md",
      "resolved_prompt_file": ".runtime/resolved-prompts/rd-dispatcher.md",
      "system_prompt": "# R&D Dispatcher\n\n...resolved prompt..."
    },
    {
      "agent_id": "coding",
      "agent_name": "Coding Agent",
      "app_id": "cli_fake_coding",
      "app_secret": "fake-secret-from-lark-cli",
      "source_memory_file": "agents/03-coding-agent.md",
      "resolved_prompt_file": ".runtime/resolved-prompts/coding.md",
      "system_prompt": "# Coding Agent\n\n...resolved prompt..."
    }
  ]
}
```

真实文件应包含 8 个 `apps[]` 项，每个 `app_id` / `app_secret` 对应一个独立飞书 Bot App。

## 一次启动两个服务

```powershell
Copy-Item services\feishu-agent-runtime\.env.example services\feishu-agent-runtime\.env
Copy-Item services\feishu-channel-adapter\.env.example services\feishu-channel-adapter\.env
```

确保两个 `.env` 中的 token 一致：

```env
# services/feishu-agent-runtime/.env
CHANNEL_AUTH_TOKEN=<same-token>

# services/feishu-channel-adapter/.env
RUNTIME_AUTH_TOKEN=<same-token>
```

启动：

```powershell
cd services
docker compose -f docker-compose.full.yml up -d --build
```

## 本地启动

不走 Docker 时，两个服务都只读取各自目录下的 `.env`。

```powershell
cd services
.\start-local-services.ps1
```

确认 runtime 通过后，再启动 adapter：

```powershell
.\stop-local-services.ps1
.\start-local-services.ps1 -Adapter
```

日志和 pid 文件位于：

```text
services/.local-run/
```

查看当前状态：

```powershell
.\status-local-services.ps1
```

输出 JSON：

```powershell
.\status-local-services.ps1 -Json
```

运行 smoke 检查：

```powershell
.\smoke-services.ps1
```

运行最小监控检查：

```powershell
.\monitor-services.ps1
```

直接看日志：

```powershell
Get-Content -Tail 100 .\.local-run\runtime.err.log
Get-Content -Tail 100 .\.local-run\adapter.err.log
Get-Content -Wait .\.local-run\adapter.err.log
```

adapter 是 WebSocket 长连接服务，没有 HTTP 状态端口。本地状态由 `adapter-status/*.json` 脱敏状态文件、进程树和 stderr 日志共同确认。

停止：

```powershell
.\stop-local-services.ps1
```

## 验收与部署文档

- [Agent Team E2E Runbook](docs/e2e-runbook.md)：真实飞书群 `@Agent` 闭环测试、8 个 Bot `app_id` 映射和验收记录。
- [1Panel Read-Only Pre-Check](docs/1panel-readonly-precheck.md)：正式部署前的服务器只读检查、Bash/PowerShell 脱敏证据包模板、Release gate 和禁止操作。
- [1Panel Read-Only Evidence](docs/1panel-readonly-evidence.md)：当前阶段的脱敏证据包、本地只读验证结果和目标服务器待确认项。
- [1Panel Preflight Checklist](docs/1panel-preflight.md)：上传清单、私密配置、Compose 启动和服务器验收步骤。
- [Minimal Monitoring](docs/monitoring.md)：runtime、adapter worker、Docker 容器和日志信号的最小监控。
- [Real Project Trial Runbook](docs/project-trial-runbook.md)：把 8 个 Agent 放进真实项目群后的首轮试运行流程。
- [Runtime 1Panel Deploy](feishu-agent-runtime/docs/1panel-deploy.md)：更详细的 runtime/adapter Compose 部署说明。
