import base64
import logging

from src import session

BASE_URL = "https://ws75.aptoide.com/api/7/"


def get_latest_version(app_name: str, config: dict) -> str | None:
    package = config["package"]
    arch = config.get("arch", "universal")
    q = _get_q_param(arch)
    url = f"{BASE_URL}apps/search?query={package}&limit=1&trusted=true{q}"
    try:
        response = session.get(url)
        response.raise_for_status()
        res = response.json()
        if res.get("datalist", {}).get("list"):
            return res["datalist"]["list"][0]["file"]["vername"]
    except Exception as e:
        logging.error(f"Failed to get latest version from Aptoide for {package}: {e}")
    return None


def get_download_link(version: str, app_name: str, config: dict) -> str | None:
    package = config["package"]
    arch = config.get("arch", "universal")
    q = _get_q_param(arch)

    try:
        if version.lower() == "latest":
            url = f"{BASE_URL}apps/search?query={package}&limit=1&trusted=true{q}"
            response = session.get(url)
            response.raise_for_status()
            res = response.json()
            apps = res.get("datalist", {}).get("list", [])
            if not apps:
                return None
            return apps[0]["file"]["path"]

        # Find vercode for specific version
        url_versions = f"{BASE_URL}listAppVersions?package_name={package}&limit=50{q}"
        response = session.get(url_versions)
        response.raise_for_status()
        res_v = response.json()
        vercode = None
        for app in res_v.get("datalist", {}).get("list", []):
            if app["file"]["vername"] == version:
                vercode = app["file"]["vercode"]
                break
        if not vercode:
            logging.error(f"Version {version} not found for {package}")
            return None

        # Get meta with download path
        url_meta = f"{BASE_URL}getAppMeta?package_name={package}&vercode={vercode}{q}"
        response = session.get(url_meta)
        response.raise_for_status()
        res_meta = response.json()
        return res_meta["data"]["file"]["path"]
    except Exception as e:
        logging.error(
            f"Failed to get download link from Aptoide for {package} v{version}: {e}"
        )
        return None


def _get_q_param(arch: str) -> str:
    if arch == "universal":
        return ""
    cpu_map = {
        "arm64-v8a": "arm64-v8a,armeabi-v7a,armeabi",
        "armeabi-v7a": "armeabi-v7a,armeabi",
        # Add others as needed
    }
    cpu = cpu_map.get(arch, "")
    if cpu:
        q_str = f"myCPU={cpu}&leanback=0"
        return f"&q={base64.b64encode(q_str.encode('utf-8')).decode('utf-8')}"
    return ""
