# Feishu Agent Runtime

独立运行的 Agent runtime 服务，用来承接飞书 Channel SDK 明确不覆盖的能力边界。

Channel SDK 负责：

- 飞书 WebSocket / Webhook 通道
- 原始事件解析成 `NormalizedMessage` / `CardActionEvent` / `CommentEvent`
- 去重、过期过滤、单聊/群聊策略
- 回复发送、流式卡片更新、媒体上传、卡片交互

本服务负责：

- 根据 `app_id` / `agent_id` 路由到对应 Agent
- 加载每个 Agent 的系统提示词
- 按项目群、线程、用户和 Agent 隔离 Session
- SQLite 持久化事件、会话和消息
- 通过 OpenAI-compatible Chat Completions API 调用模型
- 统一保存凭据配置，不把 App Secret 写进代码

## 目录

```text
services/feishu-agent-runtime/
  app/                  FastAPI 服务源码
  docs/                 接入和部署文档
  Dockerfile
  docker-compose.yml
  .env.example
```

## API

- `GET /health`
- `GET /v1/agents`
- `POST /v1/channel/messages`
- `POST /v1/channel/comments`
- `POST /v1/channel/card-actions`

除 `/health` 外，若设置了 `CHANNEL_AUTH_TOKEN`，请求必须带：

```http
Authorization: Bearer <CHANNEL_AUTH_TOKEN>
```

## 本地运行

```powershell
cd services/feishu-agent-runtime
python -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
Copy-Item .env.example .env
```

把已生成的运行时配置复制到服务配置目录：

```powershell
New-Item -ItemType Directory -Force config | Out-Null
Copy-Item ..\..\.agents\teams\code-rd-agent-team\.runtime\agent-runtime-config.json config\agent-runtime-config.json
```

上面的命令在 PowerShell 中容易输错。更稳的写法是在仓库根目录执行：

```powershell
New-Item -ItemType Directory -Force services\feishu-agent-runtime\config | Out-Null
Copy-Item .agents\teams\code-rd-agent-team\.runtime\agent-runtime-config.json services\feishu-agent-runtime\config\agent-runtime-config.json
```

启动：

```powershell
cd services/feishu-agent-runtime
.\.venv\Scripts\uvicorn app.main:app --host 127.0.0.1 --port 8080
```

## Docker

```powershell
cd services/feishu-agent-runtime
Copy-Item .env.example .env
New-Item -ItemType Directory -Force config,data | Out-Null
docker compose up -d --build
```

如果从仓库根目录准备 Docker 配置：

```powershell
New-Item -ItemType Directory -Force services\feishu-agent-runtime\config,services\feishu-agent-runtime\data | Out-Null
Copy-Item .agents\teams\code-rd-agent-team\.runtime\agent-runtime-config.json services\feishu-agent-runtime\config\agent-runtime-config.json
```

## 模型后端

runtime 只支持 OpenAI-compatible Chat Completions API，配置读取 `.env`：

```env
OPENAI_API_KEY=...
OPENAI_BASE_URL=https://api.openai.com/v1
OPENAI_MODEL=gpt-4.1-mini
```

## 文档

- [Channel SDK Adapter Contract](docs/channel-sdk-adapter.md)
- [1Panel Deployment](docs/1panel-deploy.md)
- [API Examples](docs/api.md)
