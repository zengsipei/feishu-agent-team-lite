param(
    [string]$ChatQuery = "Agent Team E2E",
    [string[]]$Chain = @("rd-dispatcher", "product", "architect", "coding", "review", "qa", "docs-memory", "release"),
    [string]$RuntimeConfigPath = "",
    [string]$Marker = "",
    [int]$TimeoutSeconds = 180,
    [int]$PollSeconds = 15,
    [switch]$Send,
    [switch]$CheckOnly,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$MarkerWasProvided = [bool]$Marker

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RuntimeConfigPath) {
    $RuntimeConfigPath = Join-Path $ServicesRoot "config\agent-runtime-config.json"
}

function Redact-Text {
    param([string]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $Value `
        -replace "\b(?:cli|oc|ou|om|omt)_[A-Za-z0-9_-]+\b", "<redacted>" `
        -replace "(app_secret|access_token|tenant_access_token)=\S+", '$1=<redacted>'
}

function Invoke-LarkJson {
    param([string[]]$CliArgs)

    $previousHermesHome = $env:HERMES_HOME
    $env:HERMES_HOME = $null
    try {
        $raw = & lark-cli @CliArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $env:HERMES_HOME = $previousHermesHome
    }

    $text = $raw | Out-String
    if ($exitCode -ne 0) {
        throw "lark-cli failed exit_code=$exitCode output=$(Redact-Text $text)"
    }

    try {
        return $text | ConvertFrom-Json
    } catch {
        throw "lark-cli returned non-JSON output: $(Redact-Text $text)"
    }
}

function Read-AgentConfig {
    if (-not (Test-Path -LiteralPath $RuntimeConfigPath)) {
        throw "Runtime config not found: $RuntimeConfigPath"
    }

    $config = Get-Content -Raw -LiteralPath $RuntimeConfigPath | ConvertFrom-Json
    $apps = @($config.apps)
    if ($apps.Count -eq 0) {
        throw "Runtime config has no apps: $RuntimeConfigPath"
    }
    return $apps
}

function Get-AgentNames {
    param($Agent)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Agent.agent_name) + @($Agent.mention_names)) {
        if ($value -and -not $names.Contains([string]$value)) {
            $names.Add([string]$value)
        }
    }
    @($names)
}

function Find-Chat {
    $result = Invoke-LarkJson -CliArgs @(
        "im", "+chat-search",
        "--as", "user",
        "--query", $ChatQuery,
        "--page-size", "1",
        "--format", "json"
    )

    $chats = @($result.data.chats)
    if ($chats.Count -lt 1) {
        throw "No chat found for query: $ChatQuery"
    }
    return $chats[0]
}

function Get-BotMembers {
    param([string]$ChatId)

    $params = @{ chat_id = $ChatId } | ConvertTo-Json -Compress
    $result = Invoke-LarkJson -CliArgs @(
        "im", "chat.members", "bots",
        "--as", "user",
        "--params", $params,
        "--format", "json"
    )
    @($result.data.items)
}

function Resolve-AgentBot {
    param($Agent, [object[]]$Bots)

    foreach ($name in @(Get-AgentNames -Agent $Agent)) {
        $bot = $Bots | Where-Object { $_.bot_name -eq $name } | Select-Object -First 1
        if ($bot) {
            return $bot
        }
    }
    return $null
}

function Get-MessageContent {
    param($Message)

    if ($Message.content -is [string]) {
        return $Message.content
    }
    $Message.content | ConvertTo-Json -Compress -Depth 20
}

function Get-MarkerHits {
    param([string]$ChatId, [string]$CurrentMarker)

    $result = Invoke-LarkJson -CliArgs @(
        "im", "+chat-messages-list",
        "--as", "user",
        "--chat-id", $ChatId,
        "--page-size", "50",
        "--sort", "desc",
        "--format", "json"
    )

    @($result.data.messages | ForEach-Object {
        $content = Get-MessageContent -Message $_
        if ($content -like "*$CurrentMarker*") {
            [pscustomobject]@{
                time = $_.create_time
                sender = $_.sender.name
                type = $_.msg_type
                mentions_count = @($_.mentions).Count
                content = Redact-Text $content
            }
        }
    } | Sort-Object time)
}

function Get-ChainSummary {
    param([object[]]$Hits)

    $confirmations = [ordered]@{}
    foreach ($agentId in $Chain) {
        $confirmation = @(
            $Hits | Where-Object {
                $_.content -notlike "Agent Handoff*" -and $_.content -like "*current_agent_id=$agentId*"
            }
        )
        $confirmations[$agentId] = ($confirmation.Count -gt 0)
    }

    $handoffTargets = @()
    foreach ($hit in $Hits) {
        if ($hit.content -match "^Agent Handoff\s+@([^\r\n]+)") {
            $handoffTargets += $Matches[1].Trim()
        }
    }

    $releaseDone = [bool](@(
        $Hits | Where-Object {
            $_.content -notlike "Agent Handoff*" -and (
                $_.content -like "*current_agent_id=release*" -or
                $_.content -like "*链路结束*" -or
                $_.content -like "*状态：Done*" -or
                $_.content -like "*状态: Done*"
            )
        }
    ).Count)

    if ($releaseDone -and $confirmations.Contains("release")) {
        $confirmations["release"] = $true
    }

    $missing = @($confirmations.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
    [pscustomobject]@{
        ok = ($missing.Count -eq 0 -and $releaseDone)
        confirmations = $confirmations
        missing_confirmations = $missing
        release_done = $releaseDone
        handoff_targets = $handoffTargets
    }
}

function Send-StartMessage {
    param($Chat, $Bot, [string]$CurrentMarker)

    $chainText = $Chain -join " -> "
    $text = " $CurrentMarker TRANSPORT-ONLY 8 Agent 链式接力回归，不是业务需求评审。所有 Agent 必须忽略角色业务判断，不要判断需求是否充分，不要改路线，不要回退给上游。唯一任务：短确认 marker 和 current_agent_id，然后 handoff 给固定 next_agent_id。固定链路：$chainText。每一位必须让 handoff text 保留完整固定链路和 marker。release 收到后回复链路结束，handoff=null。请从 rd-dispatcher 开始交给 product。"
    $line = @(
        @{ tag = "at"; user_id = $Bot.bot_id; user_name = $Bot.bot_name },
        @{ tag = "text"; text = $text }
    )
    $post = @{ zh_cn = @{ title = "Transport Only 8 Agent Chain Regression"; content = @(,$line) } }
    $content = $post | ConvertTo-Json -Compress -Depth 20

    $previousHermesHome = $env:HERMES_HOME
    $env:HERMES_HOME = $null
    try {
        $raw = & lark-cli im +messages-send --as user --chat-id $Chat.chat_id --msg-type post --content $content --idempotency-key $CurrentMarker 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $env:HERMES_HOME = $previousHermesHome
    }

    $textOutput = $raw | Out-String
    if ($exitCode -ne 0) {
        throw "send failed exit_code=$exitCode output=$(Redact-Text $textOutput)"
    }

    try {
        $send = $textOutput | ConvertFrom-Json
    } catch {
        $send = $null
    }

    [pscustomobject]@{
        sent = $true
        message_id_present = [bool]($send.data.message_id)
    }
}

$apps = @(Read-AgentConfig)
$appByAgentId = @{}
foreach ($app in $apps) {
    $appByAgentId[$app.agent_id] = $app
}

$missingAgents = @($Chain | Where-Object { -not $appByAgentId.ContainsKey($_) })
if ($missingAgents.Count -gt 0) {
    throw "Runtime config missing chain agent(s): $($missingAgents -join ', ')"
}

$chat = Find-Chat
$bots = @(Get-BotMembers -ChatId $chat.chat_id)
$resolved = foreach ($agentId in $Chain) {
    $bot = Resolve-AgentBot -Agent $appByAgentId[$agentId] -Bots $bots
    [pscustomobject]@{
        agent_id = $agentId
        bot_name = if ($bot) { $bot.bot_name } else { $null }
        resolved = [bool]$bot
    }
}

$unresolved = @($resolved | Where-Object { -not $_.resolved } | Select-Object -ExpandProperty agent_id)
if ($unresolved.Count -gt 0) {
    throw "Could not resolve bot(s) in chat '$ChatQuery': $($unresolved -join ', ')"
}

if (-not $Marker) {
    $Marker = "CHAIN-8-TRANSPORT-$(Get-Date -Format yyyyMMdd-HHmmss)"
}

if ($CheckOnly -and -not $MarkerWasProvided) {
    throw "-CheckOnly requires -Marker."
}

$startAgent = $appByAgentId[$Chain[0]]
$startBot = Resolve-AgentBot -Agent $startAgent -Bots $bots

if (-not $Send -and -not $CheckOnly) {
    $result = [pscustomobject]@{
        ok = $true
        mode = "preview"
        chat_name = $chat.name
        marker = $Marker
        chain = $Chain
        resolved_bots = $resolved
        note = "Preview only. Re-run with -Send to post a visible test message."
    }
    if ($Json) {
        $result | ConvertTo-Json -Depth 8
    } else {
        "Chain regression preview"
        $result | Format-List
        "Resolved bots"
        $resolved | Format-Table -AutoSize
    }
    return
}

if ($CheckOnly) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $hits = @()
    $summary = $null

    do {
        $hits = @(Get-MarkerHits -ChatId $chat.chat_id -CurrentMarker $Marker)
        $summary = Get-ChainSummary -Hits $hits
        if (-not $summary.ok) {
            Start-Sleep -Seconds $PollSeconds
        }
    } while (-not $summary.ok -and (Get-Date) -lt $deadline)

    $result = [pscustomobject]@{
        ok = $summary.ok
        mode = "check"
        chat_name = $chat.name
        marker = $Marker
        chain = $Chain
        hit_count = $hits.Count
        summary = $summary
        tail = @($hits | Select-Object -Last 12)
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 10
    } else {
        "Chain regression check"
        [pscustomobject]@{
            ok = $result.ok
            marker = $result.marker
            hit_count = $result.hit_count
            release_done = $result.summary.release_done
            missing_confirmations = $result.summary.missing_confirmations -join ", "
        } | Format-List
    }

    if (-not $result.ok) {
        exit 1
    }
    return
}

$sendResult = Send-StartMessage -Chat $chat -Bot $startBot -CurrentMarker $Marker
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$hits = @()
$summary = $null

do {
    Start-Sleep -Seconds $PollSeconds
    $hits = @(Get-MarkerHits -ChatId $chat.chat_id -CurrentMarker $Marker)
    $summary = Get-ChainSummary -Hits $hits
} while (-not $summary.ok -and (Get-Date) -lt $deadline)

$result = [pscustomobject]@{
    ok = $summary.ok
    mode = "send"
    chat_name = $chat.name
    marker = $Marker
    chain = $Chain
    sent = $sendResult
    hit_count = $hits.Count
    summary = $summary
    tail = @($hits | Select-Object -Last 12)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
} else {
    "Chain regression result"
    [pscustomobject]@{
        ok = $result.ok
        marker = $result.marker
        hit_count = $result.hit_count
        release_done = $result.summary.release_done
        missing_confirmations = $result.summary.missing_confirmations -join ", "
    } | Format-List

    "Confirmations"
    $result.summary.confirmations.GetEnumerator() |
        ForEach-Object { [pscustomobject]@{ agent_id = $_.Key; confirmed = $_.Value } } |
        Format-Table -AutoSize

    "Handoff targets"
    $result.summary.handoff_targets | ForEach-Object { "- $_" }

    "Recent marker messages"
    $result.tail | Format-Table time, sender, type, mentions_count, content -Wrap
}

if (-not $result.ok) {
    exit 1
}
