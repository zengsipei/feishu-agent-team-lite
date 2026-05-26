# Channel SDK Adapter Contract

这个服务不直接替代飞书 Channel SDK。推荐结构是：

```text
Feishu Channel SDK
  -> 解析事件、执行安全策略、发送/流式更新回复
  -> POST 标准化事件到 feishu-agent-runtime
  <- 收到 runtime 的 reply_text / metadata
  -> 用 Channel SDK 回复飞书消息、评论或卡片
```

## 消息事件

Channel SDK 收到 `NormalizedMessage` 后，适配器 POST：

```http
POST /v1/channel/messages
Authorization: Bearer <CHANNEL_AUTH_TOKEN>
Content-Type: application/json
```

```json
{
  "event_id": "cli_xxx:message:om_xxx",
  "message_id": "om_xxx",
  "app_id": "cli_demo_rd_dispatcher",
  "chat_id": "oc_xxx",
  "chat_type": "group",
  "thread_id": "om_xxx",
  "sender_id": "ou_xxx",
  "sender_name": "User",
  "text": "帮我拆一下这个需求",
  "message_type": "text",
  "project_id": "oc_xxx",
  "raw": {}
}
```

字段约定：

- `app_id`：收到事件的 Bot App ID。runtime 用它找到对应 Agent。
- `agent_id`：可选。如果适配器已知道角色，可以直接传 `rd-dispatcher` 等。
- `project_id`：可选。默认用 `chat_id`，即一个群一个项目。
- `thread_id`：可选。有线程时用于隔离同一项目内不同话题。
- `event_id` 或 `message_id`：用于去重。多 Agent App 可能收到同一条飞书消息，适配器应把 `app_id` 纳入 `event_id`，避免不同 Agent 之间互相误判重复。

返回：

```json
{
  "status": "ok",
  "agent_id": "rd-dispatcher",
  "agent_name": "R&D Dispatcher",
  "session_id": "oc_xxx:oc_xxx:om_xxx:rd-dispatcher",
  "response_id": "42",
  "reply_text": "...",
  "metadata": {
    "project_id": "oc_xxx"
  }
}
```

Channel SDK 适配器应负责把 `reply_text` 发送回飞书。runtime 不直接调用飞书发消息，这样可以继续复用 SDK 的流式卡片、媒体上传和降级策略。

## 文档评论

```http
POST /v1/channel/comments
```

```json
{
  "event_id": "cli_xxx:comment:doccn_xxx:comment_xxx",
  "comment_id": "comment_xxx",
  "app_id": "cli_demo_docs_memory",
  "file_token": "doccn_xxx",
  "file_type": "docx",
  "sender_id": "ou_xxx",
  "text": "把这段整理成决策记录",
  "project_id": "doccn_xxx",
  "raw": {}
}
```

## 卡片交互

```http
POST /v1/channel/card-actions
```

```json
{
  "event_id": "cli_xxx:card:om_xxx:ou_xxx:<action>",
  "app_id": "cli_demo_review",
  "chat_id": "oc_xxx",
  "user_id": "ou_xxx",
  "action": {
    "value": {
      "action": "approve"
    }
  },
  "raw": {}
}
```

当前实现只记录卡片事件。需要复杂卡片状态机时，建议新增独立 action handler。

## 去重边界

Channel SDK 已有去重，本服务也会用 `event_id` / `message_id` 做二次去重。重复事件返回：

```json
{
  "status": "ignored",
  "reply_text": "Duplicate event ignored."
}
```

适配器收到 `ignored` 不应回复用户。
