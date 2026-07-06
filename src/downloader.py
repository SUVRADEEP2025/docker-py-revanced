import json
import logging
import tempfile
import time
from pathlib import Path

from src import apkmirror, apkpure, aptoide, session, uptodown, utils

DOWNLOAD_TIMEOUT = 60
MAX_RETRIES = 3
RETRY_BACKOFF_BASE = 2

PLATFORM_MODULES = {
    "apkmirror": apkmirror,
    "apkpure": apkpure,
    "uptodown": uptodown,
    "aptoide": aptoide,
}


def download_resource(
    url: str, name: str | None = None, timeout: int = DOWNLOAD_TIMEOUT
) -> Path:
    """Download a resource with retry logic and timeout."""
    last_error = None

    for attempt in range(MAX_RETRIES):
        try:
            res = session.get(url, stream=True, timeout=timeout)
            res.raise_for_status()
            final_url = res.url

            if not name:
                name = utils.extract_filename(res, fallback_url=final_url)

            filepath = Path(name)
            total_size = int(res.headers.get("content-length", 0))
            downloaded_size = 0

            # Write to temp file first, then rename on success
            with tempfile.NamedTemporaryFile(delete=False, dir=".") as tmp:
                tmp_path = Path(tmp.name)
                try:
                    for chunk in res.iter_content(chunk_size=8192):
                        if chunk:
                            tmp.write(chunk)
                            downloaded_size += len(chunk)
                except Exception:
                    tmp_path.unlink(missing_ok=True)
                    raise

            # Verify non-empty download
            if downloaded_size == 0:
                tmp_path.unlink(missing_ok=True)
                raise ValueError(f"Downloaded empty file from {url}")

            # Rename to final path (overwrite if exists)
            filepath.unlink(missing_ok=True)
            tmp_path.rename(filepath)

            logging.info(
                f'URL: {final_url} [{downloaded_size}/{total_size}] -> "{filepath}"'
            )
            return filepath

        except Exception as e:
            last_error = e
            if attempt < MAX_RETRIES - 1:
                wait_time = RETRY_BACKOFF_BASE ** (attempt + 1)
                logging.warning(
                    f"Download attempt {attempt + 1} failed: {e}. Retrying in {wait_time}s..."
                )
                time.sleep(wait_time)

    raise RuntimeError(
        f"Failed to download {url} after {MAX_RETRIES} attempts: {last_error}"
    )


def download_required(source: str) -> tuple[list[Path], str]:
    source_path = Path("sources") / f"{source}.json"
    with source_path.open() as json_file:
        repos_info = json.load(json_file)

    if isinstance(repos_info, dict) and "bundle_url" in repos_info:
        return download_from_bundle(repos_info)

    name = repos_info[0]["name"]
    downloaded_files = []

    for repo_info in repos_info[1:]:
        release = utils.detect_release(repo_info)
        entry_name = (
            repo_info.get("repo")
            or repo_info.get("project")
            or repo_info.get("name")
            or ""
        ).lower()

        for asset in release["assets"]:
            asset_name = asset["name"]
            asset_url = asset["browser_download_url"]
            if asset_name.endswith(".asc"):
                continue

            if "morphe-patches" in entry_name or "morphe-cli" in entry_name:
                if asset_name.endswith(".mpp") or (
                    "morphe-cli" in asset_name and asset_name.endswith(".jar")
                ):
                    downloaded_files.append(download_resource(asset_url))
            else:
                downloaded_files.append(download_resource(asset_url))

    return downloaded_files, name


def download_from_bundle(bundle_info: dict) -> tuple[list[Path], str]:
    """Download resources from a bundle URL."""
    bundle_url = bundle_info["bundle_url"]
    name = bundle_info.get("name", "bundle-patches")

    logging.info(f"Downloading bundle from {bundle_url}")

    with session.get(bundle_url, timeout=DOWNLOAD_TIMEOUT) as res:
        res.raise_for_status()
        bundle_data = res.json()

    downloaded_files = []

    if "patches" in bundle_data:
        patches = bundle_data.get("patches", [])
        integrations = bundle_data.get("integrations", [])

        for patch in patches:
            if "url" in patch:
                filepath = download_resource(patch["url"])
                downloaded_files.append(filepath)
                logging.info(f"Downloaded patch: {patch.get('name', 'unknown')}")

        for integration in integrations:
            if "url" in integration:
                filepath = download_resource(integration["url"])
                downloaded_files.append(filepath)
                logging.info(
                    f"Downloaded integration: {integration.get('name', 'unknown')}"
                )

    try:
        cli_release = utils.detect_github_release("revanced", "revanced-cli", "latest")
        for asset in cli_release["assets"]:
            if asset["name"].endswith(".asc"):
                continue
            if asset["name"].endswith(".jar") and "cli" in asset["name"].lower():
                filepath = download_resource(asset["browser_download_url"])
                downloaded_files.append(filepath)
                logging.info("Downloaded ReVanced CLI")
                break
    except Exception as e:
        logging.warning(f"Could not download ReVanced CLI: {e}")

    return downloaded_files, name


def download_platform(
    app_name: str,
    platform: str,
    cli: str,
    patches: str,
    arch: str | None = None,
    override_version: str | None = None,
) -> tuple[Path | None, str | None, list[str]]:
    """Download APK from a specific platform with fallback."""
    try:
        config_path = Path("apps") / platform / f"{app_name}.json"
        if not config_path.exists():
            raise FileNotFoundError(f"Config file not found: {config_path}")

        with config_path.open() as json_file:
            config = json.load(json_file)

        if arch:
            config["arch"] = arch

        platform_module = PLATFORM_MODULES.get(platform)
        if not platform_module:
            raise ValueError(f"Unknown platform: {platform}")

        pinned = (config.get("version") or "").strip()
        if override_version:
            candidates = [override_version]
        elif pinned:
            candidates = [pinned]
        else:
            candidates = utils.get_supported_versions(config["package"], cli, patches)
            if not candidates:
                latest = platform_module.get_latest_version(app_name, config)
                candidates = [latest] if latest else []

        last_error: Exception | None = None
        for version in candidates:
            if not version:
                continue
            try:
                download_link = platform_module.get_download_link(
                    version, app_name, config
                )
                if not download_link:
                    last_error = ValueError(
                        f"No download link found for {app_name} version {version}"
                    )
                    logging.warning(
                        f"No download link for {app_name} v{version} on {platform}"
                    )
                    continue
                filepath = download_resource(download_link)
                return filepath, version, candidates
            except Exception as e:
                last_error = e
                logging.warning(
                    f"Failed to download {app_name} v{version} from {platform}: {e}"
                )
                continue

        raise last_error or ValueError(
            f"No downloadable versions found for {app_name} on {platform}"
        )

    except FileNotFoundError:
        logging.debug(f"Config not found for {app_name} on {platform}, skipping")
        return None, None, []
    except Exception as e:
        logging.error(f"Error downloading {app_name} from {platform}: {e}")
        return None, None, []


def download_apkmirror(
    app_name: str,
    cli: str,
    patches: str,
    arch: str | None = None,
    override_version: str | None = None,
) -> tuple[Path | None, str | None, list[str]]:
    return download_platform(
        app_name, "apkmirror", cli, patches, arch, override_version
    )


def download_apkpure(
    app_name: str,
    cli: str,
    patches: str,
    arch: str | None = None,
    override_version: str | None = None,
) -> tuple[Path | None, str | None, list[str]]:
    return download_platform(app_name, "apkpure", cli, patches, arch, override_version)


def download_aptoide(
    app_name: str,
    cli: str,
    patches: str,
    arch: str | None = None,
    override_version: str | None = None,
) -> tuple[Path | None, str | None, list[str]]:
    return download_platform(app_name, "aptoide", cli, patches, arch, override_version)


def download_uptodown(
    app_name: str,
    cli: str,
    patches: str,
    arch: str | None = None,
    override_version: str | None = None,
) -> tuple[Path | None, str | None, list[str]]:
    return download_platform(app_name, "uptodown", cli, patches, arch, override_version)


def download_apkeditor() -> Path:
    """Download APKEditor with retry logic."""
    for attempt in range(MAX_RETRIES):
        try:
            release = utils.detect_github_release("REAndroid", "APKEditor", "latest")

            for asset in release["assets"]:
                if asset["name"].startswith("APKEditor") and asset["name"].endswith(
                    ".jar"
                ):
                    return download_resource(asset["browser_download_url"])

            raise RuntimeError("APKEditor .jar file not found in the latest release")
        except Exception as e:
            if attempt == MAX_RETRIES - 1:
                raise RuntimeError(
                    f"Failed to download APKEditor after {MAX_RETRIES} attempts: {e}"
                )
            wait_time = RETRY_BACKOFF_BASE ** (attempt + 1)
            logging.warning(
                f"APKEditor download attempt {attempt + 1} failed: {e}. Retrying in {wait_time}s..."
            )
            time.sleep(wait_time)
