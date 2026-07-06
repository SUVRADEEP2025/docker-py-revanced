#!/usr/bin/env python3
"""Record per-build APK filenames into manifest entries (one entry per built APK).

Used inside the build-apps matrix job: after a successful build, run this with
APP_NAME, SOURCE, ARCH, APK_PATH set so we can write a tiny per-build JSON that
the release job will merge into the final manifest.json.

Output file: ./build_records/<app>__<source>__<arch>.json
Content:    {"key": "app|source|arch", "apk": "<filename>"}
"""

import os
import sys
import json
from pathlib import Path

REC_DIR = Path("build_records")

# Known architecture tokens that may appear in the APK filename
KNOWN_ARCHES = ("arm64-v8a", "armeabi-v7a", "x86_64", "x86", "universal")


def detect_arch_from_filename(apk_name: str, default: str = "universal") -> str:
    """APK files are named like {app}-{arch}-{name}-v{version}.apk.
    Try to detect the arch token from the filename."""
    if not apk_name:
        return default
    base = apk_name.lower()

    # Check for specific arch tokens in the filename
    # Order matters: check more specific ones first
    if "arm64-v8a" in base:
        return "arm64-v8a"
    if "armeabi-v7a" in base:
        return "armeabi-v7a"
    if "x86_64" in base:
        return "x86_64"
    if "x86" in base:
        return "x86"
    if "universal" in base:
        return "universal"

    return default


def main() -> int:
    app = os.environ.get("APP_NAME", "").strip()
    src = os.environ.get("SOURCE", "").strip()
    apk_path = os.environ.get("APK_PATH", "").strip()
    arch_env = os.environ.get("ARCH", "").strip()

    if not app or not src:
        print("APP_NAME / SOURCE missing; skipping manifest record")
        return 0

    apk_name = Path(apk_path).name if apk_path else ""

    # Prefer explicit ARCH env, otherwise detect from filename, fallback universal
    arch = arch_env or detect_arch_from_filename(apk_name) or "universal"

    REC_DIR.mkdir(parents=True, exist_ok=True)
    record = {
        "key": f"{app}|{src}|{arch}",
        "apk": apk_name,
        "app_name": app,
        "source": src,
        "arch": arch,
    }

    safe = f"{app}__{src}__{arch}".replace("/", "_")
    fp = REC_DIR / f"{safe}.json"
    with fp.open("w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
    print(f"Recorded build: {fp} -> {record}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
