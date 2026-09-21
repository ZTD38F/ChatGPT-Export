from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3

from .config import Settings


def cmd_doctor(settings: Settings) -> int:
    checks = []
    checks.append(("state_dir", settings.state_dir.exists() and settings.state_dir.is_dir(), str(settings.state_dir)))
    checks.append(("data_dir", settings.data_dir.exists() and settings.data_dir.is_dir(), str(settings.data_dir)))
    checks.append(("key_file", settings.key_file.exists(), str(settings.key_file)))
    checks.append(("admin_token_file", settings.admin_token_file.exists(), str(settings.admin_token_file)))
    db_path = settings.state_dir / "state.sqlite3"
    db_ok = False
    detail = str(db_path)
    if db_path.exists():
        try:
            with sqlite3.connect(db_path) as conn:
                result = conn.execute("PRAGMA integrity_check").fetchone()
                db_ok = bool(result and result[0] == "ok")
                detail += f" integrity={result[0] if result else 'unknown'}"
        except Exception as exc:
            detail += f" error={type(exc).__name__}"
    checks.append(("database", db_ok, detail))
    for name, ok, info in checks:
        print(f"{'OK' if ok else 'FAIL':4} {name:18} {info}")
    return 0 if all(ok for _, ok, _ in checks) else 1


def cmd_status(settings: Settings) -> int:
    db_path = settings.state_dir / "state.sqlite3"
    if not db_path.exists():
        print("No state database yet.")
        return 1
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM jobs ORDER BY created_at DESC LIMIT 1").fetchone()
    if not row:
        print("No export jobs yet.")
        return 0
    data = dict(row)
    try:
        data["progress"] = json.loads(data.pop("progress_json"))
    except Exception:
        pass
    print(json.dumps(data, indent=2, ensure_ascii=False))
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(prog="chatgpt-export")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor")
    sub.add_parser("status")
    args = parser.parse_args()
    settings = Settings.load()
    if args.cmd == "doctor":
        raise SystemExit(cmd_doctor(settings))
    if args.cmd == "status":
        raise SystemExit(cmd_status(settings))


if __name__ == "__main__":
    main()
