from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from .assets import AssetCapturer
from .conversation_capture import ConversationCapturer
from .db import Database
from .inventory import InventoryEngine
from .models import Workspace
from .provider import ChatGPTClient, AuthenticationRequired
from .utils import atomic_write_json


class WorkspaceExporter:
    def __init__(self, db: Database, inventory: InventoryEngine, assets: AssetCapturer, concurrency: int):
        self.db = db; self.inventory = inventory; self.assets = assets; self.conversations = ConversationCapturer(db, assets, concurrency)

    async def run(self, client: ChatGPTClient, workspace: Workspace, run_id: str, run_ws: Path, archive_ws: Path,
                  progress: dict[str, Any], job_id: str) -> dict[str, Any]:
        run_ws.mkdir(parents=True, exist_ok=True); archive_ws.mkdir(parents=True, exist_ok=True)
        atomic_write_json(run_ws / "workspace.json", {"key": workspace.key, "name": workspace.name,
            "account_id_fingerprint": None if workspace.account_id is None else hashlib.sha256(workspace.account_id.encode()).hexdigest(), "raw": workspace.raw})
        inv = await self.inventory.capture(client, workspace, run_ws); listings = inv["listings"]; memberships = inv["memberships"]
        progress["conversations_expected"] += len(listings); progress["projects"] += len(inv["projects"]); self.db.update_job(job_id, progress=progress)
        for pid, project in inv["projects"].items():
            project_dir = archive_ws / "projects" / pid
            atomic_write_json(project_dir / "project.json", project["raw"])
            members = []
            for cid, scopes in memberships.items():
                if any(scope.get("scope") == "project" and scope.get("project_id") == pid for scope in scopes):
                    listing = listings.get(cid, {})
                    members.append({"id": cid, "title": listing.get("title"), "update_time": listing.get("update_time"),
                        "conversation_path": f"../../conversations/{cid}"})
            atomic_write_json(project_dir / "conversation-index.json", sorted(members, key=lambda item: str(item.get("title") or item["id"]).casefold()))

        artifact_errors = await self._account_artifacts(client, workspace, archive_ws); gpt_files: list[tuple[str, dict[str, Any]]] = []
        try:
            for raw in await self.inventory.gpts(client, workspace, run_ws / "source" / "gpts"):
                gid = self._gpt_id(raw)
                if not gid: continue
                atomic_write_json(archive_ws / "gpts" / f"{gid}.json", raw); gpt_files.extend((gid, d) for d in self.assets.gpt_file_descriptors(raw))
        except AuthenticationRequired: raise
        except Exception as exc: artifact_errors.append(self._err("custom_gpts", exc))

        conversation_errors, asset_errors = await self.conversations.capture_all(client, workspace, run_id, archive_ws, listings, memberships, progress, job_id)
        shared_errors = await self.conversations.shared(client, workspace, inv["shares"], archive_ws)
        asset_errors.extend(await self.assets.gizmo_files(client, workspace, inv["project_files"], archive_ws / "project-files", progress, job_id, "project"))
        asset_errors.extend(await self.assets.gizmo_files(client, workspace, gpt_files, archive_ws / "gpt-files", progress, job_id, "custom_gpt"))
        expected = len(listings); verified = sum((archive_ws / "conversations" / cid / "complete.json").exists() for cid in listings)
        complete = not inv["scope_errors"] and not artifact_errors and not conversation_errors and not shared_errors and not asset_errors and verified == expected
        report = {"workspace": workspace.key, "name": workspace.name, "complete": complete, "conversation_expected": expected,
            "conversation_complete_markers": verified, "projects": len(inv["projects"]), "shared": len(inv["shares"]), "scope_errors": inv["scope_errors"],
            "artifact_errors": artifact_errors, "conversation_errors": conversation_errors, "shared_errors": shared_errors, "asset_errors": asset_errors}
        atomic_write_json(run_ws / "validation.json", report); return report

    async def _account_artifacts(self, client: ChatGPTClient, workspace: Workspace, archive_ws: Path) -> list[dict[str, str]]:
        errors = []
        for kind in ("memories", "custom_instructions", "settings", "beta_features"):
            try: atomic_write_json(archive_ws / "account" / f"{kind}.json", await client.account_artifact(kind, workspace.account_id))
            except AuthenticationRequired: raise
            except Exception as exc: errors.append(self._err(kind, exc))
        return errors

    @staticmethod
    def _gpt_id(item: dict[str, Any]) -> str | None:
        resource = item.get("resource") if isinstance(item.get("resource"), dict) else item; gizmo = resource.get("gizmo") if isinstance(resource.get("gizmo"), dict) else resource
        value = gizmo.get("id") if isinstance(gizmo, dict) else None; return value if isinstance(value, str) and value else None

    @staticmethod
    def _err(kind: str, exc: Exception) -> dict[str, str]: return {"kind": kind, "code": getattr(exc, "code", "ARTIFACT_FAILED"), "message": str(exc)[:1000]}
