param(
    [int]$RuntimePort = 18080,
    [int]$Tail = 40,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunDir = Join-Path $ServicesRoot ".local-run"
$StatusDir = Join-Path $RunDir "adapter-status"

function Get-PidProcess {
    param([string]$Name)

    $pidFile = Join-Path $RunDir "$Name.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) {
        return $null
    }
    $processId = [int](Get-Content -Raw $pidFile)
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    [pscustomobject]@{
        pid = $processId
        running = [bool]$process
        started_at = if ($process) { $process.StartTime } else { $null }
    }
}

function Get-DescendantProcesses {
    param([int]$RootProcessId)

    function Walk {
        param([int]$NodeProcessId, [int]$Depth)
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$NodeProcessId" -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            [pscustomobject]@{
                depth = $Depth
                pid = [int]$child.ProcessId
                parent_pid = [int]$child.ParentProcessId
                name = $child.Name
                app_main = ($child.CommandLine -like "*-m app.main*")
            }
            Walk -NodeProcessId ([int]$child.ProcessId) -Depth ($Depth + 1)
        }
    }
    @(Walk -NodeProcessId $RootProcessId -Depth 1)
}

function Read-WorkerStatuses {
    if (-not (Test-Path -LiteralPath $StatusDir)) {
        return @()
    }
    Get-ChildItem -LiteralPath $StatusDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        ForEach-Object {
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
        } |
        Sort-Object agent_id
}

function Get-RecentProblems {
    $patterns = "ERROR|WARNING|Traceback|Exception|exited|failed|failed"
    foreach ($name in @("runtime.err.log", "adapter.err.log")) {
        $path = Join-Path $RunDir $name
        if (Test-Path -LiteralPath $path) {
            Get-Content -Tail $Tail -LiteralPath $path |
                Select-String -Pattern $patterns |
                ForEach-Object {
                    [pscustomobject]@{
                        log = $name
                        line = $_.Line
                    }
                }
        }
    }
}

$runtime = Get-PidProcess -Name "runtime"
$adapter = Get-PidProcess -Name "adapter"

$runtimeHealth = $null
try {
    $runtimeHealth = Invoke-RestMethod -Uri "http://127.0.0.1:$RuntimePort/health" -Method Get -TimeoutSec 5
} catch {
    $runtimeHealth = [pscustomobject]@{
        ok = $false
        error = $_.Exception.Message
    }
}

$adapterTree = @()
if ($adapter -and $adapter.running) {
    $adapterTree = @(Get-DescendantProcesses -RootProcessId $adapter.pid)
}
$workers = @(Read-WorkerStatuses)
$problems = @(Get-RecentProblems)

$result = [pscustomobject]@{
    runtime = $runtime
    runtime_health = $runtimeHealth
    adapter = $adapter
    adapter_descendant_processes = $adapterTree.Count
    adapter_worker_statuses = $workers
    recent_problems = $problems
    logs = [pscustomobject]@{
        runtime_stdout = Join-Path $RunDir "runtime.out.log"
        runtime_stderr = Join-Path $RunDir "runtime.err.log"
        adapter_stdout = Join-Path $RunDir "adapter.out.log"
        adapter_stderr = Join-Path $RunDir "adapter.err.log"
        adapter_status_dir = $StatusDir
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
    return
}

"Runtime"
$result.runtime | Format-List
"Runtime health"
$result.runtime_health | Format-List
"Adapter"
$result.adapter | Format-List
"Adapter worker statuses"
if ($workers.Count -gt 0) {
    $workers | Select-Object agent_id,agent_name,status,pid,updated_at,message | Format-Table -AutoSize
} else {
    "No adapter worker status files found."
}
"Recent problems"
if ($problems.Count -gt 0) {
    $problems | Format-Table -AutoSize
} else {
    "No recent ERROR/WARNING lines in the last $Tail stderr lines."
}
"Log files"
$result.logs | Format-List
