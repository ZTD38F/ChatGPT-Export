from __future__ import annotations

from pathlib import Path
import json
import sqlite3
import threading
import time
import uuid


SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  run_dir TEXT,
  progress_json TEXT NOT NULL DEFAULT '{}',
  error_code TEXT,
  error_message TEXT
);
CREATE TABLE IF NOT EXISTS object_state (
  workspace_key TEXT NOT NULL,
  object_type TEXT NOT NULL,
  object_id TEXT NOT NULL,
  remote_updated TEXT,
  sha256 TEXT,
  local_path TEXT,
  verified INTEGER NOT NULL DEFAULT 0,
  last_seen_run TEXT,
  PRIMARY KEY (workspace_key, object_type, object_id)
);
"""


class Database:
    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.RLock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as conn:
            conn.executescript(SCHEMA)

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=30, isolation_level=None, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=30000")
        return conn

    def create_job(self, kind: str = "full") -> str:
        job_id = uuid.uuid4().hex
        now = time.time()
        with self._lock, self.connect() as conn:
            conn.execute(
                "INSERT INTO jobs(id,kind,status,created_at,updated_at,progress_json) VALUES(?,?,?,?,?,?)",
                (job_id, kind, "QUEUED", now, now, "{}"),
            )
        return job_id

    def update_job(self, job_id: str, *, status: str | None = None, run_dir: str | None = None,
                   progress: dict | None = None, error_code: str | None = None,
                   error_message: str | None = None) -> None:
        fields = ["updated_at=?"]
        values: list[object] = [time.time()]
        if status is not None:
            fields.append("status=?"); values.append(status)
        if run_dir is not None:
            fields.append("run_dir=?"); values.append(run_dir)
        if progress is not None:
            fields.append("progress_json=?"); values.append(json.dumps(progress, separators=(",", ":")))
        if error_code is not None:
            fields.append("error_code=?"); values.append(error_code)
        if error_message is not None:
            fields.append("error_message=?"); values.append(error_message[:2000])
        values.append(job_id)
        with self._lock, self.connect() as conn:
            conn.execute(f"UPDATE jobs SET {', '.join(fields)} WHERE id=?", values)

    def job(self, job_id: str) -> dict | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        return self._row_job(row) if row else None

    def latest_job(self) -> dict | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM jobs ORDER BY created_at DESC LIMIT 1").fetchone()
        return self._row_job(row) if row else None

    @staticmethod
    def _row_job(row: sqlite3.Row) -> dict:
        result = dict(row)
        try:
            result["progress"] = json.loads(result.pop("progress_json"))
        except Exception:
            result["progress"] = {}
        return result

    def object_state(self, workspace_key: str, object_type: str, object_id: str) -> dict | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM object_state WHERE workspace_key=? AND object_type=? AND object_id=?",
                (workspace_key, object_type, object_id),
            ).fetchone()
        return dict(row) if row else None

    def upsert_object(self, *, workspace_key: str, object_type: str, object_id: str,
                      remote_updated: str | None, sha256: str | None, local_path: str | None,
                      verified: bool, run_id: str) -> None:
        with self._lock, self.connect() as conn:
            conn.execute(
                """
                INSERT INTO object_state(workspace_key,object_type,object_id,remote_updated,sha256,local_path,verified,last_seen_run)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(workspace_key,object_type,object_id) DO UPDATE SET
                  remote_updated=excluded.remote_updated,
                  sha256=excluded.sha256,
                  local_path=excluded.local_path,
                  verified=excluded.verified,
                  last_seen_run=excluded.last_seen_run
                """,
                (workspace_key, object_type, object_id, remote_updated, sha256, local_path, int(verified), run_id),
            )
