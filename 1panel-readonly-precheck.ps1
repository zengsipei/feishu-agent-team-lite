param(
    [string]$RootPath = "",
    [string]$BaseUrl = "http://127.0.0.1:8080",
    [string]$RuntimeEnvPath = "",
    [string]$AdapterEnvPath = "",
    [string]$RuntimeConfigPath = "",
    [string]$AdapterStatusDir = "",
    [string]$ComposeFile = "",
    [int]$ExpectedAgentCount = 8,
    [string[]]$Ports = @("8080"),
    [ValidateSet("ReportOnly", "RequireFree", "RequireListening")]
    [string]$PortMode = "ReportOnly",
    [int]$LogTail = 200,
    [switch]$RequireComposeServices,
    [switch]$RequireRuntimeHealth,
    [switch]$RequireAdapterConnected,
    [switch]$FailOnLogProblems,
    [switch]$SkipFeishuNetworkProbe,
    [string]$NetworkProbeUrl = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RootPath) {
    $RootPath = $ScriptRoot
}
$RootPath = (Resolve-Path -LiteralPath $RootPath).Path

function Join-RootPath {
    param([string[]]$Parts)

    $path = $RootPath
    foreach ($part in $Parts) {
        $path = Join-Path $path $part
    }
    return $path
}

if (-not $RuntimeEnvPath) {
    $RuntimeEnvPath = Join-RootPath @("feishu-agent-runtime", ".env")
}
if (-not $AdapterEnvPath) {
    $AdapterEnvPath = Join-RootPath @("feishu-channel-adapter", ".env")
}
if (-not $RuntimeConfigPath) {
    $RuntimeConfigPath = Join-RootPath @("config", "agent-runtime-config.json")
}
if (-not $AdapterStatusDir) {
    $AdapterStatusDir = Join-RootPath @("feishu-channel-adapter", "status")
}
if (-not $ComposeFile) {
    $ComposeFile = Join-Path $RootPath "docker-compose.full.yml"
}

$Checks = @()
$ForbiddenOperations = @(
    "docker compose up",
    "docker compose down",
    "docker compose restart",
    "docker compose pull",
    "docker compose build",
    "docker create/run/rm",
    "write env files",
    "write runtime config",
    "change 1Panel settings"
)

function ConvertTo-RelativePath {
    param([string]$Path)

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetFullPath($RootPath)
        if ($full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) -eq $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) {
            return "."
        }
        if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $root = $root + [System.IO.Path]::DirectorySeparatorChar
        }
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($root.Length)
        }
        return $full
    } catch {
        return $Path
    }
}

function Add-Check {
    param(
        [string]$Area,
        [string]$Name,
        [ValidateSet("PASS", "WARN", "FAIL", "NOT_VERIFIED")]
        [string]$Status,
        [string]$Summary,
        [object[]]$Evidence = @()
    )

    $script:Checks += [pscustomobject]@{
        area = $Area
        name = $Name
        status = $Status
        summary = $Summary
        evidence = @($Evidence)
    }
}

function Invoke-ReadonlyCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = & $FilePath @Arguments 2>&1
    [pscustomobject]@{
        exit_code = $LASTEXITCODE
        output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Test-EnvKeyPresence {
    param(
        [string]$Path,
        [string[]]$RequiredKeys,
        [string]$Area,
        [string]$Name
    )

    $relative = ConvertTo-RelativePath -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Check -Area $Area -Name $Name -Status "FAIL" -Summary "Missing env file." -Evidence @(
            [pscustomobject]@{ path = $relative; exists = $false }
        )
        return
    }

    $present = New-Object System.Collections.Generic.HashSet[string]
    $nonEmpty = New-Object System.Collections.Generic.HashSet[string]
    $lines = Get-Content -LiteralPath $Path
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed -match "^\s*([^=\s]+)\s*=") {
            $key = $Matches[1].Trim()
            $present.Add($key) | Out-Null
            if ($trimmed -match ("^\s*" + [regex]::Escape($key) + "\s*=\s*\S+")) {
                $nonEmpty.Add($key) | Out-Null
            }
        }
    }

    $missing = @($RequiredKeys | Where-Object { -not $present.Contains($_) })
    $blank = @($RequiredKeys | Where-Object { $present.Contains($_) -and -not $nonEmpty.Contains($_) })
    $status = "PASS"
    $summary = "Required keys are present; values were not printed."
    if ($missing.Count -gt 0) {
        $status = "FAIL"
        $summary = "Required env keys are missing."
    } elseif ($blank.Count -gt 0) {
        $status = "FAIL"
        $summary = "Required env keys are present but empty."
    }

    Add-Check -Area $Area -Name $Name -Status $status -Summary $summary -Evidence @(
        [pscustomobject]@{
            path = $relative
            exists = $true
            required_key_count = $RequiredKeys.Count
            missing_keys = $missing
            blank_keys = $blank
            value_output = "suppressed"
        }
    )
}

function Test-RuntimeConfig {
    param([string]$Path)

    $relative = ConvertTo-RelativePath -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Check -Area "config" -Name "runtime config" -Status "FAIL" -Summary "Missing runtime config file." -Evidence @(
            [pscustomobject]@{ path = $relative; exists = $false }
        )
        return
    }

    try {
        $config = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        Add-Check -Area "config" -Name "runtime config" -Status "FAIL" -Summary "Runtime config is not valid JSON." -Evidence @(
            [pscustomobject]@{ path = $relative; parse_error = $_.Exception.Message }
        )
        return
    }

    $apps = @($config.apps)
    $agentIds = @($apps | ForEach-Object { $_.agent_id } | Where-Object { $_ })
    $appIds = @($apps | ForEach-Object { $_.app_id } | Where-Object { $_ })
    $secretFieldCount = @($apps | Where-Object { $_.PSObject.Properties.Name -contains "app_secret" }).Count
    $systemPromptFieldCount = @($apps | Where-Object { $_.PSObject.Properties.Name -contains "system_prompt" }).Count
    $duplicateAgentIdCount = @($agentIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count
    $duplicateAppIdCount = @($appIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count

    $failures = New-Object System.Collections.Generic.List[string]
    if ($apps.Count -ne $ExpectedAgentCount) {
        $failures.Add("expected $ExpectedAgentCount apps, got $($apps.Count)") | Out-Null
    }
    if ($agentIds.Count -ne $ExpectedAgentCount) {
        $failures.Add("agent_id count is $($agentIds.Count)") | Out-Null
    }
    if ($appIds.Count -ne $ExpectedAgentCount) {
        $failures.Add("app_id count is $($appIds.Count)") | Out-Null
    }
    if ($duplicateAgentIdCount -gt 0) {
        $failures.Add("duplicate agent_id groups: $duplicateAgentIdCount") | Out-Null
    }
    if ($duplicateAppIdCount -gt 0) {
        $failures.Add("duplicate app_id groups: $duplicateAppIdCount") | Out-Null
    }

    $status = "PASS"
    $summary = "Runtime config structure is valid; secret fields were not printed."
    if ($failures.Count -gt 0) {
        $status = "FAIL"
        $summary = "Runtime config structure failed validation."
    }

    Add-Check -Area "config" -Name "runtime config" -Status $status -Summary $summary -Evidence @(
        [pscustomobject]@{
            path = $relative
            exists = $true
            apps_count = $apps.Count
            agent_id_count = $agentIds.Count
            app_id_count = $appIds.Count
            duplicate_agent_id_groups = $duplicateAgentIdCount
            duplicate_app_id_groups = $duplicateAppIdCount
            app_secret_fields = $secretFieldCount
            system_prompt_fields = $systemPromptFieldCount
            sensitive_value_output = "suppressed"
            failures = @($failures)
        }
    )
}

function Get-MemorySummary {
    try {
        if (Test-Path -LiteralPath "/proc/meminfo") {
            $items = @{}
            Get-Content -LiteralPath "/proc/meminfo" | ForEach-Object {
                if ($_ -match "^([^:]+):\s+(\d+)") {
                    $items[$Matches[1]] = [int64]$Matches[2]
                }
            }
            if ($items.ContainsKey("MemTotal")) {
                return [pscustomobject]@{
                    source = "/proc/meminfo"
                    total_mb = [math]::Round($items["MemTotal"] / 1024, 0)
                    available_mb = if ($items.ContainsKey("MemAvailable")) { [math]::Round($items["MemAvailable"] / 1024, 0) } else { $null }
                }
            }
        }
    } catch {
        return $null
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [pscustomobject]@{
            source = "Win32_OperatingSystem"
            total_mb = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            available_mb = [math]::Round($os.FreePhysicalMemory / 1024, 0)
        }
    } catch {
        return $null
    }
}

function Get-DiskSummary {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path
        $driveName = $item.PSDrive.Name
        $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
        return [pscustomobject]@{
            drive = $driveName
            free_gb = [math]::Round($drive.Free / 1GB, 2)
            used_gb = [math]::Round($drive.Used / 1GB, 2)
        }
    } catch {
        return $null
    }
}

function Test-SystemResources {
    $memory = Get-MemorySummary
    $disk = Get-DiskSummary -Path $RootPath
    $osText = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()

    $status = "PASS"
    $summary = "System resource summary collected without changing the host."
    if (-not $memory -or -not $disk) {
        $status = "WARN"
        $summary = "System resource summary is partial."
    }

    Add-Check -Area "host" -Name "system resources" -Status $status -Summary $summary -Evidence @(
        [pscustomobject]@{
            os = $osText
            architecture = $arch
            powershell = $PSVersionTable.PSVersion.ToString()
            memory = $memory
            disk = $disk
        }
    )
}

function Test-DirectoryInventory {
    $paths = @(
        @{ name = "services root"; path = $RootPath; required = $true },
        @{ name = "config directory"; path = (Join-Path $RootPath "config"); required = $true },
        @{ name = "runtime data directory"; path = (Join-RootPath @("feishu-agent-runtime", "data")); required = $true },
        @{ name = "adapter status directory"; path = $AdapterStatusDir; required = $true },
        @{ name = "runtime app directory"; path = (Join-RootPath @("feishu-agent-runtime", "app")); required = $true },
        @{ name = "adapter app directory"; path = (Join-RootPath @("feishu-channel-adapter", "app")); required = $true }
    )

    $items = @()
    $missingRequired = 0
    foreach ($entry in $paths) {
        $exists = Test-Path -LiteralPath $entry.path
        $aclReadable = $false
        if ($exists) {
            try {
                Get-Acl -LiteralPath $entry.path | Out-Null
                $aclReadable = $true
            } catch {
                $aclReadable = $false
            }
        } elseif ($entry.required) {
            $missingRequired += 1
        }
        $items += [pscustomobject]@{
            name = $entry.name
            path = (ConvertTo-RelativePath -Path $entry.path)
            exists = $exists
            acl_readable = $aclReadable
            write_test = "not_performed"
        }
    }

    $status = "PASS"
    $summary = "Required directories exist; ACLs were only read."
    if ($missingRequired -gt 0) {
        $status = "FAIL"
        $summary = "Required directories are missing."
    }

    Add-Check -Area "filesystem" -Name "directory inventory" -Status $status -Summary $summary -Evidence $items
}

function Test-ComposeFile {
    $relative = ConvertTo-RelativePath -Path $ComposeFile
    if (-not (Test-Path -LiteralPath $ComposeFile)) {
        Add-Check -Area "docker" -Name "compose file" -Status "FAIL" -Summary "Compose file is missing." -Evidence @(
            [pscustomobject]@{ path = $relative; exists = $false }
        )
        return
    }

    Add-Check -Area "docker" -Name "compose file" -Status "PASS" -Summary "Compose file exists." -Evidence @(
        [pscustomobject]@{ path = $relative; exists = $true }
    )
}

function Test-DockerAvailability {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        Add-Check -Area "docker" -Name "docker cli" -Status "FAIL" -Summary "Docker CLI is not available." -Evidence @()
        return $false
    }

    $version = Invoke-ReadonlyCommand -FilePath "docker" -Arguments @("--version")
    $composeVersion = Invoke-ReadonlyCommand -FilePath "docker" -Arguments @("compose", "version")
    $status = "PASS"
    $summary = "Docker and Compose commands are available."
    if ($version.exit_code -ne 0 -or $composeVersion.exit_code -ne 0) {
        $status = "FAIL"
        $summary = "Docker or Compose command failed."
    }

    Add-Check -Area "docker" -Name "docker cli" -Status $status -Summary $summary -Evidence @(
        [pscustomobject]@{
            docker_version = ($version.output -join " ")
            compose_version = ($composeVersion.output -join " ")
        }
    )
    return ($status -eq "PASS")
}

function ConvertFrom-ComposePsJson {
    param([string[]]$Rows)

    $text = ($Rows -join "`n").Trim()
    if (-not $text) {
        return @()
    }
    try {
        return @($text | ConvertFrom-Json)
    } catch {
        return @($Rows | Where-Object { $_.Trim().StartsWith("{") } | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

function Test-DockerComposeState {
    if (-not (Test-Path -LiteralPath $ComposeFile)) {
        Add-Check -Area "docker" -Name "compose state" -Status "NOT_VERIFIED" -Summary "Compose state was not checked because the compose file is missing." -Evidence @()
        return
    }

    $config = Invoke-ReadonlyCommand -FilePath "docker" -Arguments @("compose", "-f", $ComposeFile, "config", "--quiet")
    if ($config.exit_code -ne 0) {
        Add-Check -Area "docker" -Name "compose config" -Status "FAIL" -Summary "docker compose config failed." -Evidence @(
            [pscustomobject]@{ exit_code = $config.exit_code; output = $config.output }
        )
    } else {
        Add-Check -Area "docker" -Name "compose config" -Status "PASS" -Summary "docker compose config is valid." -Evidence @(
            [pscustomobject]@{ exit_code = $config.exit_code }
        )
    }

    $psResult = Invoke-ReadonlyCommand -FilePath "docker" -Arguments @("compose", "-f", $ComposeFile, "ps", "--format", "json")
    if ($psResult.exit_code -ne 0) {
        $status = "WARN"
        if ($RequireComposeServices) {
            $status = "FAIL"
        }
        Add-Check -Area "docker" -Name "compose ps" -Status $status -Summary "docker compose ps could not be read." -Evidence @(
            [pscustomobject]@{ exit_code = $psResult.exit_code; output = $psResult.output }
        )
        return
    }

    $containers = @(ConvertFrom-ComposePsJson -Rows $psResult.output)
    $summaryRows = @($containers | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            service = $_.Service
            state = $_.State
            health = $_.Health
        }
    })

    $requiredServices = @("feishu-agent-runtime", "feishu-channel-adapter")
    $failures = New-Object System.Collections.Generic.List[string]
    if ($RequireComposeServices) {
        foreach ($service in $requiredServices) {
            $container = $containers | Where-Object { $_.Service -eq $service -or $_.Name -eq $service } | Select-Object -First 1
            if (-not $container) {
                $failures.Add("missing $service") | Out-Null
                continue
            }
            if ($container.State -ne "running") {
                $failures.Add("$service state=$($container.State)") | Out-Null
            }
            if ($service -eq "feishu-agent-runtime" -and $container.Health -and $container.Health -ne "healthy") {
                $failures.Add("$service health=$($container.Health)") | Out-Null
            }
        }
    }

    $status = "PASS"
    $summary = "Compose state was read."
    if ($failures.Count -gt 0) {
        $status = "FAIL"
        $summary = "Required Compose services are not all running and healthy."
    } elseif (-not $RequireComposeServices -and $containers.Count -eq 0) {
        $status = "NOT_VERIFIED"
        $summary = "No Compose containers are currently associated with this file."
    }

    Add-Check -Area "docker" -Name "compose ps" -Status $status -Summary $summary -Evidence @(
        [pscustomobject]@{
            container_count = $containers.Count
            containers = $summaryRows
            require_compose_services = [bool]$RequireComposeServices
            failures = @($failures)
        }
    )
}

function Test-PortState {
    foreach ($portText in $Ports) {
        $port = 0
        if (-not [int]::TryParse($portText, [ref]$port)) {
            Add-Check -Area "network" -Name "port $portText" -Status "WARN" -Summary "Port value is not numeric." -Evidence @()
            continue
        }

        $method = "unavailable"
        $listening = $null
        $errorText = $null
        try {
            if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
                $rows = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
                $method = "Get-NetTCPConnection"
                $listening = ($rows.Count -gt 0)
            } elseif (Get-Command ss -ErrorAction SilentlyContinue) {
                $rows = & ss -ltn 2>$null
                $method = "ss"
                $listening = (@($rows | Select-String -Pattern (":$port\s")).Count -gt 0)
            } elseif (Get-Command netstat -ErrorAction SilentlyContinue) {
                $rows = & netstat -an 2>$null
                $method = "netstat"
                $listening = (@($rows | Select-String -Pattern (":$port\s+.*LISTEN")).Count -gt 0)
            }
        } catch {
            $errorText = $_.Exception.Message
        }

        if ($null -eq $listening) {
            Add-Check -Area "network" -Name "port $port" -Status "NOT_VERIFIED" -Summary "Port state could not be determined." -Evidence @(
                [pscustomobject]@{ method = $method; error = $errorText }
            )
            continue
        }

        $status = "PASS"
        $summary = "Port state observed."
        if ($PortMode -eq "RequireFree" -and $listening) {
            $status = "FAIL"
            $summary = "Port is listening but the policy requires it to be free."
        } elseif ($PortMode -eq "RequireListening" -and -not $listening) {
            $status = "FAIL"
            $summary = "Port is not listening but the policy requires it to be listening."
        }

        Add-Check -Area "network" -Name "port $port" -Status $status -Summary $summary -Evidence @(
            [pscustomobject]@{
                mode = $PortMode
                method = $method
                listening = $listening
            }
        )
    }
}

function Test-RuntimeHealth {
    try {
        $health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get -TimeoutSec 8
        $ok = $false
        if ($health.PSObject.Properties.Name -contains "ok") {
            $ok = [bool]$health.ok
        }
        $status = "PASS"
        $summary = "Runtime health endpoint is reachable."
        if (-not $ok) {
            $status = "WARN"
            $summary = "Runtime health endpoint responded but did not report ok=true."
            if ($RequireRuntimeHealth) {
                $status = "FAIL"
            }
        }
        Add-Check -Area "network" -Name "runtime health" -Status $status -Summary $summary -Evidence @(
            [pscustomobject]@{ base_url = $BaseUrl; ok = $ok; response_fields = @($health.PSObject.Properties.Name) }
        )
    } catch {
        $status = "NOT_VERIFIED"
        if ($RequireRuntimeHealth) {
            $status = "FAIL"
        }
        Add-Check -Area "network" -Name "runtime health" -Status $status -Summary "Runtime health endpoint is not reachable." -Evidence @(
            [pscustomobject]@{ base_url = $BaseUrl; error = $_.Exception.Message }
        )
    }
}

function Test-NetworkProbe {
    param(
        [string]$Name,
        [string]$Url,
        [bool]$IsCustom
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 10 -UseBasicParsing
        $evidence = [pscustomobject]@{
            probe = $(if ($IsCustom) { "custom" } else { $Url })
            status_code = [int]$response.StatusCode
        }
        Add-Check -Area "network" -Name $Name -Status "PASS" -Summary "Network probe reached the target." -Evidence @($evidence)
    } catch {
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode) {
            $statusCode = [int]$response.StatusCode
            Add-Check -Area "network" -Name $Name -Status "PASS" -Summary "Network probe reached the target and received an HTTP response." -Evidence @(
                [pscustomobject]@{
                    probe = $(if ($IsCustom) { "custom" } else { $Url })
                    status_code = $statusCode
                }
            )
        } else {
            Add-Check -Area "network" -Name $Name -Status "WARN" -Summary "Network probe did not reach the target." -Evidence @(
                [pscustomobject]@{
                    probe = $(if ($IsCustom) { "custom" } else { $Url })
                    error = $_.Exception.Message
                }
            )
        }
    }
}

function Test-AdapterStatusFiles {
    $relative = ConvertTo-RelativePath -Path $AdapterStatusDir
    if (-not (Test-Path -LiteralPath $AdapterStatusDir)) {
        $status = "NOT_VERIFIED"
        if ($RequireAdapterConnected) {
            $status = "FAIL"
        }
        Add-Check -Area "adapter" -Name "worker status files" -Status $status -Summary "Adapter status directory is missing." -Evidence @(
            [pscustomobject]@{ path = $relative; exists = $false }
        )
        return
    }

    $files = @(Get-ChildItem -LiteralPath $AdapterStatusDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
    $badJson = 0
    $statusCounts = @{}
    foreach ($file in $files) {
        try {
            $data = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            $state = "missing"
            if ($data.PSObject.Properties.Name -contains "status" -and $data.status) {
                $state = [string]$data.status
            }
            if (-not $statusCounts.ContainsKey($state)) {
                $statusCounts[$state] = 0
            }
            $statusCounts[$state] += 1
        } catch {
            $badJson += 1
        }
    }

    $connected = 0
    if ($statusCounts.ContainsKey("connected")) {
        $connected = $statusCounts["connected"]
    }
    $status = "PASS"
    $summary = "Adapter worker status files are present and connected."
    if ($files.Count -ne $ExpectedAgentCount -or $connected -ne $ExpectedAgentCount -or $badJson -gt 0) {
        $status = "WARN"
        if ($RequireAdapterConnected) {
            $status = "FAIL"
        }
        $summary = "Adapter worker status files are incomplete or not all connected."
    }

    Add-Check -Area "adapter" -Name "worker status files" -Status $status -Summary $summary -Evidence @(
        [pscustomobject]@{
            path = $relative
            file_count = $files.Count
            expected_file_count = $ExpectedAgentCount
            connected_count = $connected
            bad_json_count = $badJson
            status_counts = $statusCounts
            app_id_output = "suppressed"
        }
    )
}

function Test-ComposeLogs {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Add-Check -Area "logs" -Name "compose logs" -Status "NOT_VERIFIED" -Summary "Docker CLI is unavailable." -Evidence @()
        return
    }
    if (-not (Test-Path -LiteralPath $ComposeFile)) {
        Add-Check -Area "logs" -Name "compose logs" -Status "NOT_VERIFIED" -Summary "Compose file is missing." -Evidence @()
        return
    }

    $patterns = "ERROR|WARNING|Traceback|Exception|exited|failed|retrying|Runtime returned status=error"
    $services = @("feishu-agent-runtime", "feishu-channel-adapter")
    $rows = @()
    $commandFailures = 0
    foreach ($service in $services) {
        $result = Invoke-ReadonlyCommand -FilePath "docker" -Arguments @("compose", "-f", $ComposeFile, "logs", "--tail=$LogTail", $service)
        if ($result.exit_code -ne 0) {
            $commandFailures += 1
            $rows += [pscustomobject]@{
                service = $service
                problem_line_count = $null
                command_exit_code = $result.exit_code
            }
            continue
        }
        $problemCount = @($result.output | Select-String -Pattern $patterns).Count
        $rows += [pscustomobject]@{
            service = $service
            problem_line_count = $problemCount
            command_exit_code = $result.exit_code
        }
    }

    $totalProblems = @($rows | Where-Object { $null -ne $_.problem_line_count } | Measure-Object -Property problem_line_count -Sum).Sum
    if ($null -eq $totalProblems) {
        $totalProblems = 0
    }

    $status = "PASS"
    $summary = "Compose logs were scanned without printing raw log lines."
    if ($commandFailures -gt 0) {
        $status = "NOT_VERIFIED"
        $summary = "Some compose logs could not be read."
    } elseif ($totalProblems -gt 0) {
        $status = "WARN"
        $summary = "Compose logs contain problem-pattern matches; raw lines were suppressed."
        if ($FailOnLogProblems) {
            $status = "FAIL"
        }
    }

    Add-Check -Area "logs" -Name "compose logs" -Status $status -Summary $summary -Evidence @(
        [pscustomobject]@{
            tail = $LogTail
            raw_log_output = "suppressed"
            services = $rows
        }
    )
}

function Test-BackupRollbackInventory {
    $items = @(
        @{ display = "docker-compose.full.yml"; parts = @("docker-compose.full.yml") },
        @{ display = "config/agent-runtime-config.json"; parts = @("config", "agent-runtime-config.json") },
        @{ display = "feishu-agent-runtime/.env"; parts = @("feishu-agent-runtime", ".env") },
        @{ display = "feishu-channel-adapter/.env"; parts = @("feishu-channel-adapter", ".env") },
        @{ display = "feishu-agent-runtime/data/runtime.sqlite3"; parts = @("feishu-agent-runtime", "data", "runtime.sqlite3") },
        @{ display = "feishu-agent-runtime/data/runtime.sqlite3-wal"; parts = @("feishu-agent-runtime", "data", "runtime.sqlite3-wal") },
        @{ display = "feishu-agent-runtime/data/runtime.sqlite3-shm"; parts = @("feishu-agent-runtime", "data", "runtime.sqlite3-shm") }
    )
    $rows = @()
    foreach ($item in $items) {
        $path = Join-RootPath $item.parts
        $rows += [pscustomobject]@{
            path = $item.display
            exists = (Test-Path -LiteralPath $path)
            content_output = "suppressed"
        }
    }

    Add-Check -Area "rollback" -Name "backup inventory" -Status "PASS" -Summary "Backup candidate inventory was collected; no backup was created." -Evidence $rows
    Add-Check -Area "rollback" -Name "external backup target" -Status "NOT_VERIFIED" -Summary "Operator must confirm the off-host backup target and rollback owner before deployment." -Evidence @(
        [pscustomobject]@{
            backup_created_by_script = $false
            rollback_test_performed = $false
        }
    )
}

function Add-ReleaseGateChecks {
    Add-Check -Area "release_gate" -Name "forbidden operations" -Status "PASS" -Summary "This script performed only read-only checks." -Evidence @(
        [pscustomobject]@{
            forbidden_operations = $ForbiddenOperations
            performed = $false
        }
    )
    Add-Check -Area "release_gate" -Name "formal deploy" -Status "NOT_VERIFIED" -Summary "Formal deployment remains blocked until the sanitized evidence package is reviewed and explicitly approved." -Evidence @(
        [pscustomobject]@{
            allowed_stage = "1Panel read-only pre-check"
            formal_deploy_allowed = $false
            known_blocker = "Agents cannot yet emit real Feishu rich-text mentions for automatic multi-agent relay."
        }
    )
}

Test-SystemResources
Test-DirectoryInventory
Test-EnvKeyPresence -Path $RuntimeEnvPath -RequiredKeys @("CHANNEL_AUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_MODEL") -Area "config" -Name "runtime env"
Test-EnvKeyPresence -Path $AdapterEnvPath -RequiredKeys @("RUNTIME_AUTH_TOKEN", "CHANNEL_TRANSPORT", "CHANNEL_REQUIRE_MENTION", "CHANNEL_DROP_SELF_SENT") -Area "config" -Name "adapter env"
Test-RuntimeConfig -Path $RuntimeConfigPath
Test-ComposeFile
$dockerOk = Test-DockerAvailability
if ($dockerOk) {
    Test-DockerComposeState
}
Test-PortState
Test-RuntimeHealth
if (-not $SkipFeishuNetworkProbe) {
    Test-NetworkProbe -Name "feishu open platform" -Url "https://open.feishu.cn" -IsCustom $false
}
if ($NetworkProbeUrl) {
    Test-NetworkProbe -Name "custom provider endpoint" -Url $NetworkProbeUrl -IsCustom $true
}
Test-AdapterStatusFiles
Test-ComposeLogs
Test-BackupRollbackInventory
Add-ReleaseGateChecks

$summary = [ordered]@{}
foreach ($status in @("PASS", "WARN", "FAIL", "NOT_VERIFIED")) {
    $summary[$status.ToLower()] = @($Checks | Where-Object { $_.status -eq $status }).Count
}

$blockingFailures = @($Checks | Where-Object { $_.status -eq "FAIL" })
$warnings = @($Checks | Where-Object { $_.status -eq "WARN" })
$notVerified = @($Checks | Where-Object { $_.status -eq "NOT_VERIFIED" })

$result = [System.Collections.Specialized.OrderedDictionary]::new()
$result.Add("ok", ($blockingFailures.Count -eq 0))
$result.Add("generated_at", ((Get-Date).ToString("o")))
$result.Add("root_path", (ConvertTo-RelativePath -Path $RootPath))
$result.Add("base_url", $BaseUrl)
$result.Add("expected_agent_count", $ExpectedAgentCount)
$result.Add("port_mode", $PortMode)
$result.Add("summary", $summary)
$checksArray = [object[]]@($Checks)
$blockingFailuresArray = [object[]]@($blockingFailures | Select-Object area, name, summary)
$warningsArray = [object[]]@($warnings | Select-Object area, name, summary)
$notVerifiedArray = [object[]]@($notVerified | Select-Object area, name, summary)
$result.Add("checks", [object]$checksArray)
$result.Add("blocking_failures", [object]$blockingFailuresArray)
$result.Add("warnings", [object]$warningsArray)
$result.Add("not_verified", [object]$notVerifiedArray)

if ($Json) {
    $result | ConvertTo-Json -Depth 12
} else {
    "1Panel read-only pre-check"
    [pscustomobject]@{
        ok = $result["ok"]
        pass = $summary.pass
        warn = $summary.warn
        fail = $summary.fail
        not_verified = $summary.not_verified
        port_mode = $PortMode
        expected_agent_count = $ExpectedAgentCount
    } | Format-List

    "Checks"
    $Checks | Select-Object area, name, status, summary | Format-Table -AutoSize

    if ($blockingFailures.Count -gt 0) {
        "Blocking failures"
        $blockingFailures | Select-Object area, name, summary | Format-Table -AutoSize
    }
    if ($warnings.Count -gt 0) {
        "Warnings"
        $warnings | Select-Object area, name, summary | Format-Table -AutoSize
    }
    if ($notVerified.Count -gt 0) {
        "Not verified"
        $notVerified | Select-Object area, name, summary | Format-Table -AutoSize
    }
}

if ($blockingFailures.Count -gt 0) {
    exit 1
}
