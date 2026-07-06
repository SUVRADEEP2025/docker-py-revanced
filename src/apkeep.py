import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REQUIRED_CONFIG_KEYS = ["package"]


def _validate_config(config: dict, context: str = "") -> bool:
    """Validate that config has required keys."""
    missing = [k for k in REQUIRED_CONFIG_KEYS if k not in config]
    if missing:
        logging.error(f"Missing required config keys {missing} for {context}")
        return False
    return True


def _find_apkeep() -> str | None:
    """Find the apkeep binary."""
    return shutil.which("apkeep")


def _apkeep_download(
    package: str,
    output_dir: Path,
    source: str = "apk-pure",
    version: str | None = None,
    email: str | None = None,
    aas_token: str | None = None,
) -> Path | None:
    """Run apkeep to download an APK and return the downloaded file path."""
    apkeep_bin = _find_apkeep()
    if not apkeep_bin:
        raise RuntimeError("apkeep not found in PATH")

    cmd = [apkeep_bin, "-a", package, "-d", source]

    if source == "google-play":
        if not email or not aas_token:
            raise ValueError(
                "Google Play source requires APKEEP_EMAIL and APKEEP_AAS_TOKEN"
            )
        cmd.extend(["-e", email, "-t", aas_token])

    if version and version.lower() != "latest":
        cmd[2] = f"{package}@{version}"

    cmd.append(str(output_dir))

    logging.info(f"Running: {' '.join(cmd[:6])}...")

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

    if result.returncode != 0:
        logging.error(f"apkeep failed (exit {result.returncode}): {result.stderr}")
        return None

    # Find the downloaded file
    apk_files = list(output_dir.glob("*.apk"))
    if not apk_files:
        logging.error("apkeep completed but no APK found in output")
        return None

    # Return the most recently modified APK
    return max(apk_files, key=lambda f: f.stat().st_mtime)


def get_latest_version(app_name: str, config: dict) -> str | None:
    """Get the latest version using apkeep -l (list versions)."""
    if not _validate_config(config, app_name):
        return None

    apkeep_bin = _find_apkeep()
    if not apkeep_bin:
        logging.error("apkeep not found in PATH")
        return None

    package = config["package"]
    source = config.get("apkeep_source", "apk-pure")

    cmd = [apkeep_bin, "-l", "-a", package, "-d", source]

    if source == "google-play":
        email = os.getenv("APKEEP_EMAIL")
        aas_token = os.getenv("APKEEP_AAS_TOKEN")
        if not email or not aas_token:
            logging.error(
                "Google Play source requires APKEEP_EMAIL and APKEEP_AAS_TOKEN"
            )
            return None
        cmd.extend(["-e", email, "-t", aas_token])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            logging.error(f"apkeep list failed: {result.stderr}")
            return None

        # Parse output - versions are listed one per line
        versions = [
            line.strip() for line in result.stdout.strip().splitlines() if line.strip()
        ]
        if versions:
            return versions[0]  # Most recent version first
    except Exception as e:
        logging.error(f"Failed to get latest version via apkeep for {app_name}: {e}")

    return None


def get_download_link(version: str, app_name: str, config: dict) -> Path | None:
    """Download APK using apkeep and return the local file path.

    Unlike other source modules that return a URL, this returns a Path
    because apkeep downloads directly.
    """
    if not _validate_config(config, app_name):
        return None

    package = config["package"]
    source = config.get("apkeep_source", "apk-pure")
    email = os.getenv("APKEEP_EMAIL")
    aas_token = os.getenv("APKEEP_AAS_TOKEN")

    with tempfile.TemporaryDirectory(prefix="apkeep_") as tmp_dir:
        try:
            result = _apkeep_download(
                package=package,
                output_dir=Path(tmp_dir),
                source=source,
                version=version if version and version.lower() != "latest" else None,
                email=email,
                aas_token=aas_token,
            )
            if result:
                # Move to current directory with a clean name
                dest = Path(f"{app_name}-apkeep-{result.name}")
                shutil.move(str(result), str(dest))
                logging.info(f"Downloaded via apkeep: {dest}")
                return dest
        except Exception as e:
            logging.error(f"apkeep download failed for {app_name} v{version}: {e}")

    return None
