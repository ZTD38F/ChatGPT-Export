from __future__ import annotations

from pathlib import Path
import hashlib
import json
import os
import re
import tempfile

IDENTIFIER = re.compile(r"^[A-Za-z0-9_-]{1,256}$")
CURSOR = re.compile(r"^[A-Za-z0-9._~-]{1,1024}$")


def require_identifier(value: str, label: str = "identifier") -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ValueError(f"invalid {label}")
    return value


def safe_cursor(value: str) -> str:
    if not CURSOR.fullmatch(value):
        raise ValueError("invalid cursor")
    return value


def safe_component(value: str, fallback: str = "untitled", max_len: int = 90) -> str:
    cleaned = re.sub(r"[<>:\"/\\|?*\x00-\x1f]", "_", str(value)).strip(" .")
    cleaned = re.sub(r"\s+", " ", cleaned)
    return (cleaned[:max_len] or fallback)


def canonical_json_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write_bytes(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def atomic_write_json(path: Path, value: object, mode: int = 0o600) -> str:
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    atomic_write_bytes(path, data, mode)
    return sha256_bytes(data)


def atomic_write_text(path: Path, value: str, mode: int = 0o600) -> str:
    data = value.encode("utf-8")
    atomic_write_bytes(path, data, mode)
    return sha256_bytes(data)
