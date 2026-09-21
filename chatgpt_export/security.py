from __future__ import annotations

from cryptography.fernet import Fernet, InvalidToken
from pathlib import Path
import hmac
import json
import os
import secrets


class SecretStore:
    def __init__(self, key_file: Path, secret_file: Path):
        self.key_file = key_file
        self.secret_file = secret_file
        self._fernet = Fernet(self._load_key())

    def _load_key(self) -> bytes:
        data = self.key_file.read_bytes().strip()
        if not data:
            raise RuntimeError(f"encryption key is empty: {self.key_file}")
        return data

    def save_session(self, session: dict) -> None:
        payload = json.dumps(session, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        encrypted = self._fernet.encrypt(payload)
        self.secret_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.secret_file.with_name(f".{self.secret_file.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
        try:
            tmp.write_bytes(encrypted)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.secret_file)
        finally:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass

    def load_session(self) -> dict | None:
        if not self.secret_file.exists():
            return None
        try:
            plain = self._fernet.decrypt(self.secret_file.read_bytes())
            value = json.loads(plain)
        except (InvalidToken, json.JSONDecodeError) as exc:
            raise RuntimeError("stored ChatGPT session could not be decrypted") from exc
        if not isinstance(value, dict):
            raise RuntimeError("stored ChatGPT session has an invalid shape")
        return value

    def clear_session(self) -> None:
        try:
            self.secret_file.unlink()
        except FileNotFoundError:
            pass


def require_access_token(session: dict) -> str:
    token = session.get("accessToken") or session.get("access_token")
    if not isinstance(token, str) or len(token) < 32 or any(ch.isspace() for ch in token):
        raise ValueError("session JSON does not contain a usable accessToken")
    return token


def load_admin_token(path: Path) -> str:
    token = path.read_text("utf-8").strip()
    if len(token) < 24:
        raise RuntimeError(f"admin token is missing or too short: {path}")
    return token


def constant_time_equal(left: str, right: str) -> bool:
    return hmac.compare_digest(left.encode(), right.encode())
