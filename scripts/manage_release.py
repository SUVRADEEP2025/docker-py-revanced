#!/usr/bin/env python3
import glob
import json
import os
from datetime import datetime


def get_app_versions():
    """Read version information from app configs"""
    versions = {}

    # Check apkmirror configs
    for config_file in glob.glob("apps/apkmirror/*.json"):
        try:
            with open(config_file, "r") as f:
                config = json.load(f)
                app_name = os.path.basename(config_file).replace(".json", "")
                versions[app_name] = {
                    "version": config.get("version", "latest"),
                    "source": "apkmirror",
                }
        except (FileNotFoundError, json.JSONDecodeError):
            pass

    # You can add apkpure and uptodown similarly

    return versions


def create_release_notes():
    """Create release notes for the release"""
    versions = get_app_versions()

    notes = "# ReVanced Patched APKs\n\n"
    notes += "## 📱 Available Apps\n\n"

    # Read patch-config to know which apps were built
    with open("patch-config.json", "r") as f:
        patch_config = json.load(f)

    for app_config in patch_config["patch_list"]:
        app_name = app_config["app_name"]
        source = app_config["source"]

        if app_name in versions:
            version_info = versions[app_name]
            notes += f"### {app_name.replace('-', ' ').title()} ({source})\n"
            notes += f"- **Version:** `{version_info['version']}`\n"
            notes += f"- **Source:** {version_info['source']}\n\n"
        else:
            notes += f"### {app_name.replace('-', ' ').title()} ({source})\n"
            notes += "- **Version:** `latest`\n\n"

    notes += "---\n\n"
    notes += "## 🔧 Build Information\n\n"
    notes += f"- **Build Date:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}\n"
    notes += "- **Auto-built:** Every 6 hours\n"
    notes += "- **Source:** Various ReVanced sources\n\n"
    notes += "## ⚠️ Disclaimer\n"
    notes += "These APKs are built automatically using the ReVanced patcher.\n"
    notes += "Use at your own risk.\n"

    return notes


if __name__ == "__main__":
    # This writes release notes to a file for the workflow to use
    release_notes = create_release_notes()

    with open("release_notes.md", "w") as f:
        f.write(release_notes)

    print("Release notes generated")
