# Feishu Channel Adapter

独立运行的飞书 Channel SDK 适配器。它负责和飞书长连接通信，把 SDK 事件标准化后转发给 `feishu-agent-runtime`，再把 runtime 的回复发回飞书。

## 职责边界

本服务负责：

- 为 `agent-runtime-config.json` 中每个 Bot App 创建一个 `FeishuChannel`
- 监听 `message` / `comment` / `cardAction`
- 把事件 POST 到 runtime 的 `/v1/channel/*`
- 对消息事件，把 runtime 返回的 `reply_text` 用 Channel SDK 回复到飞书

本服务不负责：

- Agent 系统提示词执行
- 项目 Session 隔离
- SQLite 持久化
- 模型调用

这些能力在 `feishu-agent-runtime` 中实现。

## 本地运行

```powershell
cd services\feishu-channel-adapter
python -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
Copy-Item .env.example .env
```

准备配置：

```powershell
New-Item -ItemType Directory -Force config | Out-Null
Copy-Item ..\..\.agents\teams\code-rd-agent-team\.runtime\agent-runtime-config.json config\agent-runtime-config.json
```

上面路径在 PowerShell 中不如从仓库根目录执行稳定：

```powershell
New-Item -ItemType Directory -Force services\feishu-channel-adapter\config | Out-Null
Copy-Item .agents\teams\code-rd-agent-team\.runtime\agent-runtime-config.json services\feishu-channel-adapter\config\agent-runtime-config.json
```

启动前先启动 runtime：

```powershell
cd services\feishu-agent-runtime
.\.venv\Scripts\uvicorn app.main:app --host 127.0.0.1 --port 8080
```

再启动 adapter：

```powershell
cd services\feishu-channel-adapter
.\.venv\Scripts\python -m app.main
```

## 配置

核心环境变量：

```env
RUNTIME_BASE_URL=http://127.0.0.1:8080
RUNTIME_AUTH_TOKEN=change-me
AGENT_RUNTIME_CONFIG_PATH=./config/agent-runtime-config.json
CHANNEL_TRANSPORT=ws
CHANNEL_REQUIRE_MENTION=true
LOG_LEVEL=WARNING
```

`RUNTIME_AUTH_TOKEN` 必须和 runtime 的 `CHANNEL_AUTH_TOKEN` 一致。

当前适配器使用 Channel SDK WebSocket 长连接模式。adapter 主进程会为每个 Bot App 启动一个 worker 子进程，隔离 Channel SDK 的 WebSocket event loop。`COMMENT_FETCH_ENABLED=false` 是默认值。打开后适配器会尝试通过 Drive Comment OpenAPI 读取评论正文，这要求每个 Bot App 有对应 Drive 评论读取权限。

## Docker

本服务可以单独构建：

```powershell
cd services\feishu-channel-adapter
docker compose up -d --build
```

更推荐从 `services/docker-compose.full.yml` 启动 runtime + adapter 两个服务。
