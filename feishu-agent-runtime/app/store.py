import json
import sqlite3
from contextlib import closing
from pathlib import Path
from typing import Any


class RuntimeStore:
    def __init__(self, database_path: Path):
        self.database_path = database_path
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self.init_schema()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.database_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def init_schema(self) -> None:
        with closing(self.connect()) as conn:
            with conn:
                conn.executescript(
                    """
                    CREATE TABLE IF NOT EXISTS sessions (
                        id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL,
                        chat_id TEXT NOT NULL,
                        thread_id TEXT,
                        sender_id TEXT,
                        agent_id TEXT NOT NULL,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        metadata_json TEXT NOT NULL DEFAULT '{}'
                    );

                    CREATE TABLE IF NOT EXISTS messages (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        session_id TEXT NOT NULL,
                        role TEXT NOT NULL,
                        content TEXT NOT NULL,
                        source_type TEXT NOT NULL DEFAULT 'channel',
                        source_id TEXT,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        metadata_json TEXT NOT NULL DEFAULT '{}',
                        FOREIGN KEY(session_id) REFERENCES sessions(id)
                    );

                    CREATE TABLE IF NOT EXISTS events (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        event_id TEXT,
                        event_type TEXT NOT NULL,
                        project_id TEXT,
                        chat_id TEXT,
                        agent_id TEXT,
                        payload_json TEXT NOT NULL,
                        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                    );

                    CREATE UNIQUE INDEX IF NOT EXISTS idx_events_event_id
                        ON events(event_id)
                        WHERE event_id IS NOT NULL AND event_id != '';

                    CREATE INDEX IF NOT EXISTS idx_messages_session_created
                        ON messages(session_id, created_at);
                    """
                )

    def session_id_for(
        self,
        *,
        project_id: str,
        chat_id: str,
        thread_id: str | None,
        sender_id: str | None,
        agent_id: str,
    ) -> str:
        thread_or_sender = thread_id or sender_id or "chat"
        return f"{project_id}:{chat_id}:{thread_or_sender}:{agent_id}"

    def upsert_session(
        self,
        *,
        session_id: str,
        project_id: str,
        chat_id: str,
        thread_id: str | None,
        sender_id: str | None,
        agent_id: str,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        with closing(self.connect()) as conn:
            with conn:
                conn.execute(
                    """
                    INSERT INTO sessions (
                        id, project_id, chat_id, thread_id, sender_id, agent_id, metadata_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        updated_at = CURRENT_TIMESTAMP,
                        metadata_json = excluded.metadata_json
                    """,
                    (
                        session_id,
                        project_id,
                        chat_id,
                        thread_id,
                        sender_id,
                        agent_id,
                        json.dumps(metadata or {}, ensure_ascii=False),
                    ),
                )

    def record_event(
        self,
        *,
        event_id: str | None,
        event_type: str,
        project_id: str | None,
        chat_id: str | None,
        agent_id: str | None,
        payload: dict[str, Any],
    ) -> bool:
        try:
            with closing(self.connect()) as conn:
                with conn:
                    conn.execute(
                        """
                        INSERT INTO events (event_id, event_type, project_id, chat_id, agent_id, payload_json)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (
                            event_id,
                            event_type,
                            project_id,
                            chat_id,
                            agent_id,
                            json.dumps(payload, ensure_ascii=False),
                        ),
                    )
            return True
        except sqlite3.IntegrityError:
            return False

    def add_message(
        self,
        *,
        session_id: str,
        role: str,
        content: str,
        source_type: str = "channel",
        source_id: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> int:
        with closing(self.connect()) as conn:
            with conn:
                cur = conn.execute(
                    """
                    INSERT INTO messages (session_id, role, content, source_type, source_id, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        session_id,
                        role,
                        content,
                        source_type,
                        source_id,
                        json.dumps(metadata or {}, ensure_ascii=False),
                    ),
                )
                conn.execute(
                    "UPDATE sessions SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                    (session_id,),
                )
                return int(cur.lastrowid)

    def recent_messages(self, session_id: str, limit: int) -> list[dict[str, Any]]:
        with closing(self.connect()) as conn:
            rows = conn.execute(
                """
                SELECT role, content, source_type, source_id, metadata_json, created_at
                FROM messages
                WHERE session_id = ?
                ORDER BY id DESC
                LIMIT ?
                """,
                (session_id, limit),
            ).fetchall()

        messages = []
        for row in reversed(rows):
            messages.append(
                {
                    "role": row["role"],
                    "content": row["content"],
                    "source_type": row["source_type"],
                    "source_id": row["source_id"],
                    "metadata": json.loads(row["metadata_json"]),
                    "created_at": row["created_at"],
                }
            )
        return messages
