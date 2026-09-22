from __future__ import annotations

import argparse
import json
import sqlite3

from .config import Settings


def _doctor_checks(settings: Settings) -> list[tuple[str, bool, str]]:
    checks: list[tuple[str, bool, str]] = []
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
    return checks


def cmd_doctor(settings: Settings, *, verbose: bool = False) -> int:
    checks = _doctor_checks(settings)
    failures = [(name, info) for name, ok, info in checks if not ok]

    if verbose:
        for name, ok, info in checks:
            print(f"{'OK' if ok else 'FAIL':4} {name:18} {info}")

    if not failures:
        print("✓ Doctor: all checks passed.")
        return 0

    print(f"✗ Doctor: {len(failures)} check(s) failed.")
    for name, info in failures:
        print(f"  - {name}: {info}")
    return 1


def _latest_job(settings: Settings) -> dict | None:
    db_path = settings.state_dir / "state.sqlite3"
    if not db_path.exists():
        return None
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM jobs ORDER BY created_at DESC LIMIT 1").fetchone()
    if not row:
        return None
    data = dict(row)
    try:
        data["progress"] = json.loads(data.pop("progress_json"))
    except Exception:
        data["progress"] = {}
    return data


def cmd_status(settings: Settings, *, json_output: bool = False) -> int:
    data = _latest_job(settings)
    if json_output:
        print(json.dumps(data or {"status": "NOT_STARTED"}, indent=2, ensure_ascii=False))
        return 0

    if not data:
        print("Export         — not started")
        return 0

    progress = data.get("progress") if isinstance(data.get("progress"), dict) else {}
    status = str(data.get("status") or "UNKNOWN")
    verified = int(progress.get("conversations_verified") or 0)
    expected = int(progress.get("conversations_expected") or 0)
    assets_ok = int(progress.get("assets_verified") or 0)
    assets_expected = int(progress.get("assets_expected") or 0)
    errors = int(progress.get("errors") or 0)

    print(f"Export         {status}")
    if expected or verified:
        print(f"Chats          {verified}/{expected or '?'}")
    if assets_expected or assets_ok:
        print(f"Assets         {assets_ok}/{assets_expected or '?'}")
    if errors:
        print(f"Errors         {errors}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(prog="chatgpt-export")
    sub = parser.add_subparsers(dest="cmd", required=True)

    doctor = sub.add_parser("doctor")
    doctor.add_argument("--verbose", action="store_true")

    status = sub.add_parser("status")
    status.add_argument("--json", action="store_true", dest="json_output")

    args = parser.parse_args()
    settings = Settings.load()

    if args.cmd == "doctor":
        raise SystemExit(cmd_doctor(settings, verbose=args.verbose))
    if args.cmd == "status":
        raise SystemExit(cmd_status(settings, json_output=args.json_output))


if __name__ == "__main__":
    main()
