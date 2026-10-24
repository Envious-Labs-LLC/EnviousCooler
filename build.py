#!/usr/bin/env python3
"""Build production tools; opt in separately to low-speed diagnostics."""
from pathlib import Path
import subprocess
import sys
import platform

ROOT = Path(__file__).resolve().parent
CONTROL = ["Core.swift", "Shared.swift", "Thermals.swift", "Hardware.swift", "Automatic.swift", "main.swift"]


def compile_tool(files, name, extra=()):
    target = f"{platform.machine()}-apple-macos14.0"
    subprocess.run(["swiftc", "-O", "-target", target, *extra, *(str(ROOT / file) for file in files), "-o", str(ROOT / name)], check=True)


def main():
    if sys.argv[1:] not in ([], ["--diagnostics"]):
        raise RuntimeError("Use build.py [--diagnostics]")
    compile_tool(CONTROL, "enviouscooler")
    compile_tool(["Core.swift", "Shared.swift", "Thermals.swift", "BrandIcon.swift", "MenuBar.swift"], "enviouscooler-menu")
    compile_tool(["Core.swift", "Shared.swift", "Thermals.swift", "Hardware.swift", "Automatic.swift", "Tests/main.swift"], "native-checks")
    subprocess.run([str(ROOT / "native-checks")], check=True)
    subprocess.run([sys.executable, str(ROOT / "check_controls.py")], check=True)
    subprocess.run([sys.executable, str(ROOT / "check_service.py")], check=True)
    subprocess.run([sys.executable, str(ROOT / "check_installer.py")], check=True)
    if sys.argv[1:] == ["--diagnostics"]:
        compile_tool(CONTROL, "enviouscooler-diagnostic", ["-D", "DIAGNOSTICS"])
        compile_tool(["diagnostics/InspectInput.swift"], "inspect-input")


if __name__ == "__main__":
    main()
