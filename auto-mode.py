#!/usr/bin/env python3
"""Manage the native cooling controller as a user-owned macOS login service."""
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import fcntl
sys.dont_write_bytecode = True
from runtime_tools import atomic_copy, atomic_bytes, management_lock

LABEL = "co.enviouslabs.enviouscooler"
DOMAIN = f"gui/{os.getuid()}"
SERVICE = f"{DOMAIN}/{LABEL}"
FOLDER = Path.home() / "Library/Application Support/EnviousCooler"
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
SOURCE_BINARY = Path(__file__).resolve().parent / "enviouscooler"
INSTALLED_BINARY = FOLDER / "enviouscooler"


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=15)


def service_pid():
    result = command("launchctl", "print", SERVICE)
    if result.returncode:
        return None
    match = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.MULTILINE)
    return int(match.group(1)) if match else None


def wait_for_exit(pid):
    if pid is None:
        return
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)  # wait for actual process exit, not an assumed shutdown duration
    raise RuntimeError("Controller has not exited yet; its fan setting is unconfirmed.")


def status():
    pid = service_pid()
    state = {"enabled": PLIST.exists(), "running": pid is not None}
    try:
        with (FOLDER / "state.json").open() as file:
            text = file.read(4097)
        if len(text) > 4096:
            raise ValueError("Oversized controller state")
        observed = json.loads(text)
        if not isinstance(observed, dict):
            raise ValueError("Controller state must be an object")
        # A file from an older instance isn't current service status.
        if pid is not None and observed.get("pid") == pid:
            state.update(observed)
            stamp = observed.get("updated_at")
            if not isinstance(stamp, str):
                raise ValueError("Missing state timestamp")
            parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError("State timestamp must include timezone")
            age = (datetime.now(timezone.utc) - parsed).total_seconds()
            state["reading_age_seconds"] = round(age, 2)
            if age < -2 or (age > 10 and observed.get("status") != "sleeping"):
                state["status"] = "unresponsive"
    except (OSError, ValueError, KeyError, TypeError):
        if pid is not None:
            state["status"] = "unconfirmed"
    state["service_pid"] = pid
    state["running"] = pid is not None
    state["enabled"] = PLIST.exists()
    return state


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"on", "off", "status"}:
        raise RuntimeError("Use auto-mode.py on|off|status")
    action = sys.argv[1]
    if action == "status":
        print(json.dumps(status(), indent=2))
        return
    if action == "off":
        pid = service_pid()
        result = command("launchctl", "bootout", SERVICE)
        if result.returncode and service_pid() is not None:
            raise RuntimeError(result.stderr.strip() or "Could not stop automatic mode.")
        PLIST.unlink(missing_ok=True)
        wait_for_exit(pid)
        receipt = {"automatic_mode": "disabled", "restore_acknowledged": False}
        try:
            observed = json.loads((FOLDER / "state.json").read_text())
            if observed.get("pid") == pid and observed.get("status") == "stopped":
                receipt["restore_acknowledged"] = observed.get("restore_acknowledged") is True
                receipt["restore_skipped_for_sleep"] = observed.get("restore_skipped_for_sleep") is True
        except (OSError, ValueError, AttributeError):
            pass
        receipt["note"] = "1500 RPM restoration acknowledged." if receipt["restore_acknowledged"] else "Automatic mode stopped; fan setting is unconfirmed or restoration was skipped during sleep."
        print(json.dumps(receipt))
        return
    if service_pid() is not None:
        current = status()
        if current.get("status") in {"running", "sleeping", "degraded"}:
            print(json.dumps(current, indent=2))
            return
        raise RuntimeError("Controller is not responding. Turn automatic mode off, then on to restart it.")
    # Preflight: actual named chip readings are mandatory, never guessed temperatures.
    result = command(str(SOURCE_BINARY), "sensors")
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    rows = json.loads(result.stdout)["sensors"]
    if not any(row["kind"] in {"cpu", "gpu", "soc_die"} for row in rows):
        raise RuntimeError("No identified Mac chip-temperature sensors.")
    # Clear an existing unloaded/failed registration before replacing the binary.
    previous_pid = service_pid()
    command("launchctl", "bootout", SERVICE)
    wait_for_exit(previous_pid)
    FOLDER.mkdir(parents=True, exist_ok=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    atomic_copy(SOURCE_BINARY, INSTALLED_BINARY)
    settings = {
        "Label": LABEL,
        "ProgramArguments": [str(INSTALLED_BINARY), "auto-run"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "ProcessType": "Background",
        "StandardOutPath": str(FOLDER / "automatic.log"),
        "StandardErrorPath": str(FOLDER / "automatic-error.log"),
    }
    atomic_bytes(plistlib.dumps(settings), PLIST)
    result = command("launchctl", "bootstrap", DOMAIN, str(PLIST))
    if result.returncode:
        PLIST.unlink(missing_ok=True)
        raise RuntimeError(result.stderr.strip() or "Could not enable automatic mode.")
    # Wait for the controller's own successful device/sensor receipt, with a deadline.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        current = status()
        if current.get("status") == "running":
            print(json.dumps(current, indent=2))
            return
        if current.get("status") == "degraded":
            break
        time.sleep(0.1)  # bounded status observation; elapsed time is not success
    failed_pid = service_pid()
    command("launchctl", "bootout", SERVICE)
    wait_for_exit(failed_pid)
    PLIST.unlink(missing_ok=True)
    raise RuntimeError("Automatic mode did not report a successful sensor/device tick; service stopped. Check automatic-error.log.")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["status"]:
            main()
        else:
            with management_lock():
                FOLDER.mkdir(parents=True, exist_ok=True)
                main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        sys.exit(1)
