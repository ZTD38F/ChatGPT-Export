"""Private, verifiable ZIP containing only this run's captured account settings.

Raw API values are kept unmodified; unavailable endpoints are explicitly reported.
No browser/session/authentication credentials are written to the archive.
"""
from __future__ import annotations

from io import BytesIO
import hashlib
import json
from pathlib import Path
import zipfile
from typing import Any

from .utils import atomic_write_bytes, atomic_write_json, canonical_json_bytes

BLOCKED = frozenset({
    "accesstoken", "access_token", "refreshtoken", "refresh_token",
    "authorization", "cookie", "sessiontoken", "session_token",
    "api_key", "apikey", "client_secret", "password",
})
EXPECTED = ("memories", "custom_instructions", "settings", "beta_features", "profile")


def contains_credential_fields(value: Any) -> bool:
    if isinstance(value, dict):
        return any(str(k).lower() in BLOCKED or contains_credential_fields(v)
                   for k, v in value.items())
    if isinstance(value, list):
        return any(contains_credential_fields(v) for v in value)
    return False


def create_bundle(account_dir: Path, workspace_key: str, successful: dict[str, Any],
                  failures: list[dict[str, str]], account_metadata: Any) -> dict:
    account_dir.mkdir(parents=True, exist_ok=True)
    files: dict[str, bytes] = {}
    for kind, value in successful.items():
        if kind not in EXPECTED:
            raise ValueError("Unsupported personal artifact: " + kind)
        if not isinstance(value, (dict, list)):
            raise ValueError("Invalid personal artifact type: " + kind)
        if contains_credential_fields(value):
            raise ValueError("Credential-like field in personal artifact: " + kind)
        files[kind + ".json"] = canonical_json_bytes(value)
        if kind == "memories":
            files["memory.json"] = files[kind + ".json"]  # Friendly alias; keep legacy name.
    metadata_status = "UNAVAILABLE"
    if isinstance(account_metadata, (dict, list)) and not contains_credential_fields(account_metadata):
        files["account_metadata.json"] = canonical_json_bytes(account_metadata)
        metadata_status = "CAPTURED"
    elif account_metadata is not None:
        metadata_status = "SKIPPED_UNEXPECTED_OR_SENSITIVE"

    records = {
        name: {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        for name, data in sorted(files.items())
    }
    missing = [name for name in EXPECTED if name not in successful]
    manifest = {
        "schema": "sonoryx-chatgpt-personalization-v1",
        "workspace": workspace_key,
        "status": "COMPLETE_FOR_SUPPORTED_ENDPOINTS" if not missing else "PARTIAL",
        "captured": [name for name in EXPECTED if name in successful],
        "missing": missing,
        "account_metadata": metadata_status,
        "errors": [{"kind": e.get("kind"), "code": e.get("code")} for e in failures],
        "files": records,
        "not_official_export": True,
        "limits": "Undocumented ChatGPT API; not all Memory summaries or account settings may be exposed.",
    }
    # Keep standalone friendly files without replacing legacy snapshots.
    if "memory.json" in files:
        atomic_write_bytes(account_dir / "memory.json", files["memory.json"], mode=0o600)
    if "account_metadata.json" in files:
        atomic_write_bytes(account_dir / "account_metadata.json", files["account_metadata.json"], mode=0o600)
    atomic_write_json(account_dir / "personalization_manifest.json", manifest)
    manifest_bytes = canonical_json_bytes(manifest)
    memory = BytesIO()
    with zipfile.ZipFile(memory, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.writestr("manifest.json", manifest_bytes)
        for name, data in sorted(files.items()):
            z.writestr("PERSONALIZATION/" + name, data)
    content = memory.getvalue()
    with zipfile.ZipFile(BytesIO(content)) as z:
        if z.testzip() is not None:
            raise ValueError("Personalization ZIP CRC failed")
        if z.read("manifest.json") != manifest_bytes:
            raise ValueError("Personalization ZIP manifest mismatch")
        for name, data in files.items():
            if hashlib.sha256(z.read("PERSONALIZATION/" + name)).hexdigest() != records[name]["sha256"]:
                raise ValueError("Personalization ZIP SHA mismatch: " + name)
    archive = account_dir / "personalization.zip"
    atomic_write_bytes(archive, content, mode=0o600)
    return {"archive": archive.name, "sha256": hashlib.sha256(content).hexdigest(),
            "status": manifest["status"], "captured": len(successful), "missing": missing}
