from __future__ import annotations

import asyncio
import json
import random
import uuid
from dataclasses import dataclass
from typing import Any

import httpx

from .config import Settings
from .utils import require_identifier
from .asset_net import download_asset_to_temp


class ProviderError(RuntimeError):
    code = "PROVIDER_ERROR"


class AuthenticationRequired(ProviderError):
    code = "AUTHENTICATION_REQUIRED"


class RateLimitExhausted(ProviderError):
    code = "RATE_LIMIT_EXHAUSTED"


class ContractDrift(ProviderError):
    code = "CONTRACT_DRIFT"


class ProviderHTTPError(ProviderError):
    code = "HTTP_ERROR"
    def __init__(self, status: int, request_id: str | None = None):
        self.status = status; self.request_id = request_id
        super().__init__(f"ChatGPT returned HTTP {status} (request-id={request_id or 'n/a'})")


@dataclass(frozen=True)
class ResponseMeta:
    status: int
    request_id: str | None
    byte_count: int


class ChatGPTTransport:
    ORIGIN = "https://chatgpt.com"

    def __init__(self, access_token: str, settings: Settings):
        self.access_token = access_token; self.settings = settings; self.device_id = str(uuid.uuid4())
        self._client = httpx.AsyncClient(
            base_url=self.ORIGIN, timeout=httpx.Timeout(settings.request_timeout), follow_redirects=False, trust_env=False,
            headers={
                "Accept": "application/json", "Accept-Language": "en-US,en;q=0.9", "Origin": self.ORIGIN,
                "Referer": f"{self.ORIGIN}/", "Oai-Device-Id": self.device_id, "Oai-Language": "en-US",
                "Sec-Fetch-Dest": "empty", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Site": "same-origin",
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
            },
        )
        self._cooldown_until = 0.0; self._cooldown_lock = asyncio.Lock()

    async def aclose(self) -> None:
        await self._client.aclose()

    def auth_headers(self, workspace_id: str | None) -> dict[str, str]:
        headers = {"Authorization": f"Bearer {self.access_token}", "X-Authorization": f"Bearer {self.access_token}"}
        if workspace_id: headers["ChatGPT-Account-Id"] = require_identifier(workspace_id, "workspace id")
        return headers

    async def request_json(self, method: str, path: str, *, workspace_id: str | None = None,
                           body: dict | None = None, max_bytes: int | None = None) -> tuple[Any, ResponseMeta]:
        self._validate_path(method, path); cap = max_bytes or self.settings.max_json_bytes; last_status = None
        for attempt in range(9):
            await self._wait_cooldown()
            try:
                response = await self._client.request(method, path, headers=self.auth_headers(workspace_id), json=body if method == "POST" else None)
            except (httpx.TimeoutException, httpx.TransportError) as exc:
                if attempt >= 8: raise ProviderError(f"network request failed after retries: {type(exc).__name__}") from exc
                await asyncio.sleep(min(30.0, (2 ** attempt) + random.random())); continue
            last_status = response.status_code; request_id = response.headers.get("x-request-id") or response.headers.get("cf-ray")
            if response.status_code == 401: raise AuthenticationRequired("ChatGPT returned HTTP 401; import a fresh session")
            if response.status_code == 403: raise ProviderHTTPError(403, request_id)
            if response.status_code == 429:
                if attempt >= 8: raise RateLimitExhausted("ChatGPT rate limit persisted after bounded retries")
                retry_after = response.headers.get("retry-after")
                try: delay = float(retry_after) if retry_after else min(300.0, 5.0 * (2 ** attempt))
                except ValueError: delay = min(300.0, 5.0 * (2 ** attempt))
                loop = asyncio.get_running_loop()
                async with self._cooldown_lock: self._cooldown_until = max(self._cooldown_until, loop.time() + delay)
                continue
            if response.status_code in {408, 425, 500, 502, 503, 504}:
                if attempt >= 8: raise ProviderError(f"ChatGPT returned HTTP {response.status_code} after retries")
                await asyncio.sleep(min(60.0, (2 ** attempt) + random.random())); continue
            if not response.is_success: raise ProviderHTTPError(response.status_code, request_id)
            declared = response.headers.get("content-length")
            if declared and declared.isdigit() and int(declared) > cap: raise ContractDrift(f"response exceeded configured limit ({declared} > {cap})")
            data = response.content
            if len(data) > cap: raise ContractDrift(f"response exceeded configured limit ({len(data)} > {cap})")
            try: parsed = json.loads(data)
            except json.JSONDecodeError as exc: raise ContractDrift(f"expected JSON but received an incompatible response (HTTP {response.status_code})") from exc
            return parsed, ResponseMeta(response.status_code, request_id, len(data))
        raise ProviderError(f"request failed with HTTP {last_status or 'unknown'}")

    async def download_asset_to_temp(self, url: str, target_dir):
        return await download_asset_to_temp(url, target_dir, self.settings)

    async def _wait_cooldown(self) -> None:
        loop = asyncio.get_running_loop()
        async with self._cooldown_lock: delay = self._cooldown_until - loop.time()
        if delay > 0: await asyncio.sleep(delay)

    @staticmethod
    def _validate_path(method: str, path: str) -> None:
        if method not in {"GET", "POST"}: raise ValueError("unsupported method")
        if not path.startswith("/") or path.startswith("//") or ".." in path: raise ValueError("path must remain relative to chatgpt.com")
        if not (path.startswith("/backend-api/") or path.startswith("/public-api/")): raise ValueError("path is outside the read-only allowlist")

