"""Github Manager."""

import json
import urllib.request
from pathlib import Path
from typing import Self

from environs import Env

from src.app import APP
from src.manager.release_manager import ReleaseManager
from src.utils import app_dump_key, branch_name, updates_file, updates_file_url


class GitHubManager(ReleaseManager):
    """Release manager with GitHub."""

    def __init__(self: Self, env: Env) -> None:
        self.update_file_url = updates_file_url.format(
            github_repository=env.str("GITHUB_REPOSITORY"),
            branch_name=branch_name,
            updates_file=updates_file,
        )
        self.is_dry_run = env.bool("DRY_RUN", False)

    def get_last_version(self: Self, app: APP, resource_name: str) -> str | list[str]:
        """Get last patched version."""
        try:
            if self.is_dry_run:
                with Path(updates_file).open() as url:
                    data = json.load(url)
            else:
                with urllib.request.urlopen(self.update_file_url) as url:
                    data = json.load(url)
            if app.app_name in data and (resource := data[app.app_name].get(resource_name)):
                if isinstance(resource, list):
                    return resource
                return str(resource)
        except (urllib.error.HTTPError, FileNotFoundError):
            # Return default value if updates file doesn't exist (fresh build)
            pass
        return "0"

    def get_last_version_source(self: Self, app: APP, resource_name: str) -> str | list[str]:
        """Get last patched version."""
        try:
            if self.is_dry_run:
                with Path(updates_file).open() as url:
                    data = json.load(url)
            else:
                with urllib.request.urlopen(self.update_file_url) as url:
                    data = json.load(url)
            if app.app_name in data:
                app_dump = data[app.app_name].get(app_dump_key, {})
                if resource := app_dump.get(resource_name):
                    if isinstance(resource, list):
                        return resource
                    return str(resource)
        except (urllib.error.HTTPError, FileNotFoundError):
            # Return default value if updates file doesn't exist (fresh build)
            pass
        return "0"
