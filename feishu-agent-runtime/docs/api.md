# API Examples

## Health

```bash
curl http://127.0.0.1:8080/health
```

## List Agents

```bash
curl -H "Authorization: Bearer $CHANNEL_AUTH_TOKEN" \
  http://127.0.0.1:8080/v1/agents
```

## Message

```bash
curl -X POST http://127.0.0.1:8080/v1/channel/messages \
  -H "Authorization: Bearer $CHANNEL_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "event_id": "evt_demo_001",
    "message_id": "om_demo_001",
    "app_id": "cli_demo_rd_dispatcher",
    "chat_id": "oc_demo_project",
    "chat_type": "group",
    "thread_id": "om_demo_thread",
    "sender_id": "ou_demo_user",
    "sender_name": "Demo User",
    "text": "帮我把这个想法拆成研发任务",
    "message_type": "text"
  }'
```

## Comment

```bash
curl -X POST http://127.0.0.1:8080/v1/channel/comments \
  -H "Authorization: Bearer $CHANNEL_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "event_id": "evt_comment_001",
    "comment_id": "comment_demo_001",
    "app_id": "cli_demo_docs_memory",
    "file_token": "doc_demo",
    "file_type": "docx",
    "sender_id": "ou_demo_user",
    "text": "把这里沉淀成项目记忆"
  }'
```

## Card Action

```bash
curl -X POST http://127.0.0.1:8080/v1/channel/card-actions \
  -H "Authorization: Bearer $CHANNEL_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "event_id": "evt_card_001",
    "app_id": "cli_demo_review",
    "chat_id": "oc_demo_project",
    "user_id": "ou_demo_user",
    "action": {
      "value": {
        "action": "approve"
      }
    }
  }'
```
