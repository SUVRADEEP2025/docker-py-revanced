#!/usr/bin/env python3
"""Merge per-build records into the final manifest.json before uploading.

Inputs:
  - new_manifest.json      (planning-time manifest, has all entries with old apk
                            filenames as fallback for carry-overs)
  - build_records/*.json   (one record per built APK, written by record_build.py)

Output:
  - manifest.json          (final manifest to attach to the release)
"""

import json
import sys
from pathlib import Path


def main() -> int:
    new_manifest_path = Path("new_manifest.json")
    if not new_manifest_path.exists():
        print("No new_manifest.json found; nothing to merge")
        return 0

    with new_manifest_path.open("r", encoding="utf-8") as f:
        manifest = json.load(f)

    entries = manifest.setdefault("entries", {})

    rec_dir = Path("build_records")
    if rec_dir.exists():
        for rec_file in sorted(rec_dir.rglob("*.json")):
            try:
                with rec_file.open("r", encoding="utf-8") as f:
                    rec = json.load(f)
            except Exception as e:
                print(f"  skip bad record {rec_file}: {e}")
                continue
            key = rec.get("key")
            apk = rec.get("apk", "")
            if not key:
                continue
            entry = entries.get(key)
            if not entry:
                # Record exists but planning didn't list this combo; create it.
                entry = {
                    "app_name": rec.get("app_name", ""),
                    "source": rec.get("source", ""),
                    "arch": rec.get("arch", "universal"),
                    "config_version": "",
                    "source_sig": "",
                    "apk": "",
                }
                entries[key] = entry
            if apk:
                entry["apk"] = apk
            print(f"  merged {key} -> apk={apk!r}")

    with open("manifest.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    print(f"Wrote manifest.json with {len(entries)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
