#!/usr/bin/env python3
"""Exercise the explicit provider cutover without network or host services."""
import base64
import contextlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cutover = load("provider_cutover", ROOT/"scripts/migrate-providers-to-fleet.py")


class ApiError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class Harness:
    def __init__(self, home):
        self.home = home
        self.context = {"origin": "https://auth.test", "subject": "1"}
        self.engine = load("cutover_engine", ROOT/"files/fleet-providers.py")
        for attr, name in (("REGISTRY_PATH", "registry.json"), ("STATE_PATH", "state.json"),
                           ("CACHE_PATH", "credentials.json"), ("CATALOG_PATH", "catalog.json"),
                           ("CONSUMER_SYNC_LOCK", "consumer.lock")):
            setattr(self.engine, attr, str(home/name))
        self.engine.common_auth_context = lambda: self.context
        self.registry = {"version": 1, "providers": {"demo": {
            "provider_type": "OpenAICompatible", "base_url": "https://example.test/v1",
            "api_format": "openai", "npm": "@ai-sdk/openai-compatible", "enabled": True,
            "auth": {"type": "api-key", "store": "opencode", "key": "demo"}}}}
        self.save(home/"registry.json", json.dumps(self.registry))
        self.save(home/"state.json", json.dumps({"version": 1, "providers": {"demo": {"enabled": False}}}))
        self.engine._save_cache({"demo": "own-key", "_common_auth_context": self.context})
        self.legacy = home/".local/bin/providers"
        self.save(self.legacy, "legacy executable")
        self.save(home/"setup-state/script-state.tsv", "providers\told\tx\ty\nother\tkeep\tx\ty\n")
        self.settings = None
        self.counter = 0
        self.pushes = []
        self.events = []
        self.failure = None
        self.old_job = self.nightly = True
        self.fleet = SimpleNamespace(HOME=home, FLEET_STATE=home/"fleet-state",
            MANIFEST_PATH=home/".config/fleet/manifest.json", ApiError=ApiError,
            provider_engine=lambda: self.engine, _api=self.api, _fleet_lock=contextlib.nullcontext,
            schedule_installed=lambda: self.nightly, save_text=self.save)

    @staticmethod
    def save(path, data, mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode() if isinstance(data, str) else data)
        path.chmod(mode)

    def api(self, method, path, body=None):
        if path.endswith("/catalog"):
            return {"version": 1, "registry": copy.deepcopy(self.registry)}
        if path == "/api/fleet/config":
            return {"counter": self.counter, "files": [] if self.settings is None else [{"path": "settings/providers.json"}]}
        assert path == "/api/fleet/config/push"
        self.pushes.append(body)
        assert body["base"] == self.counter and body["subject"] == self.context["subject"]
        assert body["delete"] == [] and [p["path"] for p in body["put"]] == ["settings/providers.json"]
        if self.failure == "upload":
            raise ApiError("offline")
        if self.failure == "stale":
            self.failure = None
            self.settings = {"version": 2, "enabled": {"demo": True}}
            self.counter += 1
            raise ApiError("stale", 409)
        self.settings = json.loads(base64.b64decode(body["put"][0]["content"]))
        self.counter += 1
        return {"counter": self.counter}

    def run(self, command):
        action = command[-2:]
        self.events.append(action)
        stage = "sync" if action == ["sync", "--pull"] else "schedule"
        if self.failure == stage:
            raise subprocess.CalledProcessError(1, command)
        if stage == "schedule":
            self.nightly = True
        else:
            self.save(Path(self.engine.CATALOG_PATH), "{}")

    def retire(self, fleet):
        if self.nightly:
            assert ["schedule", "enable"] in self.events
        if self.failure == "retire":
            raise RuntimeError("old timer busy")
        self.events.append("retire")
        self.old_job = False

    def migrate(self):
        with patch.object(cutover, "legacy_scheduled", return_value=self.old_job), \
             patch.object(cutover, "retire_legacy_job", side_effect=self.retire), \
             patch.dict(os.environ, {"STATE_DIR": str(self.home/"setup-state")}), \
             contextlib.redirect_stdout(None):
            cutover.migrate(self.fleet, self.run)


class MigrationTests(unittest.TestCase):
    def test_success_and_repeat_preserve_original_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            h = Harness(Path(directory))
            original = Path(h.engine.REGISTRY_PATH).read_bytes()
            h.migrate()
            self.assertEqual(h.settings, {"version": 2, "enabled": {"demo": False}})
            self.assertFalse(h.legacy.exists())
            self.assertEqual(h.engine._load_cache()["_fleet_account"], h.context)
            self.assertEqual(h.engine.cache_get("demo"), "own-key")
            self.assertEqual(h.events, [["sync", "--pull"], ["schedule", "enable"], "retire"])
            self.assertTrue((h.home/".local/bin/fleet-providers.py").exists())
            rows = (h.home/"setup-state/script-state.tsv").read_text()
            self.assertNotIn("providers\t", rows)
            self.assertIn("other\tkeep\tx\ty\n", rows)
            self.assertNotIn("fleet\t", rows)
            Path(h.engine.REGISTRY_PATH).write_text("changed")
            h.migrate()
            self.assertEqual(len(h.pushes), 1)
            self.assertEqual((h.fleet.FLEET_STATE/"backup/providers-migration/registry.json").read_bytes(), original)

    def test_failures_keep_legacy_installation_and_allow_retry(self):
        for failure in ("upload", "sync", "schedule", "retire"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                h = Harness(Path(directory)); h.failure = failure
                with self.assertRaises((ApiError, subprocess.CalledProcessError, RuntimeError)):
                    h.migrate()
                self.assertTrue(h.legacy.exists())
                self.assertTrue(h.old_job)
                h.failure = None
                h.migrate()
                self.assertFalse(h.legacy.exists())

    def test_concurrent_dashboard_choices_win(self):
        with tempfile.TemporaryDirectory() as directory:
            h = Harness(Path(directory)); h.failure = "stale"
            h.migrate()
            self.assertTrue(h.settings["enabled"]["demo"])
            self.assertEqual(len(h.pushes), 1)

    def test_foreign_account_cannot_import_choices(self):
        with tempfile.TemporaryDirectory() as directory:
            h = Harness(Path(directory)); h.context = {"origin": "https://other.test", "subject": "2"}
            with self.assertRaisesRegex(RuntimeError, "ownership"):
                h.migrate()
            self.assertTrue(h.legacy.exists())
            self.assertFalse(h.events)
            self.assertFalse(h.pushes)

    def test_disabled_schedules_stay_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            h = Harness(Path(directory)); h.old_job = h.nightly = False
            h.migrate()
            self.assertNotIn(["schedule", "enable"], h.events)


if __name__ == "__main__":
    unittest.main()
