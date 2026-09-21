from __future__ import annotations

from pathlib import Path
from typing import Any, Awaitable, Callable

from .provider import ContractDrift
from .utils import atomic_write_json, canonical_json_bytes, sha256_bytes


class InventoryFailure(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message); self.code = code


async def offset_chain(fetch: Callable[[int, int], Awaitable[Any]], page_dir: Path, label: str,
                       page_size: int, max_pages: int) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []; seen_ids: set[str] = set(); seen_pages: set[str] = set(); offset = 0
    for page in range(1, max_pages + 1):
        raw = await fetch(offset, page_size); atomic_write_json(page_dir / f"page-{page:06d}.json", raw)
        if not isinstance(raw, dict) or not isinstance(raw.get("items"), list): raise ContractDrift(f"{label} page no longer contains items[]")
        items = [x for x in raw["items"] if isinstance(x, dict)]; ids = [required_id(x, label) for x in items]
        ph = sha256_bytes(canonical_json_bytes(ids))
        if ids and ph in seen_pages: raise InventoryFailure("INVENTORY_REPEATED_PAGE", f"{label} inventory repeated at {offset}")
        seen_pages.add(ph)
        for item, oid in zip(items, ids):
            if oid not in seen_ids: seen_ids.add(oid); result.append(item)
        total = raw.get("total") if isinstance(raw.get("total"), int) and raw["total"] >= 0 else None
        nxt = offset + len(items)
        if not items:
            if total is not None and offset < total: raise InventoryFailure("INVENTORY_PREMATURE_EMPTY_PAGE", f"{label} ended before total {total}")
            return result
        if total is not None and nxt >= total: return result
        if nxt <= offset: raise InventoryFailure("INVENTORY_OFFSET_STALL", f"{label} offset stalled")
        offset = nxt
    raise InventoryFailure("INVENTORY_PAGE_LIMIT", f"{label} exceeded page safety limit")


async def cursor_chain(fetch: Callable[[str | None], Awaitable[Any]], page_dir: Path, first: str | None,
                       max_pages: int) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []; cursor = first; seen: set[str] = set(); seen_ids: set[str] = set()
    for page in range(1, max_pages + 1):
        raw = await fetch(cursor); atomic_write_json(page_dir / f"page-{page:06d}.json", raw)
        if not isinstance(raw, dict): raise ContractDrift("cursor inventory returned non-object")
        nested = raw.get("list") if isinstance(raw.get("list"), dict) else None
        items = raw.get("items") if isinstance(raw.get("items"), list) else nested.get("items") if nested and isinstance(nested.get("items"), list) else None
        if items is None: raise ContractDrift("cursor inventory no longer contains items[]")
        for item in items:
            if not isinstance(item, dict): continue
            oid = item.get("id")
            if not isinstance(oid, str): oid = str(len(result)) + ":" + sha256_bytes(canonical_json_bytes(item))[:12]
            if oid not in seen_ids: seen_ids.add(oid); result.append(item)
        nxt = raw.get("cursor") if raw.get("cursor") is not None else nested.get("cursor") if nested else raw.get("next_cursor")
        if nxt in (None, ""): return result
        if not isinstance(nxt, str) or nxt in seen or nxt == cursor: raise InventoryFailure("INVENTORY_CURSOR_CYCLE", "cursor chain repeated")
        seen.add(nxt); cursor = nxt
    raise InventoryFailure("INVENTORY_PAGE_LIMIT", "cursor chain exceeded page safety limit")


def required_id(item: dict[str, Any], label: str) -> str:
    value = item.get("id")
    if not isinstance(value, str) or not value: raise ContractDrift(f"{label} item missing id")
    return value
