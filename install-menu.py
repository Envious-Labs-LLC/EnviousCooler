#!/usr/bin/env python3
"""Stage a complete app, preserve rollback material, and migrate the prototype."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from runtime_tools import atomic_bytes, management_lock, LOCK_VARIABLE

ROOT = Path(__file__).resolve().parent
APP = Path.home() / "Applications/EnviousCooler.app"
IDENTIFIER = "co.enviouslabs.enviouscooler-menu"
LABEL = "co.enviouslabs.enviouscooler"
AGENT = Path.home() / "Library/LaunchAgents" / f"{IDENTIFIER}.plist"
FOLDER = Path.home() / "Library/Application Support/EnviousCooler"
LEGACY_APP = Path.home() / "Applications/Razer Cooling Pad.app"
LEGACY_FOLDER = Path.home() / "Library/Application Support/RazerCoolingPad"
LEGACY_ID = "co.enviouslabs.razer-cooling-pad-menu"
LEGACY_LABEL = "co.enviouslabs.razer-cooling-pad"
DOMAIN = f"gui/{os.getuid()}"
lock_descriptor = None


def run(*args, check=True, _locked=False):
    # Only short-lived service changes share the lock; anything else, such as
    # an app started with `open`, would keep a descriptor number it never had.
    environment = os.environ.copy()
    environment.pop(LOCK_VARIABLE, None)
    descriptors = ()
    if _locked and lock_descriptor is not None:
        environment[LOCK_VARIABLE] = str(lock_descriptor)
        descriptors = (lock_descriptor,)
    return subprocess.run(args, check=check, capture_output=True, text=True,
                          timeout=30, env=environment, pass_fds=descriptors)


def run_locked(*args, check=True):
    return run(*args, check=check, _locked=True)


def registered(label):
    return run("launchctl", "print", f"{DOMAIN}/{label}", check=False).returncode == 0


def unload(label):
    if registered(label):
        run("launchctl", "bootout", f"{DOMAIN}/{label}")
    if registered(label):
        raise RuntimeError(f"Service still registered: {label}")


def verify_owner(app, identifier):
    if app.is_symlink():
        raise RuntimeError("Refusing to replace an application symlink.")
    if app.exists():
        with (app / "Contents/Info.plist").open("rb") as file:
            if plistlib.load(file).get("CFBundleIdentifier") != identifier:
                raise RuntimeError("An unrelated application owns this path.")


def stop_menu(app, executable_name):
    executable = str(app / "Contents/MacOS" / executable_name)
    pids = []
    for line in run("ps", "-axo", "pid=,comm=").stdout.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2 and parts[1] == executable:
            try:
                pid = int(parts[0]); os.kill(pid, signal.SIGTERM); pids.append(pid)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 5
    for pid in pids:
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Menu app did not exit; installation left untouched.")
            time.sleep(0.05)


def agent_path(label):
    return Path.home() / "Library/LaunchAgents" / f"{label}.plist"


def preserve_agents(labels):
    snapshots = {}
    for label in labels:
        path = agent_path(label)
        data = path.read_bytes() if path.exists() else None
        if data is not None and plistlib.loads(data).get("Label") != label:
            raise RuntimeError(f"An unrelated login service owns {path}.")
        snapshots[label] = (data, registered(label))
    return snapshots


def save_agent_snapshots(stage_root, snapshots):
    directory = stage_root / "agent-snapshots"
    directory.mkdir(mode=0o700)
    manifest = {}
    for label, (data, registered_before) in snapshots.items():
        manifest[label] = {"existed": data is not None, "registered": registered_before}
        if data is not None:
            atomic_bytes(data, directory / f"{label}.plist")
    atomic_bytes(json.dumps(manifest).encode(), directory / "manifest.json")


def restore_agent_file(label, data):
    path = agent_path(label)
    if data is None:
        path.unlink(missing_ok=True)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_bytes(data, path)


def needs_auto(state):
    return state.get("enabled") is True or state.get("running") is True


def cleanup_predecessor():
    actions = [lambda: agent_path(LEGACY_ID).unlink(missing_ok=True),
               lambda: agent_path(LEGACY_LABEL).unlink(missing_ok=True),
               lambda: shutil.rmtree(LEGACY_APP) if LEGACY_APP.exists() else None,
               lambda: (FOLDER / "razer-pad").unlink(missing_ok=True)]
    errors = []
    for action in actions:
        try:
            action()
        except OSError as error:
            errors.append(str(error))
    return errors


def restore_registration(label, snapshot):
    data, was_registered = snapshot
    if was_registered and data is not None and not registered(label):
        run("launchctl", "bootstrap", DOMAIN, str(agent_path(label)))


def rollback(stage_root, backup, committed, migrated, snapshots, current_auto, legacy_auto, folder_existed=False):
    errors = []
    previous_restored = False
    def attempt(name, action):
        try:
            action()
        except Exception as error:
            errors.append(f"{name}: {error}")
    def save_candidate():
        if APP.exists(): APP.rename(stage_root / "Failed.app")
    def restore_previous():
        nonlocal previous_restored
        if backup.exists() and not APP.exists():
            backup.rename(APP); previous_restored = True
        elif not committed and APP.exists():
            previous_restored = True
    def restore_data():
        if FOLDER.exists() and not LEGACY_FOLDER.exists(): FOLDER.rename(LEGACY_FOLDER)
    def remove_empty_folder():
        if FOLDER.exists() and not any(FOLDER.iterdir()): FOLDER.rmdir()
    def restart_legacy():
        if LEGACY_APP.exists(): run_locked(sys.executable, str(LEGACY_APP / "Contents/Resources/auto-mode.py"), "on")
    def reopen_previous():
        if previous_restored: run("open", str(APP), "--args", "--dashboard")
        elif LEGACY_APP.exists(): run("open", str(LEGACY_APP), "--args", "--dashboard")
    if committed:
        attempt("stop candidate UI", lambda: stop_menu(APP, "EnviousCooler"))
        attempt("stop updated controller", lambda: run_locked(sys.executable, str(ROOT / "auto-mode.py"), "off"))
        attempt("save failed bundle", save_candidate)
    attempt("restore previous bundle", restore_previous)
    if migrated: attempt("restore prototype data", restore_data)
    if not migrated and not folder_existed: attempt("remove installer-created empty folder", remove_empty_folder)
    for label, (data, _) in snapshots.items():
        attempt(f"restore login file {label}", lambda label=label, data=data: restore_agent_file(label, data))
    if current_auto and previous_restored:
        attempt("restart previous controller", lambda: run_locked(sys.executable, str(APP / "Contents/Resources/auto-mode.py"), "on"))
    if legacy_auto: attempt("restart prototype controller", restart_legacy)
    for label in [IDENTIFIER, LEGACY_ID]:
        attempt(f"restore {label}", lambda label=label: restore_registration(label, snapshots[label]))
    attempt("reopen previous app", reopen_previous)
    if errors:
        raise RuntimeError("Recovery material retained at " + str(stage_root) + "; " + "; ".join(errors))


def install_locked():
    verify_owner(APP, IDENTIFIER)
    verify_owner(LEGACY_APP, LEGACY_ID)
    if LEGACY_FOLDER.exists() and FOLDER.exists():
        raise RuntimeError("Both prototype and EnviousCooler data folders exist; refusing to merge them implicitly.")
    snapshots = preserve_agents([IDENTIFIER, LABEL, LEGACY_ID, LEGACY_LABEL])
    folder_existed = FOLDER.exists()
    subprocess.run([sys.executable, str(ROOT / "build.py")], check=True)
    APP.parent.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix=".enviouscooler-install-", dir=APP.parent))
    stage, backup = stage_root / APP.name, stage_root / "Previous.app"
    committed = migrated = changed = succeeded = recovered = False
    try:
        save_agent_snapshots(stage_root, snapshots)
        contents = stage / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        shutil.copy2(ROOT / "enviouscooler-menu", contents / "MacOS/EnviousCooler")
        for name in ["enviouscooler", "auto-mode.py", "runtime_tools.py"]:
            shutil.copy2(ROOT / name, contents / "Resources" / name)
        shutil.copy2(ROOT / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
        info = {"CFBundleIdentifier": IDENTIFIER, "CFBundleName": "EnviousCooler",
                "CFBundleDisplayName": "EnviousCooler", "CFBundleExecutable": "EnviousCooler",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
                "CFBundleIconFile": "AppIcon.icns",
                "LSUIElement": True, "NSHighResolutionCapable": True, "LSMinimumSystemVersion": "14.0",
                "PythonExecutable": shutil.which("python3") or sys.executable}
        atomic_bytes(plistlib.dumps(info), contents / "Info.plist")
        run("codesign", "--force", "--deep", "--sign", "-", str(stage))
        run("codesign", "--verify", "--deep", "--strict", str(stage))
        current = json.loads(run(sys.executable, str(ROOT / "auto-mode.py"), "status").stdout)
        legacy_manager = LEGACY_APP / "Contents/Resources/auto-mode.py"
        legacy = json.loads(run(sys.executable, str(legacy_manager), "status").stdout) if legacy_manager.exists() else {}
        current_auto, legacy_auto = needs_auto(current), needs_auto(legacy)
        changed = True
        stop_menu(APP, "EnviousCooler")
        stop_menu(LEGACY_APP, "RazerCoolingPad")
        unload(IDENTIFIER); unload(LEGACY_ID)
        if legacy_manager.exists():
            run_locked(sys.executable, str(legacy_manager), "off")
        run_locked(sys.executable, str(ROOT / "auto-mode.py"), "off")
        # A manager's off command may create an empty new folder. Remove only that
        # verified-empty directory, never existing runtime data.
        if LEGACY_FOLDER.exists() and FOLDER.exists() and not any(FOLDER.iterdir()):
            FOLDER.rmdir()
        if LEGACY_FOLDER.exists() and not FOLDER.exists():
            LEGACY_FOLDER.rename(FOLDER); migrated = True
        if APP.exists():
            APP.rename(backup)
        stage.rename(APP); committed = True
        AGENT.parent.mkdir(parents=True, exist_ok=True)
        atomic_bytes(plistlib.dumps({"Label": IDENTIFIER,
            "ProgramArguments": [str(APP / "Contents/MacOS/EnviousCooler")],
            "RunAtLoad": True, "ProcessType": "Interactive"}), AGENT)
        if current_auto or legacy_auto:
            result = run_locked(sys.executable, str(APP / "Contents/Resources/auto-mode.py"), "on")
            if json.loads(result.stdout).get("status") != "running":
                raise RuntimeError("Updated controller did not report healthy operation.")
        if registered(LEGACY_ID) or registered(LEGACY_LABEL):
            raise RuntimeError("Prototype service is still active.")
        run("open", str(APP), "--args", "--dashboard")
        succeeded = True
    except Exception:
        if changed:
            rollback(stage_root, backup, committed, migrated, snapshots, current_auto, legacy_auto, folder_existed)
        recovered = True
        raise
    finally:
        if succeeded or recovered or not changed:
            shutil.rmtree(stage_root, ignore_errors=True)
    # Cleanup is after the transaction. Failure here must never roll back a healthy app.
    for error in cleanup_predecessor():
        print(f"EnviousCooler is installed; prototype cleanup needs attention: {error}", file=sys.stderr)
    print(APP)


if __name__ == "__main__":
    with management_lock() as lock_descriptor:
        install_locked()
