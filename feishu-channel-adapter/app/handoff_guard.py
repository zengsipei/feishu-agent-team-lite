import hashlib
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

TASK_ID_PATTERNS = (
    re.compile(r"(?:任务\s*ID|任务ID|Task\s*ID|Work\s*Item\s*ID)[:：]\s*([A-Za-z0-9_.:-]+)", re.IGNORECASE),
    re.compile(r"\b(WI-[A-Za-z0-9_.:-]+)\b", re.IGNORECASE),
)


@dataclass(frozen=True)
class HandoffGuardDecision:
    allowed: bool
    key: str
    task_key: str
    count: int


class HandoffLoopGuard:
    def __init__(
        self,
        *,
        status_dir: Path,
        enabled: bool = True,
        ttl_seconds: int = 600,
        max_count: int = 1,
        clock=time.time,
    ):
        self.enabled = enabled
        self.ttl_seconds = max(1, ttl_seconds)
        self.max_count = max(1, max_count)
        self.clock = clock
        self.path = status_dir / "handoff-guard.json"

    def check(
        self,
        *,
        chat_id: str,
        from_agent_id: str,
        to_agent_id: str,
        text: str,
    ) -> HandoffGuardDecision:
        return self._decide(
            chat_id=chat_id,
            from_agent_id=from_agent_id,
            to_agent_id=to_agent_id,
            text=text,
            record=False,
        )

    def record(
        self,
        *,
        chat_id: str,
        from_agent_id: str,
        to_agent_id: str,
        text: str,
    ) -> HandoffGuardDecision:
        return self._decide(
            chat_id=chat_id,
            from_agent_id=from_agent_id,
            to_agent_id=to_agent_id,
            text=text,
            record=True,
        )

    def _decide(
        self,
        *,
        chat_id: str,
        from_agent_id: str,
        to_agent_id: str,
        text: str,
        record: bool,
    ) -> HandoffGuardDecision:
        task_key = extract_task_key(text)
        key = _fingerprint("|".join([chat_id, from_agent_id, to_agent_id, task_key]))
        if not self.enabled:
            return HandoffGuardDecision(allowed=True, key=key, task_key=task_key, count=0)

        now = float(self.clock())
        entries = self._load_entries(now)
        count = int(entries.get(key, {}).get("count") or 0)
        if count >= self.max_count:
            self._save_entries(entries)
            return HandoffGuardDecision(allowed=False, key=key, task_key=task_key, count=count)

        if record:
            entries[key] = {
                "count": count + 1,
                "updated_at": now,
                "task_key": task_key,
                "from_agent_id": from_agent_id,
                "to_agent_id": to_agent_id,
            }
            self._save_entries(entries)
            count += 1
        return HandoffGuardDecision(allowed=True, key=key, task_key=task_key, count=count)

    def _load_entries(self, now: float) -> dict:
        try:
            entries = json.loads(self.path.read_text(encoding="utf-8")).get("entries", {})
        except (OSError, AttributeError, json.JSONDecodeError):
            return {}
        if not isinstance(entries, dict):
            return {}
        return {
            key: entry
            for key, entry in entries.items()
            if isinstance(entry, dict) and now - float(entry.get("updated_at") or 0) <= self.ttl_seconds
        }

    def _save_entries(self, entries: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_name(f"{self.path.name}.{uuid4().hex}.tmp")
        temp.write_text(
            json.dumps({"version": 1, "entries": entries}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temp.replace(self.path)


def extract_task_key(text: str) -> str:
    value = text or ""
    for pattern in TASK_ID_PATTERNS:
        match = pattern.search(value)
        if match:
            return match.group(1).strip()

    normalized = re.sub(r"\s+", " ", value.strip())
    if not normalized:
        return "empty"
    return "text:" + _fingerprint(normalized[:500])


def _fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]
