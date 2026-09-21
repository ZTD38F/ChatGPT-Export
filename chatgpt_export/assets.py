from __future__ import annotations

from pathlib import Path
import os
from typing import Any
import mimetypes

from .db import Database
from .models import Workspace
from .provider import ChatGPTClient, AuthenticationRequired
from .utils import atomic_write_json


class AssetFailure(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message); self.code = code


class AssetCapturer:
    def __init__(self, db: Database):
        self.db = db

    async def conversation_assets(self, client: ChatGPTClient, workspace: Workspace, cid: str, detail: dict[str, Any], target: Path,
                                  progress: dict[str, Any], job_id: str) -> list[dict[str, str]]:
        refs = self.extract_file_refs(detail)
        progress["assets_expected"] += len(refs); self.db.update_job(job_id, progress=progress)
        errors = []
        for fid, name in refs.items():
            try:
                await self._download(client, workspace, fid, name, target, conversation_id=cid)
                progress["assets_verified"] += 1; self.db.update_job(job_id, progress=progress)
            except AuthenticationRequired: raise
            except Exception as exc: errors.append(self._err(fid, exc))
        return errors

    async def gizmo_files(self, client: ChatGPTClient, workspace: Workspace, descriptors: list[tuple[str, dict[str, Any]]], target_root: Path,
                          progress: dict[str, Any], job_id: str, kind: str) -> list[dict[str, str]]:
        errors = []; seen: set[tuple[str, str]] = set()
        for gizmo_id, desc in descriptors:
            fid = desc.get("file_id") or desc.get("id")
            if not isinstance(fid, str) or (gizmo_id, fid) in seen: continue
            seen.add((gizmo_id, fid)); progress["assets_expected"] += 1; self.db.update_job(job_id, progress=progress)
            try:
                name = str(desc.get("name") or desc.get("file_name") or fid)
                await self._download(client, workspace, fid, name, target_root / gizmo_id, project_id=gizmo_id, descriptor=desc)
                progress["assets_verified"] += 1; self.db.update_job(job_id, progress=progress)
            except AuthenticationRequired: raise
            except Exception as exc:
                item = self._err(fid, exc); item["gizmo_id"] = gizmo_id; item["kind"] = kind; errors.append(item)
        return errors

    async def _download(self, client: ChatGPTClient, workspace: Workspace, fid: str, name: str, target: Path,
                        conversation_id: str | None = None, project_id: str | None = None, descriptor: dict[str, Any] | None = None) -> None:
        meta = await client.resolve_file(fid, workspace_id=workspace.account_id, conversation_id=conversation_id, project_id=project_id)
        url = self.download_url(meta)
        if not url: raise AssetFailure("ASSET_URL_MISSING", "file resolver returned no download URL")
        tmp, content_type, digest, size = await client.download_asset_to_temp(url, target)
        ext = self.extension(name, content_type); out = target / f"{fid}{ext}"
        try:
            os.replace(tmp, out)
        finally:
            try: tmp.unlink()
            except FileNotFoundError: pass
        atomic_write_json(out.with_suffix(out.suffix + ".meta.json"), {"descriptor": descriptor, "resolver": self.redact_meta(meta),
            "sha256": digest, "size_bytes": size, "content_type": content_type})

    @staticmethod
    def extract_file_refs(value: Any) -> dict[str, str]:
        refs: dict[str, str] = {}
        def add(fid: Any, name: Any = None) -> None:
            if isinstance(fid, str) and fid:
                refs.setdefault(fid, str(name or fid))
        def walk(node: Any) -> None:
            if isinstance(node, dict):
                pointer = node.get("asset_pointer")
                if isinstance(pointer, str) and "://" in pointer:
                    scheme, fid = pointer.split("://", 1)
                    if scheme in {"file-service", "sediment"} and fid:
                        add(fid, node.get("name") or node.get("file_name") or "image")
                attachments = node.get("attachments")
                if isinstance(attachments, list):
                    for att in attachments:
                        if isinstance(att, dict):
                            add(att.get("id") or att.get("file_id"), att.get("name") or att.get("file_name"))
                citations = node.get("citations")
                if isinstance(citations, list):
                    for citation in citations:
                        if not isinstance(citation, dict): continue
                        meta = citation.get("metadata") if isinstance(citation.get("metadata"), dict) else {}
                        add(meta.get("file_id") or citation.get("file_id"), meta.get("title") or citation.get("title") or "citation")
                fid = node.get("file_id")
                if isinstance(fid, str) and any(key in node for key in ("name", "file_name", "title", "mime_type", "content_type")):
                    add(fid, node.get("name") or node.get("file_name") or node.get("title"))
                for child in node.values():
                    if isinstance(child, (dict, list)): walk(child)
            elif isinstance(node, list):
                for child in node: walk(child)
        walk(value); return refs

    @staticmethod
    def gpt_file_descriptors(value: Any) -> list[dict[str, Any]]:
        found: dict[str, dict[str, Any]] = {}
        def walk(node: Any) -> None:
            if isinstance(node, dict):
                fid = node.get("file_id")
                if isinstance(fid, str) and fid: found.setdefault(fid, dict(node))
                for child in node.values():
                    if isinstance(child, (dict, list)): walk(child)
            elif isinstance(node, list):
                for child in node:
                    if isinstance(child, str) and child.startswith("file-"): found.setdefault(child, {"file_id": child})
                    else: walk(child)
        walk(value); return list(found.values())

    @staticmethod
    def download_url(meta: dict[str, Any]) -> str | None:
        for key in ("download_url", "url", "file_url", "presigned_url", "signed_url"):
            value = meta.get(key)
            if isinstance(value, str) and value.startswith("https://"): return value
        return None

    @staticmethod
    def redact_meta(meta: dict[str, Any]) -> dict[str, Any]:
        safe = dict(meta)
        for key in ("download_url", "url", "file_url", "presigned_url", "signed_url"):
            if key in safe: safe[key] = "[REDACTED_SIGNED_URL]"
        return safe

    @staticmethod
    def extension(name: str, content_type: str | None) -> str:
        suffix = Path(name).suffix
        if suffix and len(suffix) <= 12: return suffix
        if content_type:
            ext = mimetypes.guess_extension(content_type.split(";", 1)[0].strip())
            if ext: return ext
        return ".bin"

    @staticmethod
    def _err(fid: str, exc: Exception) -> dict[str, str]:
        return {"file_id": fid, "code": getattr(exc, "code", "ASSET_FAILED"), "message": str(exc)[:1000]}
