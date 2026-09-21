from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .assets import AssetCapturer
from .db import Database
from .models import Workspace
from .provider import ChatGPTClient, AuthenticationRequired
from .render import conversation_markdown
from .utils import atomic_write_json, atomic_write_text


class ConversationCapturer:
    def __init__(self, db: Database, assets: AssetCapturer, concurrency: int):
        self.db = db; self.assets = assets; self.concurrency = concurrency

    async def capture_all(self, client: ChatGPTClient, workspace: Workspace, run_id: str, archive_ws: Path,
                          listings: dict[str, dict[str, Any]], memberships: dict[str, list[dict[str, Any]]],
                          progress: dict[str, Any], job_id: str) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
        conversation_errors: list[dict[str, str]] = []; asset_errors: list[dict[str, str]] = []; sem = asyncio.Semaphore(self.concurrency)
        async def one(cid: str, listing: dict[str, Any]) -> None:
            async with sem:
                updated = self.remote_updated(listing); conv_dir = archive_ws / "conversations" / cid
                state = self.db.object_state(workspace.key, "conversation", cid)
                if state and state.get("verified") and state.get("remote_updated") == updated and (conv_dir / "complete.json").exists():
                    # Content may be unchanged while archive/project/shared membership changes.
                    atomic_write_json(conv_dir / "listing.json", listing)
                    atomic_write_json(conv_dir / "membership.json", memberships.get(cid, []))
                    self.db.upsert_object(workspace_key=workspace.key, object_type="conversation", object_id=cid,
                        remote_updated=updated, sha256=state.get("sha256"), local_path=str(conv_dir), verified=True, run_id=run_id)
                    progress["conversations_verified"] += 1; self.db.update_job(job_id, progress=progress); return
                try:
                    detail = await client.conversation_detail(cid, workspace.account_id)
                    raw_sha = atomic_write_json(conv_dir / "raw.json", detail)
                    atomic_write_json(conv_dir / "listing.json", listing); atomic_write_json(conv_dir / "membership.json", memberships.get(cid, []))
                    atomic_write_text(conv_dir / "conversation.md", conversation_markdown(detail))
                    local_errors = await self.assets.conversation_assets(client, workspace, cid, detail, conv_dir / "assets", progress, job_id)
                    asset_errors.extend(local_errors)
                    atomic_write_json(conv_dir / "complete.json", {"conversation_id": cid, "remote_updated": updated, "raw_sha256": raw_sha,
                        "verified": not local_errors, "completed_at": datetime.now(timezone.utc).isoformat()})
                    self.db.upsert_object(workspace_key=workspace.key, object_type="conversation", object_id=cid,
                        remote_updated=updated, sha256=raw_sha, local_path=str(conv_dir), verified=not local_errors, run_id=run_id)
                    progress["conversations_verified"] += 1; self.db.update_job(job_id, progress=progress)
                except AuthenticationRequired: raise
                except Exception as exc:
                    conversation_errors.append({"id": cid, "code": getattr(exc, "code", "CONVERSATION_FAILED"), "message": str(exc)[:1000]})
                    progress["errors"] += 1; self.db.update_job(job_id, progress=progress)
        tasks = [asyncio.create_task(one(cid, listing)) for cid, listing in listings.items()]
        try: await asyncio.gather(*tasks)
        except AuthenticationRequired:
            for task in tasks:
                if not task.done(): task.cancel()
            raise
        return conversation_errors, asset_errors

    async def shared(self, client: ChatGPTClient, workspace: Workspace, shares: dict[str, dict[str, Any]], archive_ws: Path) -> list[dict[str, str]]:
        errors = []
        for sid, listing in shares.items():
            try:
                detail = await client.shared_detail(sid, workspace.account_id)
                atomic_write_json(archive_ws / "shared" / sid / "raw.json", detail); atomic_write_json(archive_ws / "shared" / sid / "listing.json", listing)
            except AuthenticationRequired: raise
            except Exception as exc: errors.append({"id": sid, "code": getattr(exc, "code", "SHARED_DETAIL_FAILED"), "message": str(exc)[:1000]})
        return errors

    @staticmethod
    def remote_updated(item: dict[str, Any]) -> str | None:
        value = item.get("update_time") or item.get("updated_at") or item.get("create_time")
        return None if value is None else str(value)
