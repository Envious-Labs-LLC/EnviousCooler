"""Installer fault checks using temporary bundles; never touch launchd or USB."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
import subprocess
import sys
from unittest.mock import patch
import runtime_tools

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("installer", ROOT / "install-menu.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root / "app"
        self.legacy = self.root / "legacy-app"
        self.data = self.root / "data"
        self.legacy_data = self.root / "legacy-data"
        self.stage = self.root / "stage"
        self.stage.mkdir()
        self.backup = self.stage / "Previous.app"
        self.app.mkdir(); self.backup.mkdir(); self.data.mkdir()
        (self.backup / "marker").write_text("working app")
        (self.data / "capture").write_text("private capture")
        self.patches = [patch.object(installer, "APP", self.app),
                        patch.object(installer, "LEGACY_APP", self.legacy),
                        patch.object(installer, "FOLDER", self.data),
                        patch.object(installer, "LEGACY_FOLDER", self.legacy_data),
                        patch.object(installer, "restore_agent_file"),
                        patch.object(installer, "restore_registration"), patch.object(installer, "stop_menu")]
        for item in self.patches: item.start()
        self.snapshots = {installer.IDENTIFIER: (None, False), installer.LEGACY_ID: (None, False)}

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temp.cleanup()

    def test_enabled_but_stopped_is_preserved(self):
        self.assertTrue(installer.needs_auto({"enabled": True, "running": False}))
        self.assertFalse(installer.needs_auto({"enabled": False, "running": False}))

    def test_management_lock_blocks_competing_process_and_allows_inherited_owner(self):
        environment = os.environ.copy()
        environment.pop(runtime_tools.LOCK_VARIABLE, None)
        environment["TMPDIR"] = str(self.root)
        code = "from runtime_tools import management_lock;\nwith management_lock(): print('owned')"
        with patch.object(runtime_tools.tempfile, "gettempdir", return_value=str(self.root)):
            with runtime_tools.management_lock() as descriptor:
                denied = subprocess.run([sys.executable, "-c", code], cwd=ROOT, env=environment,
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(denied.returncode, 0)
                environment[runtime_tools.LOCK_VARIABLE] = str(descriptor)
                allowed = subprocess.run([sys.executable, "-c", code], cwd=ROOT, env=environment,
                                         pass_fds=(descriptor,), capture_output=True, text=True, timeout=5)
                self.assertEqual(allowed.returncode, 0, allowed.stderr)
                self.assertIn("owned", allowed.stdout)

    def test_only_service_changes_receive_the_management_lock(self):
        with patch.object(installer, "lock_descriptor", 7), \
                patch.dict(os.environ, {runtime_tools.LOCK_VARIABLE: "9"}), \
                patch.object(installer.subprocess, "run") as child:
            installer.run("open", str(self.app), "--args", "--dashboard")
            installer.run_locked(sys.executable, "auto-mode.py", "off")
        opened, locked = child.call_args_list
        self.assertNotIn(runtime_tools.LOCK_VARIABLE, opened.kwargs["env"])
        self.assertEqual(opened.kwargs["pass_fds"], ())
        self.assertEqual(locked.kwargs["env"][runtime_tools.LOCK_VARIABLE], "7")
        self.assertEqual(locked.kwargs["pass_fds"], (7,))

    def test_rollback_open_calls_never_receive_the_management_lock(self):
        self.legacy.mkdir()
        with patch.object(installer, "lock_descriptor", 7), \
                patch.object(installer.subprocess, "run") as child:
            child.return_value = subprocess.CompletedProcess([], 0, "{}", "")
            try:
                installer.rollback(self.stage, self.backup, True, False, self.snapshots, True, True)
            except RuntimeError:
                pass
        opens = [call for call in child.call_args_list if call.args[0][0] == "open"]
        self.assertTrue(opens)
        for call in opens:
            self.assertNotIn(runtime_tools.LOCK_VARIABLE, call.kwargs["env"])
            self.assertEqual(call.kwargs["pass_fds"], ())

    def test_rollback_continues_after_shutdown_failure(self):
        def fail_stop(*args, **kwargs):
            if args[-1] == "off": raise RuntimeError("shutdown failed")
        with patch.object(installer, "run", side_effect=fail_stop):
            with self.assertRaisesRegex(RuntimeError, "Recovery material retained"):
                installer.rollback(self.stage, self.backup, True, True, self.snapshots, False, False)
        self.assertEqual((self.app / "marker").read_text(), "working app")
        self.assertEqual((self.legacy_data / "capture").read_text(), "private capture")
        self.assertTrue((self.stage / "Failed.app").exists())
        self.assertEqual(installer.restore_agent_file.call_count, len(self.snapshots))

    def test_failed_bundle_restore_retains_backup(self):
        original = Path.rename
        def fail_restore(path, target):
            if path == self.backup: raise OSError("cannot restore")
            return original(path, target)
        with patch.object(installer, "run"), patch.object(Path, "rename", fail_restore):
            with self.assertRaisesRegex(RuntimeError, "Recovery material retained"):
                installer.rollback(self.stage, self.backup, True, False, self.snapshots, False, False)
        self.assertEqual((self.backup / "marker").read_text(), "working app")
        self.assertEqual(installer.restore_agent_file.call_count, len(self.snapshots))

    def test_failed_agent_restoration_does_not_skip_other_agents(self):
        installer.restore_agent_file.side_effect = [OSError("first agent failed"), None]
        with patch.object(installer, "run"):
            with self.assertRaisesRegex(RuntimeError, "Recovery material retained"):
                installer.rollback(self.stage, self.backup, True, False, self.snapshots, False, False)
        self.assertEqual(installer.restore_agent_file.call_count, 2)

    def test_failed_new_bundle_move_never_reopens_it(self):
        original = Path.rename
        def fail_move(path, target):
            if path == self.app: raise OSError("cannot move new app")
            return original(path, target)
        self.legacy.mkdir()
        with patch.object(installer, "run") as run, patch.object(Path, "rename", fail_move):
            with self.assertRaisesRegex(RuntimeError, "Recovery material retained"):
                installer.rollback(self.stage, self.backup, True, False, self.snapshots, True, True)
        opens = [call.args[1] for call in run.call_args_list if call.args[0] == "open"]
        self.assertEqual(opens, [str(self.legacy)])
        self.assertTrue(self.backup.exists())

    def test_early_rollback_does_not_create_retry_blocking_folder(self):
        self.data.rmdir() if not any(self.data.iterdir()) else None
        (self.data / "capture").unlink(); self.data.rmdir()
        with patch.object(installer, "run") as run:
            installer.rollback(self.stage, self.backup, False, False, self.snapshots, False, False)
        self.assertFalse(self.data.exists())
        self.assertFalse(any(call.args[-1] == "off" for call in run.call_args_list))

    def test_agent_snapshots_are_durable(self):
        snapshots = {"example": (b"original", True), "absent": (None, False)}
        installer.save_agent_snapshots(self.stage, snapshots)
        import json
        manifest = json.loads((self.stage / "agent-snapshots/manifest.json").read_text())
        self.assertEqual(manifest["example"], {"existed": True, "registered": True})
        self.assertEqual((self.stage / "agent-snapshots/example.plist").read_bytes(), b"original")

    def test_failed_bundle_cleanup_still_removes_login_agents(self):
        self.legacy.mkdir()
        paths = {label: self.root / f"{label}.plist" for label in [installer.LEGACY_ID, installer.LEGACY_LABEL]}
        for path in paths.values(): path.write_text("agent")
        with patch.object(installer, "agent_path", side_effect=lambda label: paths[label]), \
             patch.object(installer.shutil, "rmtree", side_effect=OSError("cannot delete bundle")):
            errors = installer.cleanup_predecessor()
        self.assertEqual(len(errors), 1)
        self.assertTrue(all(not path.exists() for path in paths.values()))

    def test_partial_launch_candidate_ui_is_stopped(self):
        with patch.object(installer, "run"):
            installer.rollback(self.stage, self.backup, True, False, self.snapshots, False, False)
        installer.stop_menu.assert_called_once_with(self.app, "EnviousCooler")

    def test_folder_inspection_failure_does_not_skip_agent_recovery(self):
        original = Path.iterdir
        def fail_inspection(path):
            if path == self.data: raise OSError("inspection failed")
            return original(path)
        with patch.object(installer, "run"), patch.object(Path, "iterdir", fail_inspection):
            with self.assertRaisesRegex(RuntimeError, "Recovery material retained"):
                installer.rollback(self.stage, self.backup, True, False, self.snapshots, False, False)
        self.assertEqual(installer.restore_agent_file.call_count, len(self.snapshots))

    def test_successful_rollback_restores_data_and_bundle(self):
        with patch.object(installer, "run"):
            installer.rollback(self.stage, self.backup, True, True, self.snapshots, False, False)
        self.assertTrue((self.app / "marker").exists())
        self.assertTrue((self.legacy_data / "capture").exists())
        self.assertFalse(self.backup.exists())


if __name__ == "__main__": unittest.main()
