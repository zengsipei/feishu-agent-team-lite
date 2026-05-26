param(
    [string]$BaseUrl = "http://127.0.0.1:8080",
    [string]$Token = "change-me"
)

$headers = @{
    Authorization = "Bearer $Token"
}

Invoke-RestMethod "$BaseUrl/health"
Invoke-RestMethod "$BaseUrl/v1/agents" -Headers $headers

$body = @{
    event_id = "evt_smoke_$(Get-Date -Format yyyyMMddHHmmss)"
    message_id = "om_smoke"
    app_id = "cli_demo_rd_dispatcher"
    chat_id = "oc_smoke_project"
    chat_type = "group"
    sender_id = "ou_smoke_user"
    sender_name = "Smoke User"
    text = "帮我验证 runtime 服务链路"
    message_type = "text"
} | ConvertTo-Json -Depth 8

Invoke-RestMethod "$BaseUrl/v1/channel/messages" -Method Post -Headers ($headers + @{ "Content-Type" = "application/json" }) -Body $body
