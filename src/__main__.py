import json
import logging
import re
import shutil
import subprocess
from os import getenv
from pathlib import Path
from sys import exit

from src import downloader, r2, release, utils

PATCHES_DIR = Path("patches")
KEYSTORE_PATH = "keystore/public.jks"
KEYSTORE_PASS = "pass:public"
KEY_ALIAS = "public"
MIN_SDK_VERSION = "21"


def _check_prerequisites() -> None:
    """Verify required tools are available before building."""
    required_tools = ["java", "zip"]
    missing = []
    for tool in required_tools:
        if not shutil.which(tool):
            missing.append(tool)

    if not utils.find_apksigner():
        missing.append("apksigner (Android SDK Build-Tools)")

    if missing:
        logging.error(f"Missing required tools: {', '.join(missing)}")
        logging.error("Please install the missing tools and try again.")
        exit(1)


def _should_retry_with_older_version(output: str | None) -> bool:
    """Detect common patterns that indicate the chosen app version is not
    actually compatible with the selected patches (fingerprint mismatch, etc.)."""
    if not output:
        return False
    t = output.lower()
    return (
        "failed to match the fingerprint" in t
        or "patch.patchexception" in t
        or ("fingerprint" in t and "failed" in t)
        or "patching aborted" in t
    )


def _find_tool_files(
    download_files: list[Path], source_type: str, source: str
) -> tuple[Path | None, Path | None]:
    """Find CLI and patches files from downloaded artifacts."""
    if source_type == "morphe":
        cli = utils.find_file(
            download_files, contains="morphe-cli", suffix=".jar", exclude=["dev"]
        )
        if not cli:
            cli = utils.find_file(download_files, contains="morphe", suffix=".jar")

        patches = utils.find_file(download_files, contains="patches", suffix=".mpp")
        if not patches:
            patches = utils.find_file(download_files, suffix=".mpp")
    else:
        cli = utils.find_file(download_files, contains="revanced-cli", suffix=".jar")
        patches = utils.find_file(download_files, contains="patches", suffix=".rvp")
        if not patches:
            patches = utils.find_file(download_files, contains="patches", suffix=".jar")

    if not cli:
        logging.error(f"CLI not found for source: {source}")
        logging.error(f"Available files: {[f.name for f in download_files]}")
    if not patches:
        logging.error(f"Patches not found for source: {source}")
        logging.error(f"Available files: {[f.name for f in download_files]}")

    return cli, patches


def _merge_to_apk(input_apk: Path, app_name: str) -> Path | None:
    """Merge non-APK bundles into .apk using APKEditor. Returns None on failure."""
    logging.warning("Input file is not .apk, using APKEditor to merge")
    try:
        apk_editor = downloader.download_apkeditor()
    except Exception as e:
        logging.error(f"Failed to download APKEditor: {e}")
        return None

    merged_apk = input_apk.with_suffix(".apk")

    try:
        utils.run_process(
            [
                "java",
                "-jar",
                apk_editor,
                "m",
                "-i",
                str(input_apk),
                "-o",
                str(merged_apk),
            ],
            silent=True,
        )
    except subprocess.CalledProcessError as e:
        logging.error(f"APKEditor merge failed: {e}")
        return None

    input_apk.unlink(missing_ok=True)

    if not merged_apk.exists():
        logging.error("Merged APK file not found")
        return None

    # Clean up filename: remove build number like (1575420) and -1575420
    clean_name = re.sub(r"\(\d+\)", "", merged_apk.name)
    clean_name = re.sub(r"-\d+_", "_", clean_name)
    if clean_name != merged_apk.name:
        clean_apk = merged_apk.with_name(clean_name)
        merged_apk.rename(clean_apk)
        merged_apk = clean_apk

    logging.info(f"Merged APK file generated: {merged_apk}")
    return merged_apk


def _strip_arch_libs(input_apk: Path, arch: str) -> None:
    """Remove native libraries for other architectures."""
    if arch == "arm64-v8a":
        libs_to_remove = ["lib/x86/*", "lib/x86_64/*", "lib/armeabi-v7a/*"]
    elif arch == "armeabi-v7a":
        libs_to_remove = ["lib/x86/*", "lib/x86_64/*", "lib/arm64-v8a/*"]
    else:
        libs_to_remove = ["lib/x86/*", "lib/x86_64/*"]

    logging.info(f"Processing APK for {arch} architecture...")
    utils.run_process(
        ["zip", "--delete", str(input_apk), *libs_to_remove],
        silent=True,
        check=False,
    )


def _repair_apk(input_apk: Path, app_name: str, version: str) -> Path:
    """Attempt to repair corrupted APK using zip -FF."""
    logging.info("Checking APK for corruption...")
    try:
        fixed_apk = Path(f"{app_name}-fixed-v{version}.apk")
        subprocess.run(
            ["zip", "-FF", str(input_apk), "--out", str(fixed_apk)],
            check=False,
            capture_output=True,
        )

        if fixed_apk.exists() and fixed_apk.stat().st_size > 0:
            input_apk.unlink(missing_ok=True)
            fixed_apk.rename(input_apk)
            logging.info("APK fixed successfully")
    except Exception as e:
        logging.warning(f"Could not fix APK: {e}")

    return input_apk


def _run_patch(
    cli: Path,
    patches: Path,
    input_apk: Path,
    output_apk: Path,
    is_morphe: bool,
    exclude_patches: list[str],
    include_patches: list[str],
) -> None:
    """Run the patching tool (Morphe or ReVanced)."""
    if is_morphe:
        logging.info("Using Morphe patching system...")
        morphe_cmd = [
            "java",
            "-jar",
            str(cli),
            "patch",
            "--patches",
            str(patches),
            "--out",
            str(output_apk),
            str(input_apk),
            *exclude_patches,
            *include_patches,
        ]
        utils.run_process(morphe_cmd, capture=True, stream=True)
    else:
        logging.info("Using ReVanced patching system...")
        if utils.is_newer_revanced_cli(Path(cli).name):
            utils.run_process(
                [
                    "java",
                    "-jar",
                    str(cli),
                    "patch",
                    "-p",
                    str(patches),
                    "-b",
                    "--out",
                    str(output_apk),
                    str(input_apk),
                    *exclude_patches,
                    *include_patches,
                ],
                capture=True,
                stream=True,
            )
        else:
            utils.run_process(
                [
                    "java",
                    "-jar",
                    str(cli),
                    "patch",
                    "--patches",
                    str(patches),
                    "--out",
                    str(output_apk),
                    str(input_apk),
                    *exclude_patches,
                    *include_patches,
                ],
                capture=True,
                stream=True,
            )


def _sign_apk(output_apk: Path, signed_apk: Path) -> bool:
    """Sign APK using apksigner. Returns True on success."""
    apksigner = utils.find_apksigner()
    if not apksigner:
        logging.error("apksigner not found")
        return False

    try:
        utils.run_process(
            [
                str(apksigner),
                "sign",
                "--verbose",
                "--ks",
                KEYSTORE_PATH,
                "--ks-pass",
                KEYSTORE_PASS,
                "--key-pass",
                KEYSTORE_PASS,
                "--ks-key-alias",
                KEY_ALIAS,
                "--in",
                str(output_apk),
                "--out",
                str(signed_apk),
            ],
            capture=True,
            stream=True,
        )
        return True
    except Exception as e:
        logging.warning(f"Standard signing failed: {e}")
        logging.info("Trying alternative signing method...")

    try:
        utils.run_process(
            [
                str(apksigner),
                "sign",
                "--verbose",
                "--min-sdk-version",
                MIN_SDK_VERSION,
                "--ks",
                KEYSTORE_PATH,
                "--ks-pass",
                KEYSTORE_PASS,
                "--key-pass",
                KEYSTORE_PASS,
                "--ks-key-alias",
                KEY_ALIAS,
                "--in",
                str(output_apk),
                "--out",
                str(signed_apk),
            ],
            capture=True,
            stream=True,
        )
        return True
    except Exception as e:
        logging.error(f"Alternative signing also failed: {e}")
        return False


def _load_patch_rules(app_name: str, source: str) -> tuple[list[str], list[str]]:
    """Load include/exclude patch rules from text file."""
    exclude_patches = []
    include_patches = []

    patches_path = PATCHES_DIR / f"{app_name}-{source}.txt"
    if patches_path.exists():
        with patches_path.open("r") as patches_file:
            for line in patches_file:
                line = line.strip()
                if line.startswith("-"):
                    exclude_patches.extend(["-d", line[1:].strip()])
                elif line.startswith("+"):
                    include_patches.extend(["-e", line[1:].strip()])

    return exclude_patches, include_patches


def run_build(app_name: str, source: str, arch: str = "universal") -> str | None:
    """Build APK for specific architecture."""
    download_files, name = downloader.download_required(source)

    logging.info(f"Downloaded {len(download_files)} files for {source}:")
    for file in download_files:
        logging.info(f"  - {file.name} ({file.stat().st_size} bytes)")

    # Detect source type
    source_type = utils.detect_source_type(download_files=download_files, source=source)
    is_morphe = source_type == "morphe"
    logging.info(f"Detected: {'Morphe' if is_morphe else 'ReVanced'} source type")

    # Find tools
    cli, patches = _find_tool_files(download_files, source_type, source)
    if not cli or not patches:
        return None

    logging.info(f"Using CLI: {cli.name}")
    logging.info(f"Using patches: {patches.name}")

    # Download APK
    download_methods = [
        downloader.download_apkmirror,
        downloader.download_apkpure,
        downloader.download_uptodown,
        downloader.download_aptoide,
    ]

    # Add apkeep if available and enabled
    if shutil.which("apkeep"):
        download_methods.append(downloader.download_apkeep)

    input_apk = None
    version = None
    candidates: list[str] = []
    used_method = None
    for method in download_methods:
        method_name = method.__name__.replace("download_", "")
        try:
            input_apk, version, candidates = method(
                app_name, str(cli), str(patches), arch
            )
            if input_apk:
                used_method = method
                logging.info(
                    f"Downloaded {app_name} v{version} from {method_name}"
                )
                break
            else:
                logging.debug(f"No APK available from {method_name} for {app_name}")
        except Exception as e:
            logging.warning(f"{method_name} failed for {app_name}: {e}")

    if input_apk is None or not used_method or not version:
        logging.error(f"Failed to download APK for {app_name}")
        logging.error("All download sources failed. Skipping this app.")
        return None

    # Build version list for retry
    versions_to_try: list[str] = [version]
    if candidates and version in candidates:
        versions_to_try += [v for v in candidates if v != version]

    # Load patch rules
    exclude_patches, include_patches = _load_patch_rules(app_name, source)

    for attempt_idx, ver in enumerate(versions_to_try):
        if attempt_idx > 0:
            logging.warning(
                f"Retrying {app_name}/{source}/{arch} with version {ver} "
                f"(attempt {attempt_idx + 1}/{len(versions_to_try)})..."
            )
            try:
                input_apk.unlink(missing_ok=True)
            except Exception:
                pass

            try:
                input_apk, version, _ = used_method(
                    app_name, str(cli), str(patches), arch, override_version=ver
                )
            except Exception as e:
                logging.warning(f"Download failed for {app_name} v{ver}: {e}")
                continue

            if input_apk is None:
                logging.warning(f"No APK downloaded for {app_name} v{ver}")
                continue
            version = ver

        # Merge non-APK bundles
        if input_apk.suffix != ".apk":
            merged = _merge_to_apk(input_apk, app_name)
            if merged is None:
                logging.warning(f"Merge failed for {app_name} v{version}, skipping")
                continue
            input_apk = merged

        # Strip architecture-specific libs
        try:
            _strip_arch_libs(input_apk, arch)
        except Exception as e:
            logging.warning(f"Arch strip failed for {app_name}: {e}")

        # Repair corrupted APK
        input_apk = _repair_apk(input_apk, app_name, version)

        # Patch APK
        output_apk = Path(f"{app_name}-{arch}-patch-v{version}.apk")

        try:
            _run_patch(
                cli,
                patches,
                input_apk,
                output_apk,
                is_morphe,
                exclude_patches,
                include_patches,
            )
        except subprocess.CalledProcessError as e:
            input_apk.unlink(missing_ok=True)
            output_apk.unlink(missing_ok=True)

            if attempt_idx < len(
                versions_to_try
            ) - 1 and _should_retry_with_older_version(getattr(e, "output", None)):
                continue
            raise

        # Sign APK
        input_apk.unlink(missing_ok=True)
        signed_apk = Path(f"{app_name}-{arch}-{name}-v{version}.apk")

        if not _sign_apk(output_apk, signed_apk):
            logging.error(f"Signing failed for {app_name} v{version}")
            output_apk.unlink(missing_ok=True)
            continue

        output_apk.unlink(missing_ok=True)
        logging.info(f"APK built: {signed_apk.name}")
        return str(signed_apk)

    return None


def main():
    app_name = getenv("APP_NAME")
    source = getenv("SOURCE")

    if not app_name or not source:
        logging.error("APP_NAME and SOURCE environment variables must be set")
        exit(1)

    _check_prerequisites()

    arch_config_path = Path("arch-config.json")
    if arch_config_path.exists():
        try:
            with open(arch_config_path) as f:
                arch_config = json.load(f)
        except json.JSONDecodeError as e:
            logging.error(f"Failed to parse arch-config.json: {e}")
            exit(1)

        arches = ["universal"]
        for config in arch_config:
            if config["app_name"] == app_name and config["source"] == source:
                arches = config["arches"]
                break

        built_apks = []
        for arch in arches:
            logging.info(f"Building {app_name} for {arch} architecture...")
            try:
                apk_path = run_build(app_name, source, arch)
                if apk_path:
                    built_apks.append(apk_path)
                    logging.info(f"Built {arch} version: {Path(apk_path).name}")
            except Exception as e:
                logging.error(f"Build failed for {app_name}/{arch}: {e}")

        logging.info(f"Built {len(built_apks)} APK(s) for {app_name}:")
        for apk in built_apks:
            logging.info(f"  {Path(apk).name}")

        if not built_apks:
            logging.error(f"All architectures failed for {app_name}")

    else:
        logging.warning("arch-config.json not found, building universal only")
        apk_path = run_build(app_name, source, "universal")
        if apk_path:
            logging.info(f"Final APK path: {apk_path}")


if __name__ == "__main__":
    main()
