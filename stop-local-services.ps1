$ErrorActionPreference = "Stop"

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunDir = Join-Path $ServicesRoot ".local-run"

function Stop-ProcessTree {
    param([int]$TargetProcessId)

    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$TargetProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-ProcessTree -TargetProcessId ([int]$child.ProcessId)
    }
    Stop-Process -Id $TargetProcessId -Force -ErrorAction SilentlyContinue
}

foreach ($name in @("adapter", "runtime")) {
    $pidFile = Join-Path $RunDir "$name.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) {
        continue
    }
    $processId = [int](Get-Content -Raw $pidFile)
    Stop-ProcessTree -TargetProcessId $processId
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

"stopped"
