#!/usr/bin/env python3
"""Summarize 1Panel read-only pre-check JSON without leaking raw evidence."""

import argparse
import json
import sys
from typing import Any, Dict, List, Optional


def load_json(path: str) -> Dict[str, Any]:
    if path == "-":
        text = sys.stdin.read()
    else:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    return json.loads(text)


def checks(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    rows = data.get("checks", [])
    if isinstance(rows, list):
        return [row for row in rows if isinstance(row, dict)]
    return []


def evidence_items(check: Dict[str, Any]) -> List[Dict[str, Any]]:
    evidence = check.get("evidence")
    if isinstance(evidence, dict):
        return [evidence]
    if isinstance(evidence, list):
        return [item for item in evidence if isinstance(item, dict)]
    return []


def first_evidence(check: Dict[str, Any]) -> Dict[str, Any]:
    items = evidence_items(check)
    return items[0] if items else {}


def details_or_first(check: Dict[str, Any]) -> Dict[str, Any]:
    first = first_evidence(check)
    details = first.get("details")
    if isinstance(details, dict):
        return details
    return first


def find_check(rows: List[Dict[str, Any]], area: str, name: str) -> Optional[Dict[str, Any]]:
    for row in rows:
        if row.get("area") == area and row.get("name") == name:
            return row
    return None


def checks_by_area(rows: List[Dict[str, Any]], area: str) -> List[Dict[str, Any]]:
    return [row for row in rows if row.get("area") == area]


def check_status(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    return str(row.get("status", "unknown"))


def safe_count(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, (int, float, str, bool)):
        return str(value)
    return "n/a"


def markdown_table(headers: List[str], rows: List[List[str]]) -> List[str]:
    output = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        output.append("| " + " | ".join(str(item).replace("\n", " ") for item in row) + " |")
    return output


def status_summary(data: Dict[str, Any], rows: List[Dict[str, Any]]) -> Dict[str, int]:
    summary = data.get("summary")
    if isinstance(summary, dict):
        return {
            "pass": int(summary.get("pass", 0) or 0),
            "warn": int(summary.get("warn", 0) or 0),
            "fail": int(summary.get("fail", 0) or 0),
            "not_verified": int(summary.get("not_verified", 0) or 0),
        }
    counts = {"pass": 0, "warn": 0, "fail": 0, "not_verified": 0}
    for row in rows:
        status = str(row.get("status", "")).lower()
        if status in counts:
            counts[status] += 1
    return counts


def summarize_host(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    first = first_evidence(row)
    memory = first.get("memory") if isinstance(first.get("memory"), dict) else {}
    disk = first.get("disk") if isinstance(first.get("disk"), dict) else {}
    return (
        f"{check_status(row)}; memory total={safe_count(memory.get('total_mb'))} MB, "
        f"available={safe_count(memory.get('available_mb'))} MB; "
        f"disk free={safe_count(disk.get('free_gb'))} GB, used={safe_count(disk.get('used_gb'))} GB"
    )


def summarize_directory(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    items = evidence_items(row)
    total = len(items)
    existing = sum(1 for item in items if item.get("exists") is True)
    readable = sum(1 for item in items if item.get("acl_readable") is True)
    return f"{check_status(row)}; paths={total}, existing={existing}, acl_readable={readable}, write_test=not_performed"


def summarize_env(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    first = first_evidence(row)
    missing = first.get("missing_keys")
    blank = first.get("blank_keys")
    missing_count = len(missing) if isinstance(missing, list) else 0
    blank_count = len(blank) if isinstance(blank, list) else 0
    return (
        f"{check_status(row)}; required_keys={safe_count(first.get('required_key_count'))}, "
        f"missing={missing_count}, blank={blank_count}, values=suppressed"
    )


def summarize_runtime_config(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    data = details_or_first(row)
    failures = data.get("failures")
    failure_count = len(failures) if isinstance(failures, list) else 0
    return (
        f"{check_status(row)}; apps={safe_count(data.get('apps_count'))}, "
        f"agent_id={safe_count(data.get('agent_id_count'))}, "
        f"app_id={safe_count(data.get('app_id_count'))}, "
        f"duplicate_agent_groups={safe_count(data.get('duplicate_agent_id_groups'))}, "
        f"duplicate_app_groups={safe_count(data.get('duplicate_app_id_groups'))}, "
        f"failures={failure_count}, secrets=suppressed"
    )


def summarize_compose(rows: List[Dict[str, Any]]) -> str:
    file_row = find_check(rows, "docker", "compose file")
    cli_row = find_check(rows, "docker", "docker cli")
    config_row = find_check(rows, "docker", "compose config")
    ps_row = find_check(rows, "docker", "compose ps")
    ps = first_evidence(ps_row or {})
    containers = ps.get("containers")
    if isinstance(containers, list):
        service_bits = []
        for item in containers:
            if not isinstance(item, dict):
                continue
            service = item.get("service") or item.get("name") or "unknown"
            state = item.get("state") or "unknown"
            health = item.get("health") or "n/a"
            service_bits.append(f"{service}:{state}/{health}")
        services = ", ".join(service_bits) if service_bits else "none"
    else:
        services = "not listed"
    return (
        f"file={check_status(file_row)}, cli={check_status(cli_row)}, "
        f"config={check_status(config_row)}, ps={check_status(ps_row)}, "
        f"containers={safe_count(ps.get('container_count'))}, services={services}"
    )


def summarize_ports(rows: List[Dict[str, Any]]) -> str:
    ports = [row for row in checks_by_area(rows, "network") if str(row.get("name", "")).startswith("port ")]
    if not ports:
        return "not present"
    parts = []
    for row in ports:
        first = first_evidence(row)
        parts.append(
            f"{row.get('name')}={row.get('status')} "
            f"(mode={safe_count(first.get('mode'))}, listening={safe_count(first.get('listening'))}, method={safe_count(first.get('method'))})"
        )
    return "; ".join(parts)


def summarize_runtime_health(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    first = first_evidence(row)
    return f"{check_status(row)}; ok={safe_count(first.get('ok'))}; response_body=suppressed"


def summarize_network(rows: List[Dict[str, Any]]) -> str:
    network_rows = [
        row
        for row in checks_by_area(rows, "network")
        if row.get("name") != "runtime health" and not str(row.get("name", "")).startswith("port ")
    ]
    if not network_rows:
        return "not present"
    parts = []
    for row in network_rows:
        first = first_evidence(row)
        status_code = first.get("status_code")
        suffix = f", status_code={status_code}" if status_code is not None else ""
        parts.append(f"{row.get('name')}={row.get('status')}{suffix}")
    return "; ".join(parts)


def summarize_adapter(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    data = details_or_first(row)
    return (
        f"{check_status(row)}; files={safe_count(data.get('file_count'))}, "
        f"expected={safe_count(data.get('expected_file_count'))}, "
        f"connected={safe_count(data.get('connected_count'))}, "
        f"bad_json={safe_count(data.get('bad_json_count'))}, app_ids=suppressed"
    )


def summarize_logs(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    first = first_evidence(row)
    services = first.get("services")
    total = 0
    service_count = 0
    if isinstance(services, list):
        service_count = len(services)
        for item in services:
            if isinstance(item, dict):
                total += int(item.get("problem_line_count", 0) or 0)
    return f"{check_status(row)}; services={service_count}, problem_line_count={total}, raw_logs=suppressed"


def summarize_backup(row: Optional[Dict[str, Any]]) -> str:
    if not row:
        return "not present"
    items = evidence_items(row)
    existing = sum(1 for item in items if item.get("exists") is True)
    return f"{check_status(row)}; candidates={len(items)}, existing={existing}, contents=suppressed"


def rows_for_status(
    data: Dict[str, Any], rows: List[Dict[str, Any]], key: str, status: str
) -> List[Dict[str, str]]:
    explicit = data.get(key)
    if isinstance(explicit, list):
        return [
            {
                "area": str(item.get("area", "")),
                "name": str(item.get("name", "")),
                "summary": str(item.get("summary", "")),
            }
            for item in explicit
            if isinstance(item, dict)
        ]
    return [
        {
            "area": str(row.get("area", "")),
            "name": str(row.get("name", "")),
            "summary": str(row.get("summary", "")),
        }
        for row in rows
        if row.get("status") == status
    ]


def build_markdown(data: Dict[str, Any], args: argparse.Namespace) -> str:
    rows = checks(data)
    summary = status_summary(data, rows)
    ok = bool(data.get("ok"))
    source = args.source_label or "pre-check json"
    runtime_mode = args.runtime_mode or "unspecified"
    server_label = args.server_label or "suppressed"
    deployment_label = args.deployment_label or "suppressed"

    key_rows = [
        ["Host resources", summarize_host(find_check(rows, "host", "system resources"))],
        ["Directory layout", summarize_directory(find_check(rows, "filesystem", "directory inventory"))],
        ["Runtime env", summarize_env(find_check(rows, "config", "runtime env"))],
        ["Adapter env", summarize_env(find_check(rows, "config", "adapter env"))],
        ["Runtime config", summarize_runtime_config(find_check(rows, "config", "runtime config"))],
        ["Docker/Compose", summarize_compose(rows)],
        ["Port state", summarize_ports(rows)],
        ["Runtime health", summarize_runtime_health(find_check(rows, "network", "runtime health"))],
        ["Network", summarize_network(rows)],
        ["Adapter status", summarize_adapter(find_check(rows, "adapter", "worker status files"))],
        ["Logs", summarize_logs(find_check(rows, "logs", "compose logs"))],
        ["Backup inventory", summarize_backup(find_check(rows, "rollback", "backup inventory"))],
        ["Off-host backup target", check_status(find_check(rows, "rollback", "external backup target"))],
        ["Formal deploy approval", check_status(find_check(rows, "release_gate", "formal deploy"))],
    ]

    blocking = rows_for_status(data, rows, "blocking_failures", "FAIL")
    warnings = rows_for_status(data, rows, "warnings", "WARN")
    not_verified = rows_for_status(data, rows, "not_verified", "NOT_VERIFIED")

    out: List[str] = []
    out.append("# Sanitized 1Panel Read-Only Pre-Check Summary")
    out.append("")
    out.append(f"- Source: {source}")
    out.append(f"- Server label: {server_label}")
    out.append(f"- Deployment directory label: {deployment_label}")
    out.append(f"- Runtime mode: {runtime_mode}")
    out.append(f"- Generated at: {safe_count(data.get('generated_at'))}")
    out.append(f"- Overall ok: {str(ok).lower()}")
    out.append(f"- Expected agent count: {safe_count(data.get('expected_agent_count'))}")
    out.append(f"- Port mode: {safe_count(data.get('port_mode'))}")
    out.append("- Raw env values, app IDs, app secrets, status file bodies, response bodies, and logs: suppressed")
    out.append("")
    out.extend(markdown_table(
        ["pass", "warn", "fail", "not_verified"],
        [[str(summary["pass"]), str(summary["warn"]), str(summary["fail"]), str(summary["not_verified"])]],
    ))
    out.append("")
    out.append("## Key Evidence")
    out.append("")
    out.extend(markdown_table(["Area", "Sanitized Evidence"], key_rows))
    out.append("")
    out.append("## Blocking Failures")
    out.append("")
    if blocking:
        out.extend(markdown_table(["Area", "Name", "Summary"], [[x["area"], x["name"], x["summary"]] for x in blocking]))
    else:
        out.append("- None reported by the pre-check.")
    out.append("")
    out.append("## Warnings")
    out.append("")
    if warnings:
        out.extend(markdown_table(["Area", "Name", "Summary"], [[x["area"], x["name"], x["summary"]] for x in warnings]))
    else:
        out.append("- None reported by the pre-check.")
    out.append("")
    out.append("## Not Verified")
    out.append("")
    if not_verified:
        out.extend(markdown_table(["Area", "Name", "Summary"], [[x["area"], x["name"], x["summary"]] for x in not_verified]))
    else:
        out.append("- None.")
    out.append("")
    out.append("## Release Recommendation")
    out.append("")
    if summary["fail"] > 0:
        out.append("- Do not proceed. Resolve blocking failures with read-only diagnosis only, then rerun the pre-check.")
    else:
        out.append("- Evidence can move to review, but formal deployment remains blocked until the user explicitly approves the next stage.")
    out.append("- Off-host backup target and rollback owner must be confirmed before deployment approval.")
    out.append("- Do not run start, stop, restart, recreate, build, pull, deploy, or configuration write operations in this stage.")
    return "\n".join(out) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize read-only 1Panel pre-check JSON into sanitized Markdown.")
    parser.add_argument("input", nargs="?", default="-", help="Pre-check JSON file, or '-' for stdin.")
    parser.add_argument("--source-label", default="", help="Non-sensitive source label for the evidence.")
    parser.add_argument("--server-label", default="", help="Non-sensitive server label; avoid private host/IP values.")
    parser.add_argument("--deployment-label", default="", help="Non-sensitive deployment directory label.")
    parser.add_argument("--runtime-mode", choices=["pre-deploy", "already-running", "unspecified"], default="unspecified")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    data = load_json(args.input)
    sys.stdout.write(build_markdown(data, args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
