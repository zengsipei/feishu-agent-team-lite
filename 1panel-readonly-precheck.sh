#!/usr/bin/env bash
set -u

ROOT_PATH="."
BASE_URL="http://127.0.0.1:8080"
RUNTIME_ENV_PATH=""
ADAPTER_ENV_PATH=""
RUNTIME_CONFIG_PATH=""
ADAPTER_STATUS_DIR=""
COMPOSE_FILE=""
EXPECTED_AGENT_COUNT="8"
PORTS="8080"
PORT_MODE="ReportOnly"
LOG_TAIL="200"
REQUIRE_COMPOSE_SERVICES="false"
REQUIRE_RUNTIME_HEALTH="false"
REQUIRE_ADAPTER_CONNECTED="false"
FAIL_ON_LOG_PROBLEMS="false"
SKIP_FEISHU_NETWORK_PROBE="false"
NETWORK_PROBE_URL=""
JSON_OUTPUT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-path) ROOT_PATH="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --runtime-env-path) RUNTIME_ENV_PATH="$2"; shift 2 ;;
    --adapter-env-path) ADAPTER_ENV_PATH="$2"; shift 2 ;;
    --runtime-config-path) RUNTIME_CONFIG_PATH="$2"; shift 2 ;;
    --adapter-status-dir) ADAPTER_STATUS_DIR="$2"; shift 2 ;;
    --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
    --expected-agent-count) EXPECTED_AGENT_COUNT="$2"; shift 2 ;;
    --ports) PORTS="$2"; shift 2 ;;
    --port-mode) PORT_MODE="$2"; shift 2 ;;
    --log-tail) LOG_TAIL="$2"; shift 2 ;;
    --require-compose-services) REQUIRE_COMPOSE_SERVICES="true"; shift ;;
    --require-runtime-health) REQUIRE_RUNTIME_HEALTH="true"; shift ;;
    --require-adapter-connected) REQUIRE_ADAPTER_CONNECTED="true"; shift ;;
    --fail-on-log-problems) FAIL_ON_LOG_PROBLEMS="true"; shift ;;
    --skip-feishu-network-probe) SKIP_FEISHU_NETWORK_PROBE="true"; shift ;;
    --network-probe-url) NETWORK_PROBE_URL="$2"; shift 2 ;;
    --json) JSON_OUTPUT="true"; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ./1panel-readonly-precheck.sh [options]

Read-only 1Panel pre-check for Feishu Agent Team services.

Options:
  --root-path PATH                 Deployment root. Default: .
  --base-url URL                   Runtime base URL. Default: http://127.0.0.1:8080
  --runtime-env-path PATH          Runtime .env path.
  --adapter-env-path PATH          Adapter .env path.
  --runtime-config-path PATH       agent-runtime-config.json path.
  --adapter-status-dir PATH        Adapter status directory.
  --compose-file PATH              Compose file path.
  --expected-agent-count N         Expected Agent count. Default: 8
  --ports CSV                      Ports to inspect. Default: 8080
  --port-mode MODE                 ReportOnly, RequireFree, or RequireListening.
  --log-tail N                     Compose log tail count. Default: 200
  --require-compose-services       Fail unless compose services are running.
  --require-runtime-health         Fail unless /health is reachable and ok.
  --require-adapter-connected      Fail unless adapter statuses are all connected.
  --fail-on-log-problems           Treat log problem-pattern matches as failures.
  --skip-feishu-network-probe      Skip https://open.feishu.cn probe.
  --network-probe-url URL          Optional extra provider endpoint probe.
  --json                           Print JSON. Human summary is the default.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$ROOT_PATH" ]]; then
  echo "Root path not found: $ROOT_PATH" >&2
  exit 1
fi

ROOT_PATH="$(cd "$ROOT_PATH" && pwd -P)"
RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-$ROOT_PATH/feishu-agent-runtime/.env}"
ADAPTER_ENV_PATH="${ADAPTER_ENV_PATH:-$ROOT_PATH/feishu-channel-adapter/.env}"
RUNTIME_CONFIG_PATH="${RUNTIME_CONFIG_PATH:-$ROOT_PATH/config/agent-runtime-config.json}"
ADAPTER_STATUS_DIR="${ADAPTER_STATUS_DIR:-$ROOT_PATH/feishu-channel-adapter/status}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_PATH/docker-compose.full.yml}"

CHECKS_JSON=""
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
NOT_VERIFIED_COUNT=0

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

rel_path() {
  local p="${1:-}"
  if [[ "$p" == "$ROOT_PATH" ]]; then
    printf '.'
  elif [[ "$p" == "$ROOT_PATH/"* ]]; then
    printf '%s' "${p#$ROOT_PATH/}"
  else
    printf '%s' "$p"
  fi
}

add_check() {
  local area="$1"
  local name="$2"
  local status="$3"
  local summary="$4"
  local evidence
  if [[ $# -ge 5 ]]; then
    evidence="$5"
  else
    evidence="{}"
  fi
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    NOT_VERIFIED) NOT_VERIFIED_COUNT=$((NOT_VERIFIED_COUNT + 1)) ;;
  esac
  local item
  item="{\"area\":\"$(json_escape "$area")\",\"name\":\"$(json_escape "$name")\",\"status\":\"$status\",\"summary\":\"$(json_escape "$summary")\",\"evidence\":$evidence}"
  if [[ -z "$CHECKS_JSON" ]]; then
    CHECKS_JSON="$item"
  else
    CHECKS_JSON="$CHECKS_JSON,$item"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

env_key_report() {
  local path="$1"
  local area="$2"
  local name="$3"
  shift 3
  local keys=("$@")
  local rel
  rel="$(rel_path "$path")"
  if [[ ! -f "$path" ]]; then
    add_check "$area" "$name" "FAIL" "Missing env file." "{\"path\":\"$(json_escape "$rel")\",\"exists\":false}"
    return
  fi
  local missing=()
  local blank=()
  local key line found value
  for key in "${keys[@]}"; do
    found="false"
    value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" == "$key="* || "$line" =~ ^[[:space:]]*$key[[:space:]]*= ]]; then
        found="true"
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        break
      fi
    done < "$path"
    if [[ "$found" != "true" ]]; then
      missing+=("$key")
    elif [[ -z "$value" ]]; then
      blank+=("$key")
    fi
  done
  local status="PASS"
  local summary="Required keys are present; values were not printed."
  if [[ ${#missing[@]} -gt 0 ]]; then
    status="FAIL"
    summary="Required env keys are missing."
  elif [[ ${#blank[@]} -gt 0 ]]; then
    status="FAIL"
    summary="Required env keys are present but empty."
  fi
  local missing_json="[]"
  local blank_json="[]"
  if [[ ${#missing[@]} -gt 0 ]]; then
    missing_json="["
    local first="true"
    for key in "${missing[@]}"; do
      [[ "$first" == "true" ]] || missing_json+=","
      first="false"
      missing_json+="\"$(json_escape "$key")\""
    done
    missing_json+="]"
  fi
  if [[ ${#blank[@]} -gt 0 ]]; then
    blank_json="["
    local first="true"
    for key in "${blank[@]}"; do
      [[ "$first" == "true" ]] || blank_json+=","
      first="false"
      blank_json+="\"$(json_escape "$key")\""
    done
    blank_json+="]"
  fi
  add_check "$area" "$name" "$status" "$summary" "{\"path\":\"$(json_escape "$rel")\",\"exists\":true,\"required_key_count\":${#keys[@]},\"missing_keys\":$missing_json,\"blank_keys\":$blank_json,\"value_output\":\"suppressed\"}"
}

system_resources() {
  local os arch mem_total mem_available disk_free disk_used evidence status summary
  os="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  mem_total="null"
  mem_available="null"
  if [[ -r /proc/meminfo ]]; then
    mem_total="$(awk '/MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo)"
    mem_available="$(awk '/MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo)"
    [[ -z "$mem_available" ]] && mem_available="null"
  fi
  disk_free="null"
  disk_used="null"
  if has_cmd df; then
    disk_free="$(df -Pk "$ROOT_PATH" 2>/dev/null | awk 'NR==2 {printf "%.2f", $4/1024/1024}')"
    disk_used="$(df -Pk "$ROOT_PATH" 2>/dev/null | awk 'NR==2 {printf "%.2f", $3/1024/1024}')"
    [[ -z "$disk_free" ]] && disk_free="null"
    [[ -z "$disk_used" ]] && disk_used="null"
  fi
  status="PASS"
  summary="System resource summary collected without changing the host."
  if [[ "$mem_total" == "null" || "$disk_free" == "null" ]]; then
    status="WARN"
    summary="System resource summary is partial."
  fi
  evidence="{\"os\":\"$(json_escape "$os")\",\"architecture\":\"$(json_escape "$arch")\",\"memory\":{\"source\":\"/proc/meminfo\",\"total_mb\":$mem_total,\"available_mb\":$mem_available},\"disk\":{\"free_gb\":$disk_free,\"used_gb\":$disk_used}}"
  add_check "host" "system resources" "$status" "$summary" "$evidence"
}

directory_inventory() {
  local paths=(
    "$ROOT_PATH|services root"
    "$ROOT_PATH/config|config directory"
    "$ROOT_PATH/feishu-agent-runtime/data|runtime data directory"
    "$ADAPTER_STATUS_DIR|adapter status directory"
    "$ROOT_PATH/feishu-agent-runtime/app|runtime app directory"
    "$ROOT_PATH/feishu-channel-adapter/app|adapter app directory"
  )
  local evidence="[" first="true" missing=0 entry path name exists readable
  for entry in "${paths[@]}"; do
    path="${entry%%|*}"
    name="${entry#*|}"
    exists="false"
    readable="false"
    if [[ -d "$path" ]]; then
      exists="true"
      [[ -r "$path" && -x "$path" ]] && readable="true"
    else
      missing=$((missing + 1))
    fi
    [[ "$first" == "true" ]] || evidence+=","
    first="false"
    evidence+="{\"name\":\"$(json_escape "$name")\",\"path\":\"$(json_escape "$(rel_path "$path")")\",\"exists\":$exists,\"acl_readable\":$readable,\"write_test\":\"not_performed\"}"
  done
  evidence+="]"
  if [[ "$missing" -gt 0 ]]; then
    add_check "filesystem" "directory inventory" "FAIL" "Required directories are missing." "$evidence"
  else
    add_check "filesystem" "directory inventory" "PASS" "Required directories exist; ACLs were only read." "$evidence"
  fi
}

runtime_config() {
  local rel
  rel="$(rel_path "$RUNTIME_CONFIG_PATH")"
  if [[ ! -f "$RUNTIME_CONFIG_PATH" ]]; then
    add_check "config" "runtime config" "FAIL" "Missing runtime config file." "{\"path\":\"$(json_escape "$rel")\",\"exists\":false}"
    return
  fi
  if ! has_cmd python3 && ! has_cmd python; then
    add_check "config" "runtime config" "NOT_VERIFIED" "Python is unavailable; runtime config structure was not parsed." "{\"path\":\"$(json_escape "$rel")\",\"exists\":true,\"sensitive_value_output\":\"suppressed\"}"
    return
  fi
  local py="python3"
  has_cmd python3 || py="python"
  local parsed
  parsed="$("$py" - "$RUNTIME_CONFIG_PATH" "$EXPECTED_AGENT_COUNT" <<'PY'
import json
import sys
path = sys.argv[1]
expected = int(sys.argv[2])
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(json.dumps({"ok": False, "parse_error": str(exc)}))
    sys.exit(0)
apps = data.get("apps") or []
agent_ids = [a.get("agent_id") for a in apps if a.get("agent_id")]
app_ids = [a.get("app_id") for a in apps if a.get("app_id")]
def dup_count(values):
    seen = {}
    for v in values:
        seen[v] = seen.get(v, 0) + 1
    return sum(1 for count in seen.values() if count > 1)
failures = []
if len(apps) != expected:
    failures.append(f"expected {expected} apps, got {len(apps)}")
if len(agent_ids) != expected:
    failures.append(f"agent_id count is {len(agent_ids)}")
if len(app_ids) != expected:
    failures.append(f"app_id count is {len(app_ids)}")
duplicate_agent_id_groups = dup_count(agent_ids)
duplicate_app_id_groups = dup_count(app_ids)
if duplicate_agent_id_groups:
    failures.append(f"duplicate agent_id groups: {duplicate_agent_id_groups}")
if duplicate_app_id_groups:
    failures.append(f"duplicate app_id groups: {duplicate_app_id_groups}")
print(json.dumps({
    "ok": not failures,
    "apps_count": len(apps),
    "agent_id_count": len(agent_ids),
    "app_id_count": len(app_ids),
    "duplicate_agent_id_groups": duplicate_agent_id_groups,
    "duplicate_app_id_groups": duplicate_app_id_groups,
    "app_secret_fields": sum(1 for a in apps if "app_secret" in a),
    "system_prompt_fields": sum(1 for a in apps if "system_prompt" in a),
    "failures": failures,
}, ensure_ascii=True))
PY
)"
  local ok
  ok="$(printf '%s' "$parsed" | "$py" -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo False)"
  if [[ "$ok" == "True" || "$ok" == "true" ]]; then
    add_check "config" "runtime config" "PASS" "Runtime config structure is valid; secret fields were not printed." "{\"path\":\"$(json_escape "$rel")\",\"exists\":true,\"details\":$parsed,\"sensitive_value_output\":\"suppressed\"}"
  else
    add_check "config" "runtime config" "FAIL" "Runtime config structure failed validation." "{\"path\":\"$(json_escape "$rel")\",\"exists\":true,\"details\":$parsed,\"sensitive_value_output\":\"suppressed\"}"
  fi
}

docker_checks() {
  local rel
  rel="$(rel_path "$COMPOSE_FILE")"
  if [[ -f "$COMPOSE_FILE" ]]; then
    add_check "docker" "compose file" "PASS" "Compose file exists." "{\"path\":\"$(json_escape "$rel")\",\"exists\":true}"
  else
    add_check "docker" "compose file" "FAIL" "Compose file is missing." "{\"path\":\"$(json_escape "$rel")\",\"exists\":false}"
    return
  fi
  if ! has_cmd docker; then
    add_check "docker" "docker cli" "FAIL" "Docker CLI is not available." "{}"
    return
  fi
  local docker_version compose_version
  docker_version="$(docker --version 2>&1 || true)"
  compose_version="$(docker compose version 2>&1 || true)"
  add_check "docker" "docker cli" "PASS" "Docker and Compose commands are available." "{\"docker_version\":\"$(json_escape "$docker_version")\",\"compose_version\":\"$(json_escape "$compose_version")\"}"

  if docker compose -f "$COMPOSE_FILE" config --quiet >/dev/null 2>&1; then
    add_check "docker" "compose config" "PASS" "docker compose config is valid." "{\"exit_code\":0}"
  else
    add_check "docker" "compose config" "FAIL" "docker compose config failed." "{\"exit_code\":1,\"output\":\"suppressed\"}"
  fi

  local ps_output ps_status container_count runtime_running adapter_running runtime_health
  ps_output="$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null)"
  ps_status=$?
  if [[ $ps_status -ne 0 ]]; then
    local status="WARN"
    [[ "$REQUIRE_COMPOSE_SERVICES" == "true" ]] && status="FAIL"
    add_check "docker" "compose ps" "$status" "docker compose ps could not be read." "{\"exit_code\":$ps_status,\"output\":\"suppressed\"}"
    return
  fi
  runtime_running="false"
  adapter_running="false"
  runtime_health=""
  container_count="$(printf '%s\n' "$ps_output" | grep -c '{' || true)"
  local py=""
  if has_cmd python3; then
    py="python3"
  elif has_cmd python; then
    py="python"
  fi
  if [[ -n "$py" ]]; then
    local parsed key value
    parsed="$(COMPOSE_PS_OUTPUT="$ps_output" "$py" - <<'PY'
import json
import os

raw = os.environ.get("COMPOSE_PS_OUTPUT", "")
rows = []
try:
    stripped = raw.strip()
    if stripped.startswith("["):
        parsed = json.loads(stripped)
        rows = parsed if isinstance(parsed, list) else [parsed]
    else:
        rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
except Exception:
    rows = []

def is_service(row, name):
    return row.get("Service") == name or row.get("Name") == name or row.get("Names") == name

runtime = next((row for row in rows if is_service(row, "feishu-agent-runtime")), {})
adapter = next((row for row in rows if is_service(row, "feishu-channel-adapter")), {})
print(f"container_count={len(rows)}")
print(f"runtime_running={str(runtime.get('State') == 'running').lower()}")
print(f"adapter_running={str(adapter.get('State') == 'running').lower()}")
print(f"runtime_health={runtime.get('Health') or ''}")
PY
)"
    while IFS='=' read -r key value; do
      value="${value//$'\r'/}"
      case "$key" in
        container_count) container_count="$value" ;;
        runtime_running) runtime_running="$value" ;;
        adapter_running) adapter_running="$value" ;;
        runtime_health) runtime_health="$value" ;;
      esac
    done <<< "$parsed"
  else
    if printf '%s\n' "$ps_output" | grep -q '"Service":"feishu-agent-runtime".*"State":"running"\|"Name":"feishu-agent-runtime".*"State":"running"'; then
      runtime_running="true"
    fi
    if printf '%s\n' "$ps_output" | grep -q '"Service":"feishu-channel-adapter".*"State":"running"\|"Name":"feishu-channel-adapter".*"State":"running"'; then
      adapter_running="true"
    fi
    if printf '%s\n' "$ps_output" | grep -q '"Service":"feishu-agent-runtime".*"Health":"healthy"\|"Name":"feishu-agent-runtime".*"Health":"healthy"'; then
      runtime_health="healthy"
    fi
  fi
  local status="PASS"
  local summary="Compose state was read."
  local failures="[]"
  if [[ "$REQUIRE_COMPOSE_SERVICES" == "true" ]]; then
    local parts=()
    [[ "$runtime_running" == "true" ]] || parts+=("runtime not running")
    [[ "$adapter_running" == "true" ]] || parts+=("adapter not running")
    [[ "$runtime_health" == "healthy" ]] || parts+=("runtime not healthy")
    if [[ ${#parts[@]} -gt 0 ]]; then
      status="FAIL"
      summary="Required Compose services are not all running and healthy."
      failures="["
      local first="true"
      for item in "${parts[@]}"; do
        [[ "$first" == "true" ]] || failures+=","
        first="false"
        failures+="\"$(json_escape "$item")\""
      done
      failures+="]"
    fi
  elif [[ "$container_count" -eq 0 ]]; then
    status="NOT_VERIFIED"
    summary="No Compose containers are currently associated with this file."
  fi
  add_check "docker" "compose ps" "$status" "$summary" "{\"container_count\":$container_count,\"runtime_running\":$runtime_running,\"adapter_running\":$adapter_running,\"runtime_health\":\"$(json_escape "$runtime_health")\",\"require_compose_services\":$REQUIRE_COMPOSE_SERVICES,\"failures\":$failures}"
}

port_checks() {
  IFS=',' read -r -a port_array <<< "$PORTS"
  local port method listening rows status summary
  for port in "${port_array[@]}"; do
    port="${port//[[:space:]]/}"
    method="unavailable"
    listening="null"
    if has_cmd ss; then
      method="ss"
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"; then
        listening="true"
      else
        listening="false"
      fi
    elif has_cmd netstat; then
      method="netstat"
      if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"; then
        listening="true"
      else
        listening="false"
      fi
    fi
    if [[ "$listening" == "null" ]]; then
      add_check "network" "port $port" "NOT_VERIFIED" "Port state could not be determined." "{\"method\":\"$method\"}"
      continue
    fi
    status="PASS"
    summary="Port state observed."
    if [[ "$PORT_MODE" == "RequireFree" && "$listening" == "true" ]]; then
      status="FAIL"
      summary="Port is listening but the policy requires it to be free."
    elif [[ "$PORT_MODE" == "RequireListening" && "$listening" == "false" ]]; then
      status="FAIL"
      summary="Port is not listening but the policy requires it to be listening."
    fi
    add_check "network" "port $port" "$status" "$summary" "{\"mode\":\"$(json_escape "$PORT_MODE")\",\"method\":\"$method\",\"listening\":$listening}"
  done
}

runtime_health() {
  if ! has_cmd curl; then
    local status="NOT_VERIFIED"
    [[ "$REQUIRE_RUNTIME_HEALTH" == "true" ]] && status="FAIL"
    add_check "network" "runtime health" "$status" "curl is unavailable; runtime health was not checked." "{\"base_url\":\"$(json_escape "$BASE_URL")\"}"
    return
  fi
  local body status="PASS" summary ok="false"
  body="$(curl -fsS --max-time 8 "$BASE_URL/health" 2>/dev/null || true)"
  if [[ -z "$body" ]]; then
    status="NOT_VERIFIED"
    [[ "$REQUIRE_RUNTIME_HEALTH" == "true" ]] && status="FAIL"
    add_check "network" "runtime health" "$status" "Runtime health endpoint is not reachable." "{\"base_url\":\"$(json_escape "$BASE_URL")\",\"error\":\"suppressed\"}"
    return
  fi
  if printf '%s' "$body" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    ok="true"
    summary="Runtime health endpoint is reachable."
  else
    status="WARN"
    [[ "$REQUIRE_RUNTIME_HEALTH" == "true" ]] && status="FAIL"
    summary="Runtime health endpoint responded but did not report ok=true."
  fi
  add_check "network" "runtime health" "$status" "$summary" "{\"base_url\":\"$(json_escape "$BASE_URL")\",\"ok\":$ok,\"response_body\":\"suppressed\"}"
}

network_probe() {
  local name="$1"
  local url="$2"
  if ! has_cmd curl; then
    add_check "network" "$name" "NOT_VERIFIED" "curl is unavailable; network probe was not checked." "{\"probe\":\"$(json_escape "$url")\"}"
    return
  fi
  local code
  code="$(curl -I -L -sS --max-time 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)"
  if [[ "$code" =~ ^[0-9][0-9][0-9]$ && "$code" != "000" ]]; then
    add_check "network" "$name" "PASS" "Network probe reached the target and received an HTTP response." "{\"probe\":\"$(json_escape "$url")\",\"status_code\":$code}"
  else
    add_check "network" "$name" "WARN" "Network probe did not reach the target." "{\"probe\":\"$(json_escape "$url")\",\"error\":\"suppressed\"}"
  fi
}

adapter_status() {
  local rel
  rel="$(rel_path "$ADAPTER_STATUS_DIR")"
  if [[ ! -d "$ADAPTER_STATUS_DIR" ]]; then
    local status="NOT_VERIFIED"
    [[ "$REQUIRE_ADAPTER_CONNECTED" == "true" ]] && status="FAIL"
    add_check "adapter" "worker status files" "$status" "Adapter status directory is missing." "{\"path\":\"$(json_escape "$rel")\",\"exists\":false}"
    return
  fi
  local py="python3"
  if ! has_cmd python3 && has_cmd python; then py="python"; fi
  if ! has_cmd "$py"; then
    add_check "adapter" "worker status files" "NOT_VERIFIED" "Python is unavailable; adapter status files were not parsed." "{\"path\":\"$(json_escape "$rel")\",\"exists\":true,\"app_id_output\":\"suppressed\"}"
    return
  fi
  local parsed ok status summary
  parsed="$("$py" - "$ADAPTER_STATUS_DIR" "$EXPECTED_AGENT_COUNT" <<'PY'
import glob
import json
import os
import sys
path = sys.argv[1]
expected = int(sys.argv[2])
files = glob.glob(os.path.join(path, "*.json"))
bad = 0
counts = {}
for file_path in files:
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        state = data.get("status") or "missing"
        counts[state] = counts.get(state, 0) + 1
    except Exception:
        bad += 1
connected = counts.get("connected", 0)
ok = len(files) == expected and connected == expected and bad == 0
print(json.dumps({
    "ok": ok,
    "file_count": len(files),
    "expected_file_count": expected,
    "connected_count": connected,
    "bad_json_count": bad,
    "status_counts": counts,
}, ensure_ascii=True))
PY
)"
  ok="$(printf '%s' "$parsed" | "$py" -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo False)"
  status="PASS"
  summary="Adapter worker status files are present and connected."
  if [[ "$ok" != "True" && "$ok" != "true" ]]; then
    status="WARN"
    [[ "$REQUIRE_ADAPTER_CONNECTED" == "true" ]] && status="FAIL"
    summary="Adapter worker status files are incomplete or not all connected."
  fi
  add_check "adapter" "worker status files" "$status" "$summary" "{\"path\":\"$(json_escape "$rel")\",\"details\":$parsed,\"app_id_output\":\"suppressed\"}"
}

compose_logs() {
  if ! has_cmd docker || [[ ! -f "$COMPOSE_FILE" ]]; then
    add_check "logs" "compose logs" "NOT_VERIFIED" "Docker CLI or compose file is unavailable." "{}"
    return
  fi
  local services=("feishu-agent-runtime" "feishu-channel-adapter")
  local rows="[" first="true" total=0 failures=0 service output count exit_code
  for service in "${services[@]}"; do
    output="$(docker compose -f "$COMPOSE_FILE" logs "--tail=$LOG_TAIL" "$service" 2>/dev/null)"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      failures=$((failures + 1))
      count="null"
    else
      count="$(printf '%s\n' "$output" | grep -E 'ERROR|WARNING|Traceback|Exception|exited|failed|retrying|Runtime returned status=error' | wc -l | tr -d ' ')"
      total=$((total + count))
    fi
    [[ "$first" == "true" ]] || rows+=","
    first="false"
    rows+="{\"service\":\"$(json_escape "$service")\",\"problem_line_count\":$count,\"command_exit_code\":$exit_code}"
  done
  rows+="]"
  local status="PASS" summary="Compose logs were scanned without printing raw log lines."
  if [[ "$failures" -gt 0 ]]; then
    status="NOT_VERIFIED"
    summary="Some compose logs could not be read."
  elif [[ "$total" -gt 0 ]]; then
    status="WARN"
    [[ "$FAIL_ON_LOG_PROBLEMS" == "true" ]] && status="FAIL"
    summary="Compose logs contain problem-pattern matches; raw lines were suppressed."
  fi
  add_check "logs" "compose logs" "$status" "$summary" "{\"tail\":$LOG_TAIL,\"raw_log_output\":\"suppressed\",\"services\":$rows}"
}

backup_inventory() {
  local items=(
    "docker-compose.full.yml"
    "config/agent-runtime-config.json"
    "feishu-agent-runtime/.env"
    "feishu-channel-adapter/.env"
    "feishu-agent-runtime/data/runtime.sqlite3"
    "feishu-agent-runtime/data/runtime.sqlite3-wal"
    "feishu-agent-runtime/data/runtime.sqlite3-shm"
  )
  local rows="[" first="true" item exists
  for item in "${items[@]}"; do
    exists="false"
    [[ -e "$ROOT_PATH/$item" ]] && exists="true"
    [[ "$first" == "true" ]] || rows+=","
    first="false"
    rows+="{\"path\":\"$(json_escape "$item")\",\"exists\":$exists,\"content_output\":\"suppressed\"}"
  done
  rows+="]"
  add_check "rollback" "backup inventory" "PASS" "Backup candidate inventory was collected; no backup was created." "$rows"
  add_check "rollback" "external backup target" "NOT_VERIFIED" "Operator must confirm the off-host backup target and rollback owner before deployment." "{\"backup_created_by_script\":false,\"rollback_test_performed\":false}"
}

release_gate() {
  add_check "release_gate" "forbidden operations" "PASS" "This script performed only read-only checks." "{\"forbidden_operations\":[\"docker compose up\",\"docker compose down\",\"docker compose restart\",\"docker compose pull\",\"docker compose build\",\"docker create/run/rm\",\"write env files\",\"write runtime config\",\"change 1Panel settings\"],\"performed\":false}"
  add_check "release_gate" "formal deploy" "NOT_VERIFIED" "Formal deployment remains blocked until the sanitized evidence package is reviewed and explicitly approved." "{\"allowed_stage\":\"1Panel read-only pre-check\",\"formal_deploy_allowed\":false,\"known_blocker\":\"Agents cannot yet emit real Feishu rich-text mentions for automatic multi-agent relay.\"}"
}

system_resources
directory_inventory
env_key_report "$RUNTIME_ENV_PATH" "config" "runtime env" "CHANNEL_AUTH_TOKEN" "OPENAI_API_KEY" "OPENAI_BASE_URL" "OPENAI_MODEL"
env_key_report "$ADAPTER_ENV_PATH" "config" "adapter env" "RUNTIME_AUTH_TOKEN" "CHANNEL_TRANSPORT" "CHANNEL_REQUIRE_MENTION" "CHANNEL_DROP_SELF_SENT"
runtime_config
docker_checks
port_checks
runtime_health
if [[ "$SKIP_FEISHU_NETWORK_PROBE" != "true" ]]; then
  network_probe "feishu open platform" "https://open.feishu.cn"
fi
if [[ -n "$NETWORK_PROBE_URL" ]]; then
  network_probe "custom provider endpoint" "$NETWORK_PROBE_URL"
fi
adapter_status
compose_logs
backup_inventory
release_gate

RESULT_JSON="{\"ok\":$( [[ "$FAIL_COUNT" -eq 0 ]] && echo true || echo false ),\"generated_at\":\"$(date -Iseconds)\",\"root_path\":\".\",\"base_url\":\"$(json_escape "$BASE_URL")\",\"expected_agent_count\":$EXPECTED_AGENT_COUNT,\"port_mode\":\"$(json_escape "$PORT_MODE")\",\"summary\":{\"pass\":$PASS_COUNT,\"warn\":$WARN_COUNT,\"fail\":$FAIL_COUNT,\"not_verified\":$NOT_VERIFIED_COUNT},\"checks\":[$CHECKS_JSON]}"

if [[ "$JSON_OUTPUT" == "true" ]]; then
  printf '%s\n' "$RESULT_JSON"
else
  printf '1Panel read-only pre-check\n'
  printf 'ok: %s\n' "$( [[ "$FAIL_COUNT" -eq 0 ]] && echo true || echo false )"
  printf 'pass: %s\nwarn: %s\nfail: %s\nnot_verified: %s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$NOT_VERIFIED_COUNT"
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
