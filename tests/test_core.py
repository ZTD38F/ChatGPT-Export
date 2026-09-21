from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from cryptography.fernet import Fernet

from chatgpt_export.security import SecretStore, require_access_token
from chatgpt_export.utils import safe_component, require_identifier
from chatgpt_export.render import conversation_markdown
from chatgpt_export.exporter import ExportManager
from chatgpt_export.pagination import offset_chain, cursor_chain, InventoryFailure
from chatgpt_export.inventory import InventoryEngine
from chatgpt_export.asset_net import validate_asset_url, AssetNetworkError
from chatgpt_export.config import Settings


class SecurityTests(unittest.TestCase):
    def test_session_roundtrip_is_encrypted(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            key = root / "key"
            key.write_bytes(Fernet.generate_key())
            store = SecretStore(key, root / "session.enc")
            session = {"accessToken": "x" * 64, "user": {"name": "Synthetic"}}
            store.save_session(session)
            raw = (root / "session.enc").read_bytes()
            self.assertNotIn(b"Synthetic", raw)
            self.assertEqual(store.load_session(), session)

    def test_access_token_validation(self):
        self.assertEqual(require_access_token({"accessToken": "a" * 40}), "a" * 40)
        with self.assertRaises(ValueError):
            require_access_token({"accessToken": "short"})


class UtilityTests(unittest.TestCase):
    def test_safe_component(self):
        self.assertNotIn("/", safe_component("a/b:c"))
        self.assertEqual(require_identifier("abc_DEF-123"), "abc_DEF-123")
        with self.assertRaises(ValueError):
            require_identifier("../escape")

    def test_markdown_keeps_basic_roles(self):
        convo = {
            "title": "Synthetic",
            "mapping": {
                "r": {"parent": None, "children": ["u"], "message": None},
                "u": {"parent": "r", "children": ["a"], "message": {"author": {"role": "user"}, "content": {"parts": ["Hello"]}}},
                "a": {"parent": "u", "children": [], "message": {"author": {"role": "assistant"}, "content": {"parts": ["World"]}}},
            },
        }
        md = conversation_markdown(convo)
        self.assertIn("## User", md)
        self.assertIn("Hello", md)
        self.assertIn("## Assistant", md)
        self.assertIn("World", md)

    def test_file_reference_extraction(self):
        refs = ExportManager._extract_file_refs({
            "parts": [{"content_type": "image_asset_pointer", "asset_pointer": "file-service://file_abc"}],
            "metadata": {
                "attachments": [{"id": "file_def", "name": "doc.pdf"}],
                "citations": [{"metadata": {"file_id": "file_cit", "title": "source.pdf"}}],
            },
        })
        self.assertEqual(refs["file_abc"], "image")
        self.assertEqual(refs["file_def"], "doc.pdf")
        self.assertEqual(refs["file_cit"], "source.pdf")


class GptFileTests(unittest.TestCase):
    def test_extracts_gpt_knowledge_file_descriptors(self):
        value = {
            "resource": {
                "gizmo": {
                    "id": "g-abc",
                    "knowledge_files": [
                        {"file_id": "file-abc", "name": "notes.pdf"},
                        {"file_id": "file-def", "name": "manual.txt"},
                    ],
                }
            }
        }
        found = ExportManager._extract_gpt_file_descriptors(value)
        self.assertEqual({x["file_id"] for x in found}, {"file-abc", "file-def"})


class PaginationTests(unittest.IsolatedAsyncioTestCase):
    async def test_offset_chain_detects_repeated_page(self):
        with tempfile.TemporaryDirectory() as td:
            calls = 0
            async def fetch(offset, limit):
                nonlocal calls
                calls += 1
                return {"items": [{"id": "same"}], "total": 3}
            with self.assertRaises(InventoryFailure) as ctx:
                await offset_chain(fetch, Path(td), "conversation", 1, 10)
            self.assertEqual(ctx.exception.code, "INVENTORY_REPEATED_PAGE")
            self.assertGreaterEqual(calls, 2)

    async def test_offset_chain_detects_premature_empty_page(self):
        with tempfile.TemporaryDirectory() as td:
            async def fetch(offset, limit):
                if offset == 0:
                    return {"items": [{"id": "one"}], "total": 3}
                return {"items": [], "total": 3}
            with self.assertRaises(InventoryFailure) as ctx:
                await offset_chain(fetch, Path(td), "conversation", 1, 10)
            self.assertEqual(ctx.exception.code, "INVENTORY_PREMATURE_EMPTY_PAGE")

    async def test_cursor_chain_detects_cursor_cycle(self):
        with tempfile.TemporaryDirectory() as td:
            async def fetch(cursor):
                return {"items": [{"id": f"item-{cursor}"}], "cursor": "0"}
            with self.assertRaises(InventoryFailure) as ctx:
                await cursor_chain(fetch, Path(td), "0", 10)
            self.assertEqual(ctx.exception.code, "INVENTORY_CURSOR_CYCLE")


class InventoryWorkspaceTests(unittest.IsolatedAsyncioTestCase):
    async def test_workspace_discovery_deduplicates_and_skips_deactivated(self):
        class FakeClient:
            async def accounts(self):
                return {"accounts": {
                    "a": {"account": {"account_id": "acct-1", "account_name": "Personal"}, "is_deactivated": False},
                    "a-duplicate": {"account": {"account_id": "acct-1", "account_name": "Personal duplicate"}, "is_deactivated": False},
                    "b": {"account": {"account_id": "acct-2", "account_name": "Old"}, "is_deactivated": True},
                }}
        with tempfile.TemporaryDirectory() as td:
            settings = Settings(
                state_dir=Path(td), data_dir=Path(td)/"data", key_file=Path(td)/"key", admin_token_file=Path(td)/"admin",
                bind_host="127.0.0.1", bind_port=8788, concurrency=1, page_size=100, request_timeout=30,
                max_json_bytes=10_000_000, max_asset_bytes=10_000_000, max_pages_per_chain=100,
            )
            result = await InventoryEngine(settings).discover_workspaces(FakeClient(), Path(td)/"run")
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0].account_id, "acct-1")
            self.assertTrue(result[0].key.startswith("account-"))


class AssetNetworkTests(unittest.TestCase):
    def test_rejects_non_https_and_nonstandard_port(self):
        with self.assertRaises(AssetNetworkError): validate_asset_url("http://example.com/file")
        with self.assertRaises(AssetNetworkError): validate_asset_url("https://example.com:8443/file")
        self.assertEqual(validate_asset_url("https://example.com/file").hostname, "example.com")


if __name__ == "__main__":
    unittest.main()
