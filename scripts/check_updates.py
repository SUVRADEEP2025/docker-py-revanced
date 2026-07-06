#!/usr/bin/env python3
import json
import os
import sys
import subprocess
import re
from datetime import datetime

# Always trigger build - we'll rely on schedule and manual triggers
print("Triggering build...")


def get_apkmirror_version(package_name):
    """
    Get latest version from APKMirror using curl (no Python dependencies)
    """
    try:
        # Using curl to fetch APKMirror data
        # Note: APKMirror doesn't have a simple API, so we'll use a different approach

        # Instead of trying to scrape APKMirror directly (which blocks bots),
        # we'll use a simpler approach: check if version is empty and update with placeholder

        print(
            f"Note: Auto-version detection for {package_name} needs manual implementation"
        )
        print("Current approach: Using incremental versioning for testing")

        # For now, return None - you'll need to implement actual API calls
        return None

    except Exception as e:
        print(f"Error fetching version for {package_name}: {e}")

    return None


def check_and_update_config(config_file):
    """
    Check and update a single config file if version is empty
    """
    try:
        with open(config_file, "r") as f:
            config = json.load(f)

        # Only update if version is empty
        if config.get("version") == "":
            package = config.get("package", "")
            if package:
                print(f"Checking latest version for {package}...")

                # Extract app name for APKMirror URL
                if "apkmirror" in config_file.lower():
                    # Try to get version from APKMirror
                    latest_version = get_apkmirror_version(package)

                    if latest_version:
                        print(f"Found latest version for {package}: {latest_version}")
                        config["version"] = latest_version

                        # Write updated config
                        with open(config_file, "w") as f:
                            json.dump(config, f, indent=2)
                        return True
                    else:
                        print(f"Could not find version for {package}")
                        # For testing, set a dummy version
                        # Remove this in production
                        # config['version'] = '18.45.43'
                        # return True

        return False

    except Exception as e:
        print(f"Error processing {config_file}: {e}")
        return False


def main():
    # First, change to repository root directory
    # Get the directory where this script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Change to parent directory (repository root)
    os.chdir(os.path.join(script_dir, ".."))

    print(f"Current working directory: {os.getcwd()}")
    print(f"Files in current directory: {os.listdir('.')}")

    # Read patch-config.json
    try:
        with open("patch-config.json", "r") as f:
            patch_config = json.load(f)
        print("Successfully loaded patch-config.json")
    except Exception as e:
        print(f"Error loading patch-config.json: {e}")
        return

    updated = False
    apps_checked = set()

    # Check each app in patch list
    for app_config in patch_config["patch_list"]:
        app_name = app_config["app_name"]

        # Skip if we already checked this app
        if app_name in apps_checked:
            continue

        apps_checked.add(app_name)

        # Check all possible app config locations
        app_dirs = ["apps/apkmirror", "apps/apkpure", "apps/uptodown"]

        for app_dir in app_dirs:
            config_file = f"{app_dir}/{app_name}.json"

            if os.path.exists(config_file):
                print(f"\nChecking {config_file}...")
                if check_and_update_config(config_file):
                    updated = True
                    print(f"✓ Updated {config_file}")
                else:
                    print(f"✓ No update needed for {config_file}")
                break  # Found the config, no need to check other dirs

    # Also check if there are any configs not in patch-config.json
    # This ensures all configs are up to date
    for app_dir in app_dirs:
        if os.path.exists(app_dir):
            for config_file in os.listdir(app_dir):
                if config_file.endswith(".json"):
                    full_path = os.path.join(app_dir, config_file)
                    app_name = config_file.replace(".json", "")
                    if app_name not in apps_checked:
                        print(f"\nChecking additional config: {full_path}...")
                        if check_and_update_config(full_path):
                            updated = True

    # Output for GitHub Actions
    if updated:
        print("\n" + "=" * 50)
        print("Updates found! Committing changes...")
        print("=" * 50)

        # Set GitHub Actions output
        if "GITHUB_OUTPUT" in os.environ:
            with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
                print("has_updates=true", file=fh)
        else:
            # For local testing
            print("has_updates=true")

        # Commit changes
        try:
            subprocess.run(
                ["git", "config", "--global", "user.name", "GitHub Actions"], check=True
            )
            subprocess.run(
                ["git", "config", "--global", "user.email", "actions@github.com"],
                check=True,
            )
            subprocess.run(["git", "add", "apps/"], check=True)
            subprocess.run(
                ["git", "commit", "-m", "chore: update app versions [skip ci]"],
                check=True,
            )
            token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
            repo_slug = os.environ.get("GITHUB_REPOSITORY")
            if token and repo_slug:
                remote = f"https://x-access-token:{token}@github.com/{repo_slug}.git"
                subprocess.run(
                    ["git", "remote", "set-url", "--push", "origin", remote], check=True
                )
            else:
                print(
                    "Skipping authenticated remote setup; git push may require manual credentials"
                )
            subprocess.run(["git", "push"], check=True)
        except Exception as e:
            print(f"Error committing changes: {e}")
    else:
        print("\n" + "=" * 50)
        print("No updates found")
        print("=" * 50)

        if "GITHUB_OUTPUT" in os.environ:
            with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
                print("has_updates=false", file=fh)
        else:
            print("has_updates=false")


if __name__ == "__main__":
    main()
