from __future__ import annotations

from typing import Any
from urllib.parse import urlencode

from .config import Settings
from .transport import ChatGPTTransport, ProviderError, AuthenticationRequired, RateLimitExhausted, ContractDrift, ProviderHTTPError
from .utils import require_identifier, safe_cursor

__all__ = ["ChatGPTClient", "ProviderError", "AuthenticationRequired", "RateLimitExhausted", "ContractDrift", "ProviderHTTPError"]


class ChatGPTClient:
    def __init__(self, access_token: str, settings: Settings): self.transport = ChatGPTTransport(access_token, settings)
    async def aclose(self) -> None: await self.transport.aclose()
    async def accounts(self) -> Any: return (await self.transport.request_json("GET", "/backend-api/accounts/check/v4-2023-04-27"))[0]

    async def conversation_page(self, offset: int, limit: int, archived: bool, workspace_id: str | None) -> Any:
        query = {"offset": str(offset), "limit": str(limit), "order": "updated"}
        if archived: query["is_archived"] = "true"
        return (await self.transport.request_json("GET", f"/backend-api/conversations?{urlencode(query)}", workspace_id=workspace_id))[0]

    async def projects_page(self, cursor: str | None, workspace_id: str | None) -> Any:
        query = {"conversations_per_gizmo": "0"}
        if cursor is not None: query["cursor"] = safe_cursor(cursor)
        return (await self.transport.request_json("GET", f"/backend-api/gizmos/snorlax/sidebar?{urlencode(query)}", workspace_id=workspace_id))[0]

    async def project_conversations(self, project_id: str, cursor: str, workspace_id: str | None) -> Any:
        pid = require_identifier(project_id, "project id"); query = urlencode({"cursor": safe_cursor(cursor)})
        return (await self.transport.request_json("GET", f"/backend-api/gizmos/{pid}/conversations?{query}", workspace_id=workspace_id))[0]

    async def shared_page(self, offset: int, limit: int, workspace_id: str | None) -> Any:
        query = urlencode({"order": "updated", "limit": str(limit), "offset": str(offset)})
        return (await self.transport.request_json("GET", f"/backend-api/shared_conversations?{query}", workspace_id=workspace_id))[0]

    async def shared_detail(self, share_id: str, workspace_id: str | None) -> Any:
        sid = require_identifier(share_id, "share id")
        return (await self.transport.request_json("GET", f"/backend-api/share/{sid}", workspace_id=workspace_id))[0]

    async def conversation_detail(self, conversation_id: str, workspace_id: str | None) -> Any:
        cid = require_identifier(conversation_id, "conversation id")
        return (await self.transport.request_json("GET", f"/backend-api/conversation/{cid}", workspace_id=workspace_id))[0]

    async def account_artifact(self, kind: str, workspace_id: str | None) -> Any:
        paths = {"memories": "/backend-api/memories?include_memory_entries=true", "custom_instructions": "/backend-api/user_system_messages",
                 "settings": "/backend-api/settings", "beta_features": "/backend-api/settings/beta_features"}
        if kind not in paths: raise ValueError("invalid artifact kind")
        return (await self.transport.request_json("GET", paths[kind], workspace_id=workspace_id))[0]

    async def my_gpts_page(self, cursor: str | None, workspace_id: str | None) -> Any:
        query = {"limit": "20"}
        if cursor: query["cursor"] = safe_cursor(cursor)
        return (await self.transport.request_json("GET", f"/public-api/gizmos/discovery/mine?{urlencode(query)}", workspace_id=workspace_id))[0]

    async def resolve_file(self, file_id: str, *, workspace_id: str | None, conversation_id: str | None = None, project_id: str | None = None) -> dict:
        fid = require_identifier(file_id, "file id")
        if (conversation_id is None) == (project_id is None): raise ValueError("exactly one conversation_id or project_id is required")
        if conversation_id: query = urlencode({"conversation_id": require_identifier(conversation_id, "conversation id"), "inline": "false"})
        else: query = urlencode({"gizmo_id": require_identifier(project_id or "", "project id")})
        try:
            value = (await self.transport.request_json("GET", f"/backend-api/files/download/{fid}?{query}", workspace_id=workspace_id, max_bytes=5_000_000))[0]
        except ProviderHTTPError as exc:
            if project_id is None or exc.status not in {404, 405}: raise
            value = (await self.transport.request_json("GET", f"/backend-api/files/{fid}/download?{query}", workspace_id=workspace_id, max_bytes=5_000_000))[0]
        if not isinstance(value, dict): raise ContractDrift("file resolver returned a non-object")
        return value

    async def download_asset_to_temp(self, url: str, target_dir): return await self.transport.download_asset_to_temp(url, target_dir)
