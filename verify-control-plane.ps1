param(
    [string]$AgentId = "rd-dispatcher",
    [string]$ControlPlaneEnvPath = "",
    [string]$RuntimeConfigPath = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$ServicesRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ControlPlaneEnvPath) {
    $ControlPlaneEnvPath = Join-Path $ServicesRoot ".local-run\control-plane-runtime.env"
}
if (-not $RuntimeConfigPath) {
    $RuntimeConfigPath = Join-Path $ServicesRoot "config\agent-runtime-config.json"
}

$pythonPath = Join-Path $ServicesRoot "feishu-agent-runtime\.venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $pythonPath)) {
    $pythonPath = "python"
}

$script = @'
import asyncio
import json
import logging
import os
import sys
from pathlib import Path

root = Path(os.environ["SERVICES_ROOT"])
agent_id = os.environ["VERIFY_AGENT_ID"]
control_env_path = Path(os.environ["CONTROL_PLANE_ENV_PATH"])
runtime_config_path = Path(os.environ["RUNTIME_CONFIG_PATH"])

sys.path.insert(0, str(root / "feishu-agent-runtime"))

from app.agents import AgentConfig
from app.control_plane import AgentRunRecord, FeishuBaseControlPlane, PromptProposal

logging.getLogger("app.control_plane").disabled = True


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def classify_error(message: str) -> dict:
    scopes = []
    for scope in (
        "base:record:read",
        "base:record:create",
        "base:record:update",
        "base:app:readonly",
        "base:app:update",
    ):
        if scope in message:
            scopes.append(scope)
    if scopes:
        return {"error_type": "missing_scope", "missing_scopes": sorted(set(scopes))}
    if "Access denied" in message or "Forbidden" in message:
        return {"error_type": "access_denied", "missing_scopes": []}
    return {"error_type": type(Exception()).__name__, "missing_scopes": []}


async def main() -> None:
    result = {
        "ok": False,
        "agent_id": agent_id,
        "control_plane_env_present": control_env_path.exists(),
        "runtime_config_present": runtime_config_path.exists(),
        "prompt_found": False,
        "run_write_ok": False,
        "prompt_proposal_write_ok": False,
        "missing_scopes": [],
        "errors": [],
    }
    if not control_env_path.exists() or not runtime_config_path.exists():
        print(json.dumps(result, ensure_ascii=False))
        return

    control_env = read_env(control_env_path)
    config = json.loads(runtime_config_path.read_text(encoding="utf-8"))
    app = next((item for item in config.get("apps", []) if item.get("agent_id") == agent_id), None)
    if app is None:
        result["errors"].append({"stage": "config", "error_type": "agent_not_found", "missing_scopes": []})
        print(json.dumps(result, ensure_ascii=False))
        return

    agent = AgentConfig(
        agent_id=agent_id,
        agent_name=app.get("agent_name", agent_id),
        app_id=app.get("app_id", ""),
        app_secret=app.get("app_secret", ""),
        source_memory_file=app.get("source_memory_file", ""),
        resolved_prompt_file=app.get("resolved_prompt_file"),
        system_prompt=app.get("system_prompt", ""),
    )
    control = FeishuBaseControlPlane(
        base_url=control_env.get("CONTROL_PLANE_BASE_URL", "https://open.feishu.cn"),
        app_id=app.get("app_id", ""),
        app_secret=app.get("app_secret", ""),
        base_token=control_env.get("CONTROL_PLANE_BASE_TOKEN", ""),
        agents_table_id=control_env.get("CONTROL_PLANE_AGENTS_TABLE_ID", ""),
        prompt_versions_table_id=control_env.get("CONTROL_PLANE_PROMPT_VERSIONS_TABLE_ID", ""),
        agent_runs_table_id=control_env.get("CONTROL_PLANE_AGENT_RUNS_TABLE_ID", ""),
        timeout_seconds=float(control_env.get("CONTROL_PLANE_TIMEOUT_SECONDS") or 20),
    )

    try:
        try:
            records = await control._list_records(control.agents_table_id)
            prompt_record = None
            for record in records:
                fields = record.get("fields", {}) if isinstance(record, dict) else {}
                if str(fields.get("Agent ID") or "").strip() == agent_id:
                    prompt_record = record
                    break
            prompt_fields = prompt_record.get("fields", {}) if isinstance(prompt_record, dict) else {}
            result["prompt_found"] = bool(str(prompt_fields.get("Current Prompt") or "").strip())
            result["prompt_source"] = "feishu_base" if result["prompt_found"] else None
            result["prompt_version_present"] = bool(str(prompt_fields.get("Current Prompt Version") or "").strip())
            result["prompt_text_present"] = result["prompt_found"]
        except Exception as exc:
            error = classify_error(str(exc))
            error["stage"] = "get_prompt"
            result["errors"].append(error)

        run_id = "local-control-plane-verify"
        try:
            await control._create_record(
                control.agent_runs_table_id,
                {
                    "Run ID": run_id,
                    "Agent ID": agent_id,
                    "Project ID": "local-verification",
                    "Event Type": "verification",
                    "Status": "ok",
                    "Reply Summary": "Local Control Plane verification run.",
                    "Prompt Source": result.get("prompt_source") or "",
                    "Prompt Version": "",
                },
            )
            result["run_write_ok"] = True
        except Exception as exc:
            error = classify_error(str(exc))
            error["stage"] = "record_run"
            result["errors"].append(error)

        try:
            await control._create_record(
                control.prompt_versions_table_id,
                {
                    "Title": "Local verification prompt proposal",
                    "Agent ID": agent_id,
                    "Status": "Proposed",
                    "Prompt Text": "As R&D Dispatcher, read Feishu context first and keep handoffs self-contained.",
                    "Change Reason": "Verify proposal write path only.",
                    "Source Run ID": run_id,
                },
            )
            result["prompt_proposal_write_ok"] = True
        except Exception as exc:
            error = classify_error(str(exc))
            error["stage"] = "propose_prompt"
            result["errors"].append(error)
    finally:
        await control.close()

    missing = sorted({scope for error in result["errors"] for scope in error.get("missing_scopes", [])})
    result["missing_scopes"] = missing
    result["ok"] = bool(result["prompt_found"] and result["run_write_ok"] and result["prompt_proposal_write_ok"])
    print(json.dumps(result, ensure_ascii=False))


asyncio.run(main())
'@

$env:SERVICES_ROOT = $ServicesRoot
$env:VERIFY_AGENT_ID = $AgentId
$env:CONTROL_PLANE_ENV_PATH = $ControlPlaneEnvPath
$env:RUNTIME_CONFIG_PATH = $RuntimeConfigPath

$output = $script | & $pythonPath -
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "Control Plane verification failed exit_code=$exitCode"
}

if ($Json) {
    $output
} else {
    $result = $output | ConvertFrom-Json
    "Control Plane verification"
    [pscustomobject]@{
        ok = $result.ok
        agent_id = $result.agent_id
        prompt_found = $result.prompt_found
        run_write_ok = $result.run_write_ok
        prompt_proposal_write_ok = $result.prompt_proposal_write_ok
        missing_scopes = ($result.missing_scopes -join ", ")
    } | Format-List
}
