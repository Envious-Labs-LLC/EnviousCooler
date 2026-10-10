#!/usr/bin/env python3
"""Rebuild the macOS icon from the approved artwork, using macOS tools only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def main():
    with tempfile.TemporaryDirectory(prefix="enviouscooler-icons-") as directory:
        iconset = Path(directory) / "AppIcon.iconset"
        iconset.mkdir()
        for points in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                pixels = points * scale
                suffix = "@2x" if scale == 2 else ""
                output = iconset / f"icon_{points}x{points}{suffix}.png"
                subprocess.run(["sips", "-z", str(pixels), str(pixels),
                                str(ROOT / "assets/AppIcon.png"), "--out", str(output)],
                               check=True, capture_output=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset),
                        "-o", str(ROOT / "assets/AppIcon.icns")], check=True)


if __name__ == "__main__":
    main()
