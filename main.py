"""Entry point."""

import sys
import time
from typing import Any

from environs import Env
from loguru import logger
from threading import Lock
from src.app import APP
from src.config import RevancedConfig
from src.downloader.download import Downloader
from src.exceptions import (
    AppNotFoundError,
    BuilderError,
    PatchesJsonLoadError,
    PatchingFailedError,
)
from src.parser import Parser
from src.patches import Patches
from src.utils import (
    check_java,
    delete_old_changelog,
    load_older_updates,
    save_patch_info,
    write_changelog_to_file,
)


SLEEP_AFTER_DOWNLOAD = 10  # seconds

def get_app(config: RevancedConfig, app_name: str) -> APP:
    """Get App object."""
    env_package_name = config.env.str(f"{app_name}_PACKAGE_NAME".upper(), None)
    package_name = env_package_name or Patches.get_package_name(app_name)
    return APP(app_name=app_name, package_name=package_name, config=config)


def process_single_app(
    app_name: str,
    config: RevancedConfig,
    download_cache: dict[tuple[str, str], tuple[str, str]],
    resource_cache: dict[str, tuple[str, str]],
    download_lock: Lock,
    resource_lock: Lock,
) -> dict[str, Any]:

    """Process a single app and return its update info."""
    logger.info(f"Trying to build {app_name}")

    try:
        app = get_app(config, app_name)
        # Download patch resources
        app.download_patch_resources(config, resource_cache, None)
        logger.info("Sleeping after patch resource download")
        time.sleep(SLEEP_AFTER_DOWNLOAD)
        patcher = Patches(config, app)
        parser = Parser(patcher, config)
        app_all_patches = patcher.get_app_configs(app)
        # Download APK
        app.download_apk_for_patching(config, download_cache, None)
        logger.info("Sleeping after APK download")
        time.sleep(SLEEP_AFTER_DOWNLOAD)

        parser.include_exclude_patch(app, app_all_patches, patcher.patches_dict)
        logger.info(app)

        app_update_info = save_patch_info(app, {})
        parser.patch_app(app)

    except AppNotFoundError as e:
        logger.info(e)
        return {}
    except PatchesJsonLoadError:
        logger.exception("Patches.json not found")
        return {}
    except PatchingFailedError as e:
        logger.exception(e)
        return {}
    except BuilderError as e:
        logger.exception(f"Failed to build {app_name} because of {e}")
        return {}
    else:
        logger.info(f"Successfully completed {app_name}")
        return app_update_info


def main() -> None:
    """Entry point."""
    env = Env()
    download_lock = Lock()
    resource_lock = Lock()
    env.read_env()
    config = RevancedConfig(env)
    updates_info = {}

    Downloader.extra_downloads(config)
    logger.info("Sleeping after extra downloads")
    time.sleep(SLEEP_AFTER_DOWNLOAD)

    if not config.dry_run:
        check_java()
        delete_old_changelog()
        updates_info = load_older_updates(env)

    logger.info(f"Will Patch only {len(config.apps)} apps-:\n{config.apps}")

    download_cache: dict[tuple[str, str], tuple[str, str]] = {}
    resource_cache: dict[str, tuple[str, str]] = {}

    if config.disable_caching:
        download_cache.clear()
        resource_cache.clear()

    # Always single-threaded
    for app_name in config.apps:
    app_updates = process_single_app(
        app_name,
        config,
        download_cache,
        resource_cache,
        download_lock,
        resource_lock,
    )
    updates_info.update(app_updates)
    write_changelog_to_file(updates_info)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logger.error("Script halted because of keyboard interrupt.")
        sys.exit(1)
