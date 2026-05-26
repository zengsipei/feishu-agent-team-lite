param(
    [int]$RuntimePort = 18080,
    [switch]$Adapter
)

$ErrorActionPreference = "Stop"

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RuntimeDir = Join-Path $ServicesRoot "feishu-agent-runtime"
$AdapterDir = Join-Path $ServicesRoot "feishu-channel-adapter"
$RuntimePython = Join-Path $RuntimeDir ".venv\Scripts\python.exe"
$AdapterPython = Join-Path $AdapterDir ".venv\Scripts\python.exe"
$RuntimeConfig = Join-Path $RuntimeDir "config\agent-runtime-config.json"
$RuntimeEnv = Join-Path $RuntimeDir ".env"
$AdapterEnv = Join-Path $AdapterDir ".env"
$RunDir = Join-Path $ServicesRoot ".local-run"

if (-not (Test-Path -LiteralPath $RuntimePython)) {
    throw "Runtime venv not found: $RuntimePython"
}
if (-not (Test-Path -LiteralPath $RuntimeConfig)) {
    throw "Runtime config not found: $RuntimeConfig"
}
if (-not (Test-Path -LiteralPath $RuntimeEnv)) {
    throw "Runtime .env not found: $RuntimeEnv"
}
if ($Adapter -and -not (Test-Path -LiteralPath $AdapterPython)) {
    throw "Adapter venv not found: $AdapterPython"
}
if ($Adapter -and -not (Test-Path -LiteralPath $AdapterEnv)) {
    throw "Adapter .env not found: $AdapterEnv"
}

New-Item -ItemType Directory -Force $RunDir | Out-Null

$runtimeOut = Join-Path $RunDir "runtime.out.log"
$runtimeErr = Join-Path $RunDir "runtime.err.log"
$runtime = Start-Process -FilePath $RuntimePython -ArgumentList @(
    "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$RuntimePort"
) -WorkingDirectory $RuntimeDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $runtimeOut -RedirectStandardError $runtimeErr
$runtime.Id | Set-Content -Encoding ASCII (Join-Path $RunDir "runtime.pid")

$adapterProcess = $null
if ($Adapter) {
    $adapterOut = Join-Path $RunDir "adapter.out.log"
    $adapterErr = Join-Path $RunDir "adapter.err.log"
    $adapterProcess = Start-Process -FilePath $AdapterPython -ArgumentList @(
        "-m", "app.main"
    ) -WorkingDirectory $AdapterDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $adapterOut -RedirectStandardError $adapterErr
    $adapterProcess.Id | Set-Content -Encoding ASCII (Join-Path $RunDir "adapter.pid")
}

[pscustomobject]@{
    runtime_pid = $runtime.Id
    adapter_pid = if ($adapterProcess) { $adapterProcess.Id } else { $null }
    runtime_url = "http://127.0.0.1:$RuntimePort"
    logs = $RunDir
} | ConvertTo-Json -Compress
