from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any
import hashlib

from .config import Settings
from .models import Workspace
from .pagination import offset_chain, cursor_chain, required_id
from .provider import ChatGPTClient, AuthenticationRequired
from .utils import atomic_write_json


class InventoryEngine:
    def __init__(self, settings: Settings): self.settings = settings

    async def discover_workspaces(self, client: ChatGPTClient, run_root: Path) -> list[Workspace]:
        raw = await client.accounts(); atomic_write_json(run_root / "source" / "accounts.json", raw)
        result: list[Workspace] = []; seen: set[str] = set()
        accounts = raw.get("accounts") if isinstance(raw, dict) else None
        values = accounts.values() if isinstance(accounts, dict) else accounts if isinstance(accounts, list) else []
        for item in values:
            if not isinstance(item, dict) or item.get("is_deactivated") is True: continue
            account = item.get("account") if isinstance(item.get("account"), dict) else item
            aid = account.get("account_id") if isinstance(account, dict) else None
            if not isinstance(aid, str) or not aid or aid in seen: continue
            seen.add(aid); name = account.get("account_name") if isinstance(account.get("account_name"), str) else aid
            result.append(Workspace("account-" + hashlib.sha256(("chatgpt-web-workspace-v1\0" + aid).encode()).hexdigest()[:32], aid, name, item))
        if not result:
            raise RuntimeError("ChatGPT account-check returned no active workspaces; refusing to guess an account scope")
        return sorted(result, key=lambda ws: (ws.name.casefold(), ws.key))

    async def capture(self, client: ChatGPTClient, workspace: Workspace, run_ws: Path) -> dict[str, Any]:
        source = run_ws / "source"; listings: dict[str, dict[str, Any]] = {}; memberships: dict[str, list[dict[str, Any]]] = defaultdict(list)
        projects: dict[str, dict[str, Any]] = {}; project_files: list[tuple[str, dict[str, Any]]] = []; errors = []
        shares_map: dict[str, dict[str, Any]] = {}
        for archived in (False, True):
            scope = "archived" if archived else "main"
            try:
                items = await offset_chain(lambda off, lim: client.conversation_page(off, lim, archived, workspace.account_id), source / scope, "conversation", self.settings.page_size, self.settings.max_pages_per_chain)
                for item in items:
                    cid = required_id(item, "conversation"); listings[cid] = item; memberships[cid].append({"scope": scope})
            except AuthenticationRequired: raise
            except Exception as exc: errors.append(self._err(scope, exc))
        try:
            pitems = await cursor_chain(lambda cur: client.projects_page(cur, workspace.account_id), source / "projects", None, self.settings.max_pages_per_chain)
            for raw in pitems:
                parsed = self._project(raw)
                if not parsed: continue
                pid, name, files = parsed; projects[pid] = {"id": pid, "name": name, "raw": raw}; project_files.extend((pid, x) for x in files if isinstance(x, dict))
                try:
                    items = await cursor_chain(lambda cur, pid=pid: client.project_conversations(pid, cur or "0", workspace.account_id), source / "projects" / pid, "0", self.settings.max_pages_per_chain)
                    for item in items:
                        cid = required_id(item, "conversation"); listings.setdefault(cid, item); memberships[cid].append({"scope": "project", "project_id": pid, "project_name": name})
                except AuthenticationRequired: raise
                except Exception as exc: errors.append(self._err(f"project:{pid}", exc))
        except AuthenticationRequired: raise
        except Exception as exc: errors.append(self._err("projects", exc))
        try:
            items = await offset_chain(lambda off, lim: client.shared_page(off, lim, workspace.account_id), source / "shared", "share", self.settings.page_size, self.settings.max_pages_per_chain)
            for item in items:
                sid = required_id(item, "share"); shares_map[sid] = item; cid = item.get("conversation_id")
                if isinstance(cid, str) and cid: listings.setdefault(cid, item); memberships[cid].append({"scope": "shared", "share_id": sid})
        except AuthenticationRequired: raise
        except Exception as exc: errors.append(self._err("shared", exc))
        result = {"listings": listings, "memberships": dict(memberships), "projects": projects, "project_files": project_files, "shares": shares_map, "scope_errors": errors}
        atomic_write_json(run_ws / "inventory.json", {"schema_version": 1, "workspace": workspace.key, "conversation_ids": sorted(listings), "memberships": result["memberships"],
            "projects": [{"id": p["id"], "name": p["name"]} for p in projects.values()], "share_ids": sorted(shares_map), "scope_errors": errors})
        return result

    async def gpts(self, client: ChatGPTClient, workspace: Workspace, page_dir: Path) -> list[dict[str, Any]]:
        return await cursor_chain(lambda cur: client.my_gpts_page(cur, workspace.account_id), page_dir, None, self.settings.max_pages_per_chain)

    @staticmethod
    def _project(item: dict[str, Any]) -> tuple[str, str, list[Any]] | None:
        wrapper = item.get("resource") if isinstance(item.get("resource"), dict) else item
        wrapper = wrapper.get("gizmo") if isinstance(wrapper.get("gizmo"), dict) else wrapper
        files = wrapper.get("files") if isinstance(wrapper.get("files"), list) else []
        gizmo = wrapper.get("gizmo") if isinstance(wrapper.get("gizmo"), dict) else wrapper
        pid = gizmo.get("id") if isinstance(gizmo, dict) else None
        if not isinstance(pid, str) or not pid: return None
        display = gizmo.get("display") if isinstance(gizmo.get("display"), dict) else {}; name = display.get("name") if isinstance(display.get("name"), str) else gizmo.get("name")
        return pid, str(name or pid), files

    @staticmethod
    def _err(scope: str, exc: Exception) -> dict[str, str]: return {"scope": scope, "code": getattr(exc, "code", "INVENTORY_FAILED"), "message": str(exc)[:1000]}
