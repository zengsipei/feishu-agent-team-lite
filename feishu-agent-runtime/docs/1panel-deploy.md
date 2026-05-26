# 1Panel 部署

推荐在 1Panel 中把 `feishu-agent-runtime` 和 `feishu-channel-adapter` 作为一个 Compose 应用部署。runtime 负责 Agent 会话和模型调用，adapter 负责飞书 Channel SDK 长连接和消息回复。

## 1. 准备目录

建议服务器目录：

```text
/opt/feishu-agent-team/
  docker-compose.full.yml
  config/
    agent-runtime-config.json
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
```

`agent-runtime-config.json` 包含 App Secret，必须只放在服务器私有目录，不要提交到 Git。

## 2. 上传配置

本地生成运行时配置后：

```powershell
python .agents\teams\code-rd-agent-team\build-runtime-config.py
```

把以下文件上传到服务器：

```text
.agents/teams/code-rd-agent-team/.runtime/agent-runtime-config.json
```

放到：

```text
/opt/feishu-agent-team/config/agent-runtime-config.json
```

## 3. 配置 .env

复制两个环境变量文件：

```bash
cp feishu-agent-runtime/.env.example feishu-agent-runtime/.env
cp feishu-channel-adapter/.env.example feishu-channel-adapter/.env
```

生成一个强 token：

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

把同一个 token 写入两个文件：

```env
# feishu-agent-runtime/.env
CHANNEL_AUTH_TOKEN=<same-token>

# feishu-channel-adapter/.env
RUNTIME_AUTH_TOKEN=<same-token>
```

runtime 只支持 OpenAI-compatible Chat Completions API，模型配置从 `.env` 读取：

```env
OPENAI_API_KEY=...
OPENAI_BASE_URL=https://api.openai.com/v1
OPENAI_MODEL=gpt-4.1-mini
```

adapter 默认使用 WebSocket Channel SDK：

```env
RUNTIME_BASE_URL=http://feishu-agent-runtime:8080
AGENT_RUNTIME_CONFIG_PATH=/app/config/agent-runtime-config.json
CHANNEL_TRANSPORT=ws
CHANNEL_REQUIRE_MENTION=true
LOG_LEVEL=WARNING
```

adapter 主进程会为每个 Bot App 启动一个 worker 子进程，以隔离 Channel SDK 的 WebSocket event loop。Compose 会把状态目录挂载到 `feishu-channel-adapter/status/`。

## 4. 1Panel 创建 Compose 应用

在 1Panel 中：

1. 进入 `容器` / `Compose`。
2. 选择使用已有 Compose 文件。
3. 工作目录填 `/opt/feishu-agent-team`。
4. Compose 文件选择 `docker-compose.full.yml`。
5. 启动应用。

runtime 默认监听容器内 `8080`，宿主机端口由 Compose 环境变量 `HOST_PORT` 控制。adapter 不需要暴露端口。

## 5. 飞书应用侧配置

每个智能体应用都需要：

- 已发布 Bot 能力，并把 Bot 加入需要服务的项目群。
- 开启事件订阅/长连接能力。
- 订阅消息接收事件。
- 如需处理文档评论，订阅云文档评论事件，并补齐 Drive 评论读取权限。
- 如需处理卡片动作，开启对应卡片交互事件。

一个飞书群就是一个项目；同一批 Agent 可以分别加入多个项目群。

## 6. 健康检查

runtime：

```bash
curl http://127.0.0.1:8080/health
```

列出 Agent：

```bash
curl -H "Authorization: Bearer $CHANNEL_AUTH_TOKEN" \
  http://127.0.0.1:8080/v1/agents
```

adapter 没有 HTTP 端口，检查容器日志：

```bash
docker logs feishu-channel-adapter --tail 100
```

查看每个 WebSocket worker 的脱敏状态：

```bash
cat feishu-channel-adapter/status/*.json
```

`status=connected` 表示对应智能体应用的 Channel SDK WebSocket 已连接。

## 7. 数据备份

需要备份：

- `config/agent-runtime-config.json`
- `feishu-agent-runtime/data/runtime.sqlite3`

SQLite 使用 WAL，运行时还可能出现：

- `feishu-agent-runtime/data/runtime.sqlite3-wal`
- `feishu-agent-runtime/data/runtime.sqlite3-shm`

备份时建议先暂停容器，或用 SQLite 在线备份方式。
