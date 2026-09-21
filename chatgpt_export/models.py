from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Workspace:
    key: str
    account_id: str | None
    name: str
    raw: dict[str, Any] | None
