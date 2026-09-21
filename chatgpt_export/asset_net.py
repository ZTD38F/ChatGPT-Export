from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import os
from pathlib import Path
import socket
import tempfile
from urllib.parse import urljoin, urlparse

import httpx

from .config import Settings


class AssetNetworkError(RuntimeError):
    code = "ASSET_NETWORK_ERROR"


async def download_asset_to_temp(url: str, target_dir: Path, settings: Settings) -> tuple[Path, str | None, str, int]:
    target_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".asset-", suffix=".tmp", dir=str(target_dir))
    os.close(fd)
    tmp = Path(tmp_name)
    current = url
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(settings.request_timeout), follow_redirects=False, trust_env=False) as client:
            for _ in range(6):
                parsed = validate_asset_url(current)
                await asyncio.to_thread(validate_public_hostname, parsed.hostname or "")
                async with client.stream("GET", current, headers={"User-Agent": "Mozilla/5.0 ChatGPT-Export/0.1"}) as response:
                    if response.status_code in {301, 302, 303, 307, 308}:
                        location = response.headers.get("location")
                        if not location: raise AssetNetworkError("asset redirect omitted Location")
                        current = urljoin(current, location)
                        redirect = validate_asset_url(current)
                        await asyncio.to_thread(validate_public_hostname, redirect.hostname or "")
                        continue
                    if not response.is_success: raise AssetNetworkError(f"asset download returned HTTP {response.status_code}")
                    declared = response.headers.get("content-length")
                    if declared and declared.isdigit() and int(declared) > settings.max_asset_bytes:
                        raise AssetNetworkError("asset exceeds configured size limit")
                    digest = hashlib.sha256(); total = 0
                    with tmp.open("wb") as handle:
                        async for chunk in response.aiter_bytes(1024 * 1024):
                            total += len(chunk)
                            if total > settings.max_asset_bytes: raise AssetNetworkError("asset exceeds configured size limit")
                            handle.write(chunk); digest.update(chunk)
                        handle.flush(); os.fsync(handle.fileno())
                    os.chmod(tmp, 0o600)
                    return tmp, response.headers.get("content-type"), digest.hexdigest(), total
            raise AssetNetworkError("asset redirect limit exceeded")
    except Exception:
        try: tmp.unlink()
        except FileNotFoundError: pass
        raise


def validate_asset_url(url: str):
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise AssetNetworkError("asset URL is not acceptable HTTPS")
    if parsed.port not in (None, 443):
        raise AssetNetworkError("asset URL uses an unexpected port")
    return parsed


def validate_public_hostname(hostname: str) -> None:
    if hostname.lower() in {"localhost", "localhost.localdomain"}: raise AssetNetworkError("asset host is local")
    try: addresses = socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
    except socket.gaierror as exc: raise AssetNetworkError("asset hostname could not be resolved") from exc
    if not addresses: raise AssetNetworkError("asset hostname resolved to no addresses")
    for item in addresses:
        ip = ipaddress.ip_address(item[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
            raise AssetNetworkError("asset hostname resolved to a non-public address")
