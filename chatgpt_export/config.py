from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os


def _int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.getenv(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value


@dataclass(frozen=True)
class Settings:
    state_dir: Path
    data_dir: Path
    key_file: Path
    admin_token_file: Path
    bind_host: str
    bind_port: int
    concurrency: int
    page_size: int
    request_timeout: int
    max_json_bytes: int
    max_asset_bytes: int
    max_pages_per_chain: int

    @classmethod
    def load(cls) -> "Settings":
        state = Path(os.getenv("CHATGPT_EXPORT_STATE_DIR", "/var/lib/chatgpt-export"))
        data = Path(os.getenv("CHATGPT_EXPORT_DATA_DIR", str(state / "data")))
        config_dir = Path(os.getenv("CHATGPT_EXPORT_CONFIG_DIR", "/etc/chatgpt-export"))
        return cls(
            state_dir=state,
            data_dir=data,
            key_file=Path(os.getenv("CHATGPT_EXPORT_KEY_FILE", str(config_dir / "fernet.key"))),
            admin_token_file=Path(os.getenv("CHATGPT_EXPORT_ADMIN_TOKEN_FILE", str(config_dir / "admin.token"))),
            bind_host=os.getenv("CHATGPT_EXPORT_HOST", "127.0.0.1"),
            bind_port=_int("CHATGPT_EXPORT_PORT", 8788, 1, 65535),
            concurrency=_int("CHATGPT_EXPORT_CONCURRENCY", 4, 1, 10),
            page_size=_int("CHATGPT_EXPORT_PAGE_SIZE", 100, 1, 100),
            request_timeout=_int("CHATGPT_EXPORT_REQUEST_TIMEOUT", 90, 10, 600),
            max_json_bytes=_int("CHATGPT_EXPORT_MAX_JSON_BYTES", 120_000_000, 1_000_000, 500_000_000),
            max_asset_bytes=_int("CHATGPT_EXPORT_MAX_ASSET_BYTES", 512_000_000, 1_000_000, 4_000_000_000),
            max_pages_per_chain=_int("CHATGPT_EXPORT_MAX_PAGES", 100_000, 10, 1_000_000),
        )

    def ensure_dirs(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.data_dir.mkdir(parents=True, exist_ok=True)
