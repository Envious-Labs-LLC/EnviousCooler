"""Adversarial status/install checks without touching launchd or USB."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from runtime_tools import atomic_copy

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pad_service", ROOT / "auto-mode.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class ServiceChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.folder = Path(self.directory.name)
        self.original = service.FOLDER, service.PLIST, service.service_pid
        service.FOLDER = self.folder
        service.PLIST = self.folder / "agent.plist"
        service.service_pid = lambda: 12345

    def tearDown(self):
        service.FOLDER, service.PLIST, service.service_pid = self.original
        self.directory.cleanup()

    def write(self, value):
        (self.folder / "state.json").write_text(json.dumps(value))

    def state(self, delta=0, **extra):
        return {"pid": 12345, "status": "running", "updated_at":
                (datetime.now(timezone.utc) + timedelta(seconds=delta)).isoformat(), **extra}

    def test_corrupted_state_does_not_crash_or_claim_health(self):
        for value in [[], True, "text", {"pid": 12345, "updated_at": True}]:
            self.write(value)
            result = service.status()
            self.assertTrue(result["running"])
            self.assertNotEqual(result.get("status"), "running")

    def test_stale_future_and_wrong_process(self):
        for seconds in [-20, 20]:
            self.write(self.state(seconds))
            self.assertEqual(service.status()["status"], "unresponsive")
        self.write(self.state(pid=99999))
        self.assertNotEqual(service.status().get("status"), "running")

    def test_pad_off_is_reported_only_when_fresh_and_owned(self):
        self.write(self.state(status="pad_off"))
        self.assertEqual(service.status()["status"], "pad_off")
        self.write(self.state(20, status="pad_off"))
        self.assertEqual(service.status()["status"], "unresponsive")
        self.write(self.state(status="pad_off", pid=99999))
        self.assertNotEqual(service.status().get("status"), "pad_off")

    def test_file_cannot_override_launchd_authority(self):
        self.write(self.state(running=False, enabled=True))
        result = service.status()
        self.assertTrue(result["running"])
        self.assertFalse(result["enabled"])

    def test_oversized_state_rejected(self):
        (self.folder / "state.json").write_text(" " * 10000)
        self.assertEqual(service.status()["status"], "unconfirmed")

    def test_binary_replacement_preserves_old_open_inode(self):
        source, target = self.folder / "source", self.folder / "target"
        source.write_bytes(b"new")
        target.write_bytes(b"old")
        original_inode = target.stat().st_ino
        with target.open("rb") as old:
            atomic_copy(source, target)
            self.assertEqual(old.read(), b"old")
        self.assertEqual(target.read_bytes(), b"new")
        self.assertNotEqual(target.stat().st_ino, original_inode)


if __name__ == "__main__":
    unittest.main()
