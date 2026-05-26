param(
    [string]$RuntimeBaseUrl = "http://127.0.0.1:8080",
    [string]$ComposeFile = "",
    [string]$ChatQuery = "Agent Team E2E",
    [int]$ExpectedAgentCount = 8,
    [int]$ChainTimeoutSeconds = 210,
    [int]$PollSeconds = 15,
    [string]$CheckMarker = "",
    [switch]$SkipChain,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$CheckMarkerWasProvided = $PSBoundParameters.ContainsKey("CheckMarker")

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ComposeFile) {
    $ComposeFile = Join-Path $ServicesRoot "docker-compose.full.yml"
}
if ($null -eq $CheckMarker) {
    $CheckMarker = ""
}
$CheckMarker = $CheckMarker.Trim()

$RuntimeDir = Join-Path $ServicesRoot "feishu-agent-runtime"
$AdapterDir = Join-Path $ServicesRoot "feishu-channel-adapter"
$RuntimePython = Join-Path $RuntimeDir ".venv\Scripts\python.exe"
$AdapterPython = Join-Path $AdapterDir ".venv\Scripts\python.exe"
$ChainScript = Join-Path $ServicesRoot "run-chain-regression.ps1"
$SmokeScript = Join-Path $ServicesRoot "smoke-services.ps1"
$DockerAdapterStatusDir = Join-Path $AdapterDir "status"

function Redact-Text {
    param([string]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $Value `
        -replace "\b(?:cli|oc|ou|om|omt)_[A-Za-z0-9_-]+\b", "<redacted>" `
        -replace "(app_secret|access_token|tenant_access_token)=\S+", '$1=<redacted>'
}

function Get-OutputTail {
    param(
        [string]$Text,
        [int]$Lines = 12
    )

    if (-not $Text) {
        return ""
    }
    $items = @($Text -split "\r?\n" | Where-Object { $_ })
    if ($items.Count -le $Lines) {
        return ($items -join "`n")
    }
    ($items | Select-Object -Last $Lines) -join "`n"
}

function Invoke-ProcessStep {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $started = Get-Date
    $output = ""
    $exitCode = $null
    try {
        Push-Location -LiteralPath $WorkingDirectory
        try {
            $raw = & $FilePath @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $output = Redact-Text ($raw | Out-String)
    } catch {
        $output = Redact-Text $_.Exception.Message
        $exitCode = 1
    }

    [pscustomobject]@{
        name = $Name
        ok = ($exitCode -eq 0)
        exit_code = $exitCode
        duration_seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        output_tail = Get-OutputTail -Text $output
    }
}

function Invoke-CheckedStep {
    param(
        [string]$Name,
        [scriptblock]$ScriptBlock
    )

    $started = Get-Date
    try {
        $detail = & $ScriptBlock
        [pscustomobject]@{
            name = $Name
            ok = $true
            duration_seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
            detail = $detail
            error = $null
        }
    } catch {
        [pscustomobject]@{
            name = $Name
            ok = $false
            duration_seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
            detail = $null
            error = Redact-Text $_.Exception.Message
        }
    }
}

function Invoke-Compose {
    param([string[]]$Arguments)

    $raw = & docker compose -f $ComposeFile @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = Redact-Text ($raw | Out-String)
    if ($exitCode -ne 0) {
        throw "docker compose failed exit_code=$exitCode output=$(Get-OutputTail -Text $text)"
    }
    $text
}

function Get-ContainerState {
    param(
        [string]$Name,
        [bool]$RequireHealthy
    )

    $raw = & docker inspect $Name --format "{{json .State}}" 2>&1
    $exitCode = $LASTEXITCODE
    $text = Redact-Text ($raw | Out-String)
    if ($exitCode -ne 0) {
        throw "docker inspect $Name failed exit_code=$exitCode output=$(Get-OutputTail -Text $text)"
    }

    $state = $text | ConvertFrom-Json
    $health = if ($state.Health) { $state.Health.Status } else { $null }
    $ok = ($state.Status -eq "running")
    if ($RequireHealthy) {
        $ok = $ok -and ($health -eq "healthy")
    }

    [pscustomobject]@{
        name = $Name
        status = $state.Status
        health = $health
        ok = $ok
    }
}

function Invoke-HealthCheck {
    $health = Invoke-RestMethod -Uri "$RuntimeBaseUrl/health" -Method Get -TimeoutSec 10
    [pscustomobject]@{
        url = "$RuntimeBaseUrl/health"
        ok = [bool]$health.ok
    }
}

function Invoke-ChainGate {
    $powerShellExe = (Get-Process -Id $PID).Path
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $ChainScript,
        "-Json",
        "-ChatQuery",
        $ChatQuery,
        "-TimeoutSeconds",
        "$ChainTimeoutSeconds",
        "-PollSeconds",
        "$PollSeconds"
    )
    if ($CheckMarker) {
        $arguments += @("-CheckOnly", "-Marker", $CheckMarker)
    } else {
        $arguments += @("-Send")
    }

    $raw = & $powerShellExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = Redact-Text ($raw | Out-String)
    $parsed = $null
    try {
        $parsed = $text | ConvertFrom-Json
    } catch {
        throw "chain regression returned non-JSON output exit_code=$exitCode output=$(Get-OutputTail -Text $text)"
    }

    [pscustomobject]@{
        ok = ($exitCode -eq 0 -and [bool]$parsed.ok)
        exit_code = $exitCode
        mode = if ($CheckMarker) { "check" } else { "send" }
        marker = $parsed.marker
        hit_count = $parsed.hit_count
        release_done = $parsed.summary.release_done
        missing_confirmations = @($parsed.summary.missing_confirmations)
    }
}

$failures = New-Object System.Collections.Generic.List[string]
$steps = New-Object System.Collections.Generic.List[object]

if ($CheckMarkerWasProvided -and -not $CheckMarker) {
    $failures.Add("-CheckMarker requires a non-empty marker.")
} elseif ($SkipChain -and $CheckMarker) {
    $failures.Add("-SkipChain and -CheckMarker cannot be used together.")
}

foreach ($path in @($RuntimePython, $AdapterPython, $ChainScript, $SmokeScript, $ComposeFile)) {
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("Required path not found: $path")
    }
}

if ($failures.Count -eq 0) {
    $steps.Add((Invoke-ProcessStep -Name "runtime unit tests" -FilePath $RuntimePython -Arguments @("-m", "unittest", "discover", "-s", "tests") -WorkingDirectory $RuntimeDir))
    $steps.Add((Invoke-ProcessStep -Name "adapter unit tests" -FilePath $AdapterPython -Arguments @("-m", "unittest", "discover", "-s", "tests") -WorkingDirectory $AdapterDir))
    $steps.Add((Invoke-ProcessStep -Name "runtime compile" -FilePath $RuntimePython -Arguments @("-m", "compileall", "-q", "app", "tests") -WorkingDirectory $RuntimeDir))
    $steps.Add((Invoke-ProcessStep -Name "adapter compile" -FilePath $AdapterPython -Arguments @("-m", "compileall", "-q", "app", "tests") -WorkingDirectory $AdapterDir))

    $steps.Add((Invoke-CheckedStep -Name "compose config" -ScriptBlock {
        Invoke-Compose -Arguments @("config", "--quiet") | Out-Null
        [pscustomobject]@{ compose_file = $ComposeFile }
    }))

    $steps.Add((Invoke-CheckedStep -Name "docker containers" -ScriptBlock {
        $runtime = Get-ContainerState -Name "feishu-agent-runtime" -RequireHealthy $true
        $adapter = Get-ContainerState -Name "feishu-channel-adapter" -RequireHealthy $false
        [pscustomobject]@{
            runtime = $runtime
            adapter = $adapter
        }
    }))

    $steps.Add((Invoke-CheckedStep -Name "runtime health" -ScriptBlock {
        Invoke-HealthCheck
    }))

    $steps.Add((Invoke-ProcessStep -Name "runtime and adapter smoke" -FilePath (Get-Process -Id $PID).Path -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $SmokeScript,
        "-BaseUrl",
        $RuntimeBaseUrl,
        "-AdapterStatusDir",
        $DockerAdapterStatusDir,
        "-ExpectedAgentCount",
        "$ExpectedAgentCount",
        "-SkipLocalLogs",
        "-Json"
    ) -WorkingDirectory $ServicesRoot))

    if (-not $SkipChain) {
        $steps.Add((Invoke-CheckedStep -Name "8-agent chain regression" -ScriptBlock {
            Invoke-ChainGate
        }))
    }
}

foreach ($step in $steps) {
    if (-not $step.ok) {
        $message = if ($step.error) { $step.error } elseif ($step.output_tail) { $step.output_tail } else { "failed" }
        $failures.Add("$($step.name): $message")
        continue
    }

    if ($step.name -eq "docker containers") {
        if (-not $step.detail.runtime.ok) {
            $step.ok = $false
            $failures.Add("feishu-agent-runtime is not healthy: status=$($step.detail.runtime.status) health=$($step.detail.runtime.health)")
        }
        if (-not $step.detail.adapter.ok) {
            $step.ok = $false
            $failures.Add("feishu-channel-adapter is not running: status=$($step.detail.adapter.status)")
        }
    }
    if ($step.name -eq "runtime health" -and -not $step.detail.ok) {
        $step.ok = $false
        $failures.Add("runtime /health returned ok=false")
    }
    if ($step.name -eq "8-agent chain regression" -and -not $step.detail.ok) {
        $step.ok = $false
        $missing = $step.detail.missing_confirmations -join ", "
        $failures.Add("8-agent chain regression failed marker=$($step.detail.marker) missing=$missing release_done=$($step.detail.release_done)")
    }
}

$chain = $steps | Where-Object { $_.name -eq "8-agent chain regression" } | Select-Object -First 1
$chainMarker = $null
if ($chain -and $chain.detail) {
    $chainMarker = $chain.detail.marker
}
$failureItems = @($failures.ToArray())
$stepItems = @($steps.ToArray())
$result = [ordered]@{
    ok = ($failures.Count -eq 0)
    runtime_base_url = $RuntimeBaseUrl
    expected_agent_count = $ExpectedAgentCount
    chain_marker = $chainMarker
    failures = $failureItems
    steps = $stepItems
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
} else {
    "Local Release Gate"
    [pscustomobject]@{
        ok = $result.ok
        runtime_base_url = $result.runtime_base_url
        chain_marker = $result.chain_marker
    } | Format-List

    "Steps"
    $stepItems | ForEach-Object {
        [pscustomobject]@{
            name = $_.name
            ok = $_.ok
            seconds = $_.duration_seconds
        }
    } | Format-Table -AutoSize

    if ($chain -and $chain.detail) {
        "Chain"
        [pscustomobject]@{
            marker = $chain.detail.marker
            mode = $chain.detail.mode
            hit_count = $chain.detail.hit_count
            release_done = $chain.detail.release_done
            missing = $chain.detail.missing_confirmations -join ", "
        } | Format-List
    }

    if ($failures.Count -gt 0) {
        "Failures"
        $failures | ForEach-Object { "- $_" }
    } else {
        "Gate passed."
    }
}

if ($failures.Count -gt 0) {
    exit 1
}
