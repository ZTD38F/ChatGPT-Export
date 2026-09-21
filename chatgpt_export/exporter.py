from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any

from .assets import AssetCapturer
from .config import Settings
from .db import Database
from .inventory import InventoryEngine
from .provider import ChatGPTClient, AuthenticationRequired
from .utils import atomic_write_json
from .workspace_export import WorkspaceExporter


class ExportManager:
    def __init__(self, settings: Settings, db: Database):
        self.settings = settings; self.db = db
        self.inventory = InventoryEngine(settings); self.assets = AssetCapturer(db)
        self.workspace_exporter = WorkspaceExporter(db, self.inventory, self.assets, settings.concurrency)
        self._task: asyncio.Task | None = None; self._lock = asyncio.Lock()

    async def start(self, access_token: str) -> str:
        async with self._lock:
            if self._task and not self._task.done():
                latest = self.db.latest_job()
                if latest: return latest["id"]
                raise RuntimeError("an export is already active")
            job_id = self.db.create_job("full")
            self._task = asyncio.create_task(self._run(job_id, access_token), name=f"chatgpt-export-{job_id[:8]}")
            return job_id

    def active(self) -> bool:
        return bool(self._task and not self._task.done())

    async def _run(self, job_id: str, access_token: str) -> None:
        started = datetime.now(timezone.utc); run_id = started.strftime("%Y%m%dT%H%M%SZ") + "-" + job_id[:8]
        run_root = self.settings.data_dir / "runs" / run_id; archive_root = self.settings.data_dir / "archive"
        run_root.mkdir(parents=True, exist_ok=True); archive_root.mkdir(parents=True, exist_ok=True)
        progress: dict[str, Any] = {"phase": "starting", "run_id": run_id, "workspaces": 0,
            "conversations_expected": 0, "conversations_verified": 0, "projects": 0,
            "assets_expected": 0, "assets_verified": 0, "errors": 0}
        self.db.update_job(job_id, status="RUNNING", run_dir=str(run_root), progress=progress)
        client = ChatGPTClient(access_token, self.settings); errors = []; reports = []
        try:
            progress["phase"] = "discovering_workspaces"; self.db.update_job(job_id, progress=progress)
            workspaces = await self.inventory.discover_workspaces(client, run_root)
            progress["workspaces"] = len(workspaces); self.db.update_job(job_id, progress=progress)
            for index, workspace in enumerate(workspaces, start=1):
                progress["phase"] = f"workspace_{index}_of_{len(workspaces)}"; progress["workspace"] = workspace.name
                self.db.update_job(job_id, progress=progress)
                try:
                    reports.append(await self.workspace_exporter.run(
                        client, workspace, run_id, run_root / "workspaces" / workspace.key,
                        archive_root / "workspaces" / workspace.key, progress, job_id,
                    ))
                except AuthenticationRequired: raise
                except Exception as exc:
                    errors.append({"workspace": workspace.key, "code": getattr(exc, "code", "WORKSPACE_FAILED"), "message": str(exc)[:1000]})
                    progress["errors"] = len(errors); self.db.update_job(job_id, progress=progress)
            complete = not errors and all(r.get("complete") for r in reports)
            validation = {"schema_version": 1, "run_id": run_id, "started_at": started.isoformat(),
                "finished_at": datetime.now(timezone.utc).isoformat(), "status": "COMPLETE" if complete else "PARTIAL",
                "definition": "COMPLETE means every item discovered through the supported ChatGPT web-history scopes was durably captured and verified; it is not byte-for-byte equivalence with OpenAI's official data export.",
                "workspaces": reports, "errors": errors}
            atomic_write_json(run_root / "validation.json", validation); atomic_write_json(self.settings.data_dir / "latest-validation.json", validation)
            progress["phase"] = "complete" if complete else "partial"; progress["errors"] = len(errors)
            self.db.update_job(job_id, status="COMPLETE" if complete else "PARTIAL", progress=progress)
        except AuthenticationRequired as exc:
            progress["phase"] = "authentication_required"
            self.db.update_job(job_id, status="AUTH_REQUIRED", progress=progress, error_code=exc.code, error_message=str(exc))
        except Exception as exc:
            progress["phase"] = "failed"
            self.db.update_job(job_id, status="FAILED", progress=progress, error_code=getattr(exc, "code", "EXPORT_FAILED"), error_message=str(exc))
            atomic_write_json(run_root / "fatal-error.json", {"code": getattr(exc, "code", "EXPORT_FAILED"), "message": str(exc)[:2000]})
        finally:
            await client.aclose()

    # Compatibility helpers retained for tests and external audit tooling.
    _extract_file_refs = staticmethod(AssetCapturer.extract_file_refs)
    _extract_gpt_file_descriptors = staticmethod(AssetCapturer.gpt_file_descriptors)
