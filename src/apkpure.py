import json
import logging

from bs4 import BeautifulSoup

from src import session

REQUIRED_CONFIG_KEYS = ["name", "package"]


def _validate_config(config: dict, context: str = "") -> bool:
    """Validate that config has required keys."""
    missing = [k for k in REQUIRED_CONFIG_KEYS if k not in config]
    if missing:
        logging.error(f"Missing required config keys {missing} for {context}")
        return False
    return True


def get_latest_version(app_name: str, config: dict) -> str | None:
    if not _validate_config(config, app_name):
        return None

    url = f"https://apkpure.net/{config['name']}/{config['package']}/versions"

    try:
        response = session.get(url)
        response.raise_for_status()

        soup = BeautifulSoup(response.content, "html.parser")
        version_info = soup.find("div", class_="ver-top-down")

        if version_info and "data-dt-version" in version_info.attrs:
            return version_info["data-dt-version"]

    except Exception as e:
        logging.error(f"Failed to fetch latest version for {app_name}: {e}")

    return None


def get_download_link(version: str, app_name: str, config: dict) -> str | None:
    if not _validate_config(config, app_name):
        return None

    url = f"https://apkpure.net/{config['name']}/{config['package']}/download/{version}"

    try:
        response = session.get(url)
        response.raise_for_status()

        soup = BeautifulSoup(response.content, "html.parser")

        download_link = soup.find("a", id="download_link")
        if download_link:
            return download_link["href"]

    except Exception as e:
        logging.error(f"Failed to fetch download link for {app_name} v{version}: {e}")

    return None
