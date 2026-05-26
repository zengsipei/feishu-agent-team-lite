param(
    [string]$BaseUrl = "http://127.0.0.1:18080",
    [string]$RuntimeEnvPath = "",
    [string]$AdapterStatusDir = "",
    [int]$ExpectedAgentCount = 8,
    [string]$ExpectedAppMapPath = "",
    [int]$Tail = 80,
    [switch]$SkipAdapter,
    [switch]$SkipLocalLogs,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RuntimeEnvPath) {
    $RuntimeEnvPath = Join-Path $ServicesRoot "feishu-agent-runtime\.env"
}
if (-not $AdapterStatusDir) {
    $localStatus = Join-Path $ServicesRoot ".local-run\adapter-status"
    $composeStatus = Join-Path $ServicesRoot "feishu-channel-adapter\status"
    if (Test-Path -LiteralPath $localStatus) {
        $AdapterStatusDir = $localStatus
    } else {
        $AdapterStatusDir = $composeStatus
    }
}

function Get-DotEnvValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Env file not found: $Path"
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed -match "^\s*([^=]+?)\s*=\s*(.*)\s*$") {
            $key = $Matches[1].Trim()
            if ($key -ne $Name) {
                continue
            }
            $value = $Matches[2].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return $null
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

function Read-AdapterStatuses {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    @(Get-ChildItem -LiteralPath $Path -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_
        try {
            Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
        } catch {
            [pscustomobject]@{
                agent_id = $file.BaseName
                status = "unreadable"
                message = $_.Exception.Message
            }
        }
    } | Sort-Object agent_id)
}

function Get-RecentProblems {
    param([int]$LineCount)

    $patterns = "ERROR|WARNING|Traceback|Exception|exited|failed"
    $runDir = Join-Path $ServicesRoot ".local-run"
    foreach ($name in @("runtime.err.log", "adapter.err.log")) {
        $path = Join-Path $runDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        Get-Content -Tail $LineCount -LiteralPath $path |
            Select-String -Pattern $patterns |
            ForEach-Object {
                [pscustomobject]@{
                    log = $name
                    line = $_.Line
                }
            }
    }
}

$expectedApps = @()
if ($ExpectedAppMapPath) {
    if (-not (Test-Path -LiteralPath $ExpectedAppMapPath)) {
        throw "Expected app map file not found: $ExpectedAppMapPath"
    }
    $expectedApps = @(Get-Content -Raw -LiteralPath $ExpectedAppMapPath | ConvertFrom-Json)
}

$failures = New-Object System.Collections.Generic.List[string]
$token = Get-DotEnvValue -Path $RuntimeEnvPath -Name "CHANNEL_AUTH_TOKEN"
if (-not $token -or $token -eq "change-me") {
    $failures.Add("CHANNEL_AUTH_TOKEN is missing or still change-me in $RuntimeEnvPath")
}

$health = $null
try {
    $health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get -TimeoutSec 10
    if (-not $health.ok) {
        $failures.Add("Runtime /health did not return ok=true")
    }
} catch {
    $failures.Add("Runtime /health request failed: $($_.Exception.Message)")
}

$agents = @()
if ($token) {
    try {
        $headers = @{ Authorization = "Bearer $token" }
        $rawAgents = Invoke-RestMethod -Uri "$BaseUrl/v1/agents" -Headers $headers -Method Get -TimeoutSec 10
        $agents = @($rawAgents | ForEach-Object { $_ })
    } catch {
        $failures.Add("Runtime /v1/agents request failed: $($_.Exception.Message)")
    }
}

if ($agents.Count -ne $ExpectedAgentCount) {
    $failures.Add("Expected $ExpectedAgentCount agents, got $($agents.Count)")
}

$duplicateAgentIds = @($agents | Group-Object agent_id | Where-Object { $_.Count -gt 1 })
if ($duplicateAgentIds.Count -gt 0) {
    $failures.Add("Duplicate agent_id values: $($duplicateAgentIds.Name -join ', ')")
}

$duplicateAppIds = @($agents | Group-Object app_id | Where-Object { $_.Count -gt 1 })
if ($duplicateAppIds.Count -gt 0) {
    $failures.Add("Duplicate app_id values: $($duplicateAppIds.Name -join ', ')")
}

if ($expectedApps.Count -gt 0) {
    foreach ($expected in $expectedApps) {
        $actual = $agents | Where-Object { $_.agent_id -eq $expected.agent_id } | Select-Object -First 1
        if (-not $actual) {
            $failures.Add("Missing expected agent_id=$($expected.agent_id)")
            continue
        }
        if ($actual.app_id -ne $expected.app_id) {
            $failures.Add("agent_id=$($expected.agent_id) app_id mismatch: expected $($expected.app_id), got $($actual.app_id)")
        }
    }
}

$workers = @()
if (-not $SkipAdapter) {
    $workers = @(Read-AdapterStatuses -Path $AdapterStatusDir)
    if ($workers.Count -ne $ExpectedAgentCount) {
        $failures.Add("Expected $ExpectedAgentCount adapter workers, got $($workers.Count) from $AdapterStatusDir")
    }
    foreach ($worker in $workers) {
        if ($worker.status -ne "connected") {
            $failures.Add("Adapter worker agent_id=$($worker.agent_id) status=$($worker.status)")
        }
    }
}

$recentProblems = @()
if (-not $SkipLocalLogs) {
    $recentProblems = @(Get-RecentProblems -LineCount $Tail)
}
if ($recentProblems.Count -gt 0) {
    $failures.Add("Recent local stderr logs contain $($recentProblems.Count) problem line(s)")
}

$safeFailures = @($failures | ForEach-Object { Redact-Text $_ })
$safeRecentProblems = @($recentProblems | ForEach-Object {
    [pscustomobject]@{
        log = $_.log
        line = Redact-Text $_.line
    }
})
$result = [pscustomobject]@{
    ok = ($failures.Count -eq 0)
    base_url = $BaseUrl
    runtime_env_path = $RuntimeEnvPath
    adapter_status_dir = if ($SkipAdapter) { $null } else { $AdapterStatusDir }
    expected_app_map_path = if ($ExpectedAppMapPath) { $ExpectedAppMapPath } else { $null }
    health = $health
    agents = @($agents | Sort-Object agent_id | ForEach-Object {
        [pscustomobject]@{
            agent_id = $_.agent_id
            agent_name = $_.agent_name
            app_id = if ($_.app_id) { "<redacted>" } else { $null }
            source_memory_file = $_.source_memory_file
            resolved_prompt_file = $_.resolved_prompt_file
        }
    })
    adapter_workers = @($workers | Sort-Object agent_id | ForEach-Object {
        [pscustomobject]@{
            agent_id = $_.agent_id
            agent_name = $_.agent_name
            app_id = if ($_.app_id) { "<redacted>" } else { $null }
            status = $_.status
            pid = $_.pid
            updated_at = $_.updated_at
            message = Redact-Text $_.message
        }
    })
    recent_problems = $safeRecentProblems
    failures = $safeFailures
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    "Runtime health"
    $result.health | Format-List
    "Agents"
    $result.agents | Format-Table -AutoSize
    if (-not $SkipAdapter) {
        "Adapter workers"
        $result.adapter_workers | Format-Table -AutoSize
    }
    "Recent problems"
    if ($SkipLocalLogs) {
        "Skipped local stderr log scan."
    } elseif ($safeRecentProblems.Count -gt 0) {
        $safeRecentProblems | Format-Table -AutoSize
    } else {
        "No recent problem lines in local stderr logs."
    }
    if ($failures.Count -gt 0) {
        "Failures"
        $failures | ForEach-Object { "- $_" }
    } else {
        "Smoke check passed."
    }
}

if ($failures.Count -gt 0) {
    exit 1
}
