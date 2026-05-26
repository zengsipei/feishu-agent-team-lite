param(
    [string]$BaseToken = "",
    [string]$Name = "Agent Team Control Plane MVP",
    [string]$RuntimeConfigPath = "",
    [ValidateSet("bot", "user")]
    [string]$As = "bot",
    [switch]$NoSeedAgents,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

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
        -replace "\b(?:app|cli|oc|ou|om|omt|fld|tbl|rec)_[A-Za-z0-9_-]+\b", "<redacted>" `
        -replace "(/base/)[A-Za-z0-9]+", '$1<redacted>' `
        -replace '("(?:base_token|CONTROL_PLANE_BASE_TOKEN)"\s*:\s*")[^"]+(")', '$1<redacted>$2' `
        -replace "(CONTROL_PLANE_BASE_TOKEN=)\S+", '$1<redacted>' `
        -replace "(clientID=)[A-Za-z0-9_-]+", '$1<redacted>' `
        -replace "(app_secret|access_token|tenant_access_token)=\S+", '$1=<redacted>'
}

function Get-FirstJsonObjectText {
    param([string]$Text)

    $start = $Text.IndexOf("{")
    if ($start -lt 0) {
        return ""
    }

    $depth = 0
    $inString = $false
    $escaped = $false
    for ($index = $start; $index -lt $Text.Length; $index++) {
        $char = $Text[$index]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($char -eq '\') {
                $escaped = $true
            } elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($char -eq '"') {
            $inString = $true
        } elseif ($char -eq "{") {
            $depth++
        } elseif ($char -eq "}") {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($start, $index - $start + 1)
            }
        }
    }

    return ""
}

function Invoke-LarkJson {
    param([string[]]$CliArgs)

    $previousHermesHome = $env:HERMES_HOME
    $env:HERMES_HOME = $null
    Push-Location -LiteralPath $ServicesRoot
    try {
        $raw = & lark-cli @CliArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        $env:HERMES_HOME = $previousHermesHome
    }

    $text = $raw | Out-String
    if ($exitCode -ne 0) {
        throw "lark-cli failed exit_code=$exitCode output=$(Redact-Text $text)"
    }

    $jsonText = Get-FirstJsonObjectText -Text $text
    if (-not $jsonText) {
        throw "lark-cli returned no JSON object: $(Redact-Text $text)"
    }

    try {
        $parsed = $jsonText | ConvertFrom-Json
    } catch {
        throw "lark-cli returned non-JSON output: $(Redact-Text $text)"
    }
    if ($null -ne $parsed.ok -and -not [bool]$parsed.ok) {
        throw "lark-cli returned ok=false output=$(Redact-Text $jsonText)"
    }
    return $parsed
}

function Get-BaseTokenFromResponse {
    param($Response)

    foreach ($value in @(
        $Response.base.token,
        $Response.base.base_token,
        $Response.data.base.token,
        $Response.data.base.base_token,
        $Response.data.base.app_token
    )) {
        if ($value) {
            return [string]$value
        }
    }
    return ""
}

function Get-TableIdFromResponse {
    param($Response)

    foreach ($value in @(
        $Response.table.table_id,
        $Response.table.id,
        $Response.data.table.table_id,
        $Response.data.table.id
    )) {
        if ($value) {
            return [string]$value
        }
    }
    return ""
}

function New-SelectField {
    param(
        [string]$Name,
        [string[]]$Options
    )

    @{
        name = $Name
        type = "select"
        multiple = $false
        options = @($Options | ForEach-Object {
            @{
                name = $_
                hue = "Blue"
                lightness = "Lighter"
            }
        })
    }
}

function New-Table {
    param(
        [string]$CurrentBaseToken,
        [string]$TableName,
        [object[]]$Fields
    )

    $fieldsJson = $Fields | ConvertTo-Json -Compress -Depth 20
    $response = Invoke-LarkJson -CliArgs @(
        "base", "+table-create",
        "--as", $As,
        "--base-token", $CurrentBaseToken,
        "--name", $TableName,
        "--fields", $fieldsJson
    )
    $tableId = Get-TableIdFromResponse -Response $response
    if (-not $tableId) {
        throw "Table '$TableName' created but table id could not be parsed."
    }
    return $tableId
}

function Write-ControlPlaneEnv {
    param(
        [string]$CurrentBaseToken,
        [string]$AgentsTableId,
        [string]$PromptVersionsTableId,
        [string]$AgentRunsTableId
    )

    $runDir = Join-Path $ServicesRoot ".local-run"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $envPath = Join-Path $runDir "control-plane-runtime.env"
    @(
        "CONTROL_PLANE_ENABLED=true",
        "CONTROL_PLANE_BASE_URL=https://open.feishu.cn",
        "CONTROL_PLANE_APP_ID=",
        "CONTROL_PLANE_APP_SECRET=",
        "CONTROL_PLANE_BASE_TOKEN=$CurrentBaseToken",
        "CONTROL_PLANE_AGENTS_TABLE_ID=$AgentsTableId",
        "CONTROL_PLANE_PROMPT_VERSIONS_TABLE_ID=$PromptVersionsTableId",
        "CONTROL_PLANE_AGENT_RUNS_TABLE_ID=$AgentRunsTableId",
        "CONTROL_PLANE_TIMEOUT_SECONDS=20"
    ) | Set-Content -LiteralPath $envPath -Encoding utf8
    return $envPath
}

function Seed-Agents {
    param(
        [string]$CurrentBaseToken,
        [string]$AgentsTableId
    )

    if (-not (Test-Path -LiteralPath $RuntimeConfigPath)) {
        throw "Runtime config not found: $RuntimeConfigPath"
    }

    $config = Get-Content -Raw -LiteralPath $RuntimeConfigPath | ConvertFrom-Json
    $rows = @($config.apps | ForEach-Object {
        ,@(
            $_.agent_id,
            $_.agent_name,
            "Active",
            "local-seed",
            $_.system_prompt,
            $_.source_memory_file,
            $_.resolved_prompt_file
        )
    })

    if ($rows.Count -eq 0) {
        throw "Runtime config contains no apps."
    }

    $payload = @{
        fields = @(
            "Agent ID",
            "Agent Name",
            "Status",
            "Current Prompt Version",
            "Current Prompt",
            "Source Memory File",
            "Resolved Prompt File"
        )
        rows = $rows
    }
    $runDir = Join-Path $ServicesRoot ".local-run"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $seedRelativePath = ".local-run/control-plane-agent-seed.json"
    $seedPath = Join-Path $ServicesRoot $seedRelativePath
    try {
        $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $seedPath -Encoding utf8
        Invoke-LarkJson -CliArgs @(
            "base", "+record-batch-create",
            "--as", $As,
            "--base-token", $CurrentBaseToken,
            "--table-id", $AgentsTableId,
            "--json", "@$seedRelativePath"
        ) | Out-Null
    } finally {
        Remove-Item -LiteralPath $seedPath -Force -ErrorAction SilentlyContinue
    }
    return $rows.Count
}

$createdBase = $false
$currentBaseToken = $BaseToken
if (-not $currentBaseToken) {
    $baseResponse = Invoke-LarkJson -CliArgs @(
        "base", "+base-create",
        "--as", $As,
        "--name", $Name,
        "--time-zone", "Asia/Shanghai"
    )
    $currentBaseToken = Get-BaseTokenFromResponse -Response $baseResponse
    if (-not $currentBaseToken) {
        throw "Base created but base token could not be parsed."
    }
    $createdBase = $true
}

$agentsTableId = New-Table -CurrentBaseToken $currentBaseToken -TableName "Agents" -Fields @(
    @{ name = "Agent ID"; type = "text" },
    @{ name = "Agent Name"; type = "text" },
    (New-SelectField -Name "Status" -Options @("Active", "Disabled")),
    @{ name = "Current Prompt Version"; type = "text" },
    @{ name = "Current Prompt"; type = "text" },
    @{ name = "Source Memory File"; type = "text" },
    @{ name = "Resolved Prompt File"; type = "text" }
)

$promptVersionsTableId = New-Table -CurrentBaseToken $currentBaseToken -TableName "Prompt Versions" -Fields @(
    @{ name = "Title"; type = "text" },
    @{ name = "Agent ID"; type = "text" },
    (New-SelectField -Name "Status" -Options @("Proposed", "Approved", "Rejected", "Active", "Archived")),
    @{ name = "Prompt Text"; type = "text" },
    @{ name = "Change Reason"; type = "text" },
    @{ name = "Source Run ID"; type = "text" }
)

$agentRunsTableId = New-Table -CurrentBaseToken $currentBaseToken -TableName "Agent Runs" -Fields @(
    @{ name = "Run ID"; type = "text" },
    @{ name = "Agent ID"; type = "text" },
    @{ name = "Project ID"; type = "text" },
    @{ name = "Event Type"; type = "text" },
    (New-SelectField -Name "Status" -Options @("ok", "error")),
    @{ name = "Handoff To"; type = "text" },
    @{ name = "Reply Summary"; type = "text" },
    @{ name = "Prompt Source"; type = "text" },
    @{ name = "Prompt Version"; type = "text" }
)

$seededAgents = 0
if (-not $NoSeedAgents) {
    $seededAgents = Seed-Agents -CurrentBaseToken $currentBaseToken -AgentsTableId $agentsTableId
}

$envPath = Write-ControlPlaneEnv `
    -CurrentBaseToken $currentBaseToken `
    -AgentsTableId $agentsTableId `
    -PromptVersionsTableId $promptVersionsTableId `
    -AgentRunsTableId $agentRunsTableId

$result = [pscustomobject]@{
    ok = $true
    identity = $As
    created_base = $createdBase
    base_token_present = [bool]$currentBaseToken
    tables = @("Agents", "Prompt Versions", "Agent Runs")
    table_ids_present = [bool]($agentsTableId -and $promptVersionsTableId -and $agentRunsTableId)
    seeded_agents = $seededAgents
    env_file = $envPath
    note = "Fill CONTROL_PLANE_APP_ID and CONTROL_PLANE_APP_SECRET in the generated gitignored env file before enabling runtime."
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    "Control Plane initialized"
    $result | Format-List
}
