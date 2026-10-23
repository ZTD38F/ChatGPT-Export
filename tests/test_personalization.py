from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from zipfile import ZipFile

from chatgpt_export.personalization_archive import create_bundle, contains_credential_fields
from chatgpt_export.provider import ChatGPTClient
from chatgpt_export.workspace_export import WorkspaceExporter


class BundleTests(unittest.TestCase):
    def test_bundle_contains_separate_files_and_checksums(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "account"
            fields = {
                "memories": {"memories": [{"text": "пример"}]},
                "custom_instructions": {"enabled": True, "about_user_message": "test"},
                "settings": {"settings": {"theme": "dark"}},
                "beta_features": {},
                "profile": {"profile_details": {"name": "TEST"}},
            }
            result = create_bundle(root, "private", fields, [], {"account_id": "demo"})
            self.assertEqual(result["status"], "COMPLETE_FOR_SUPPORTED_ENDPOINTS")
            self.assertTrue((root / "memory.json").is_file())
            self.assertTrue((root / "memories.json").exists() is False)  # legacy written by caller
            self.assertTrue((root / "account_metadata.json").is_file())
            self.assertEqual(json.loads((root / "memory.json").read_text()), fields["memories"])
            with ZipFile(root / "personalization.zip") as z:
                self.assertIsNone(z.testzip())
                self.assertEqual(json.loads(z.read("PERSONALIZATION/memory.json")), fields["memories"])
                self.assertEqual(json.loads(z.read("PERSONALIZATION/custom_instructions.json")), fields["custom_instructions"])
                self.assertEqual(json.loads(z.read("PERSONALIZATION/settings.json")), fields["settings"])
                self.assertIn("manifest.json", z.namelist())
            self.assertEqual((root / "personalization.zip").stat().st_mode & 0o777, 0o600)

    def test_partial_and_credential_filter(self):
        self.assertTrue(contains_credential_fields({"foo": [{"accessToken": "redacted-test"}]}))
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = create_bundle(root, "private", {"memories": []},
                                   [{"kind": "profile", "code": "HTTP_403"}],
                                   {"accessToken": "test"})
            self.assertEqual(result["status"], "PARTIAL")
            self.assertIn("profile", result["missing"])
            with ZipFile(root / "personalization.zip") as z:
                self.assertNotIn("PERSONALIZATION/account_metadata.json", z.namelist())
                self.assertIn("PERSONALIZATION/memory.json", z.namelist())


class PipelineTests(unittest.IsolatedAsyncioTestCase):
    async def test_account_export_preserves_files_and_survives_missing_endpoint(self):
        class Client:
            async def account_artifact(self, kind, workspace_id):
                if kind == "beta_features":
                    raise RuntimeError("unsupported")
                return {"kind": kind, "unicode": "ТЕСТ"}
        with tempfile.TemporaryDirectory() as td:
            exporter = object.__new__(WorkspaceExporter)
            workspace = SimpleNamespace(key="w-1", account_id="scope", raw={"account": "fake"})
            errors = await exporter._account_artifacts(Client(), workspace, Path(td))
            self.assertEqual(len(errors), 1)
            self.assertEqual(errors[0]["kind"], "beta_features")
            for name in ("memories.json", "memory.json", "custom_instructions.json",
                         "settings.json", "profile.json", "account_metadata.json",
                         "personalization_manifest.json", "personalization.zip"):
                self.assertTrue((Path(td) / "account" / name).is_file(), name)
            manifest = json.loads((Path(td)/"account/personalization_manifest.json").read_text())
            self.assertEqual(manifest["status"], "PARTIAL")

    async def test_provider_uses_observed_endpoint(self):
        calls = []
        class Transport:
            async def request_json(self, method, path, **kwargs):
                calls.append((method, path))
                return {"ok": True}, 200
        client = object.__new__(ChatGPTClient)
        client.transport = Transport()
        for kind in ("memories", "custom_instructions", "settings", "profile"):
            await client.account_artifact(kind, "demo")
        self.assertEqual(calls, [
            ("GET", "/backend-api/memories?include_memory_entries=true"),
            ("GET", "/backend-api/user_system_messages"),
            ("GET", "/backend-api/settings/user"),
            ("GET", "/backend-api/profiles/me"),
        ])
