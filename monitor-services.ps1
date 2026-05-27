param(
    [string]$BaseUrl = "http://127.0.0.1:18080",
    [string]$RuntimeEnvPath = "",
    [string]$AdapterStatusDir = "",
    [int]$ExpectedAgentCount = 8,
    [string]$ExpectedAppMapPath = "",
    [int]$LogTail = 300,
    [int]$LogSinceMinutes = 30,
    [switch]$Docker,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RuntimeEnvPath) {
    $RuntimeEnvPath = Join-Path $ServicesRoot "feishu-agent-runtime\.env"
}
if (-not $AdapterStatusDir) {
    if ($Docker) {
        $AdapterStatusDir = Join-Path $ServicesRoot "feishu-channel-adapter\status"
    } else {
        $AdapterStatusDir = Join-Path $ServicesRoot ".local-run\adapter-status"
    }
}

function Invoke-SmokeJson {
    $smokeArgs = @{
        BaseUrl = $BaseUrl
        RuntimeEnvPath = $RuntimeEnvPath
        AdapterStatusDir = $AdapterStatusDir
        ExpectedAgentCount = $ExpectedAgentCount
        Json = $true
    }
    if ($ExpectedAppMapPath) {
        $smokeArgs.ExpectedAppMapPath = $ExpectedAppMapPath
    }
    if ($Docker) {
        $smokeArgs.SkipLocalLogs = $true
    }

    $output = & (Join-Path $ServicesRoot "smoke-services.ps1") @smokeArgs
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    $parsed = $null
    try {
        $parsed = $output | ConvertFrom-Json
    } catch {
        $parsed = [pscustomobject]@{
            ok = $false
            failures = @("Smoke script returned non-JSON output: $($_.Exception.Message)")
            raw = $output
        }
    }
    [pscustomobject]@{
        exit_code = $exitCode
        result = $parsed
    }
}

function Get-DockerProblems {
    param(
        [int]$Tail,
        [int]$SinceMinutes
    )

    $patterns = "ERROR|WARNING|Traceback|Exception|exited|failed|retrying|Runtime returned status=error"
    $services = @("feishu-agent-runtime", "feishu-channel-adapter")
    foreach ($service in $services) {
        $args = @(
            "-f",
            (Join-Path $ServicesRoot "docker-compose.full.yml"),
            "logs",
            "--tail=$Tail"
        )
        if ($SinceMinutes -gt 0) {
            $args += "--since=$($SinceMinutes)m"
        }
        $args += $service
        $logs = docker compose @args 2>$null
        $logs | Select-String -Pattern $patterns | ForEach-Object {
            [pscustomobject]@{
                service = $service
                line = $_.Line
            }
        }
    }
}

function Get-LocalProblems {
    param(
        [int]$Tail,
        [int]$SinceMinutes
    )

    $patterns = "ERROR|WARNING|Traceback|Exception|exited|failed|retrying|Runtime returned status=error"
    $runDir = Join-Path $ServicesRoot ".local-run"
    $threshold = $null
    if ($SinceMinutes -gt 0) {
        $threshold = (Get-Date).AddMinutes(-$SinceMinutes)
    }
    foreach ($name in @("runtime.err.log", "adapter.err.log")) {
        $path = Join-Path $runDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        if ($threshold -and (Get-Item -LiteralPath $path).LastWriteTime -lt $threshold) {
            continue
        }
        Get-Content -Tail $Tail -LiteralPath $path |
            Select-String -Pattern $patterns |
            ForEach-Object {
                [pscustomobject]@{
                    service = $name
                    line = $_.Line
                }
            }
    }
}

function Get-DockerPs {
    if (-not $Docker) {
        return @()
    }
    $rows = docker compose -f (Join-Path $ServicesRoot "docker-compose.full.yml") ps --format json 2>$null
    if (-not $rows) {
        return @()
    }
    @($rows | ForEach-Object { $_ | ConvertFrom-Json })
}

$failures = New-Object System.Collections.Generic.List[string]
$smoke = Invoke-SmokeJson
if ($smoke.exit_code -ne 0) {
    $failures.Add("Smoke check exited with code $($smoke.exit_code)")
}
foreach ($failure in @($smoke.result.failures)) {
    if ($failure) {
        $failures.Add($failure)
    }
}

$containerStatus = @(Get-DockerPs)
if ($Docker) {
    $required = @("feishu-agent-runtime", "feishu-channel-adapter")
    foreach ($name in $required) {
        $container = $containerStatus | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $container) {
            $failures.Add("Missing Docker container $name")
            continue
        }
        if ($container.State -ne "running") {
            $failures.Add("Docker container $name is $($container.State)")
        }
        if ($name -eq "feishu-agent-runtime" -and $container.Health -and $container.Health -ne "healthy") {
            $failures.Add("Runtime container health is $($container.Health)")
        }
    }
}

$logProblems = if ($Docker) {
    @(Get-DockerProblems -Tail $LogTail -SinceMinutes $LogSinceMinutes)
} else {
    @(Get-LocalProblems -Tail $LogTail -SinceMinutes $LogSinceMinutes)
}
if ($logProblems.Count -gt 0) {
    $failures.Add("Recent logs contain $($logProblems.Count) problem line(s)")
}

$result = [pscustomobject]@{
    ok = ($failures.Count -eq 0)
    mode = if ($Docker) { "docker" } else { "local" }
    base_url = $BaseUrl
    runtime_env_path = $RuntimeEnvPath
    adapter_status_dir = $AdapterStatusDir
    smoke = $smoke.result
    docker_containers = $containerStatus
    log_problems = $logProblems
    failures = @($failures)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
} else {
    "Monitor result"
    [pscustomobject]@{
        ok = $result.ok
        mode = $result.mode
        base_url = $result.base_url
        adapter_status_dir = $result.adapter_status_dir
    } | Format-List

    if ($Docker) {
        "Docker containers"
        $containerStatus | Select-Object Name, State, Health, Status, Publishers | Format-Table -AutoSize
    }

    "Agents"
    $result.smoke.agents | Select-Object agent_id, agent_name, app_id | Format-Table -AutoSize

    "Adapter workers"
    $result.smoke.adapter_workers | Select-Object agent_id, app_id, status, updated_at, message | Format-Table -AutoSize

    "Log problems"
    if ($logProblems.Count -gt 0) {
        $logProblems | Format-Table -AutoSize
    } else {
        "No recent problem lines."
    }

    if ($failures.Count -gt 0) {
        "Failures"
        $failures | ForEach-Object { "- $_" }
    } else {
        "Monitor check passed."
    }
}

if ($failures.Count -gt 0) {
    exit 1
}
