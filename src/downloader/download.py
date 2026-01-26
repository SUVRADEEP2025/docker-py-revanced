"""Downloader Class."""

import os
import subprocess
import time
from http.client import OK as HTTP_OK
from http.client import PARTIAL_CONTENT as HTTP_PARTIAL_CONTENT
from http.client import REQUESTED_RANGE_NOT_SATISFIABLE as HTTP_RANGE_NOT_SATISFIABLE
from pathlib import Path
from queue import PriorityQueue
from time import perf_counter
from typing import Any, Self

import requests
from loguru import logger
from tqdm import tqdm

from ..app import APP
from ..config import RevancedConfig
from ..exceptions import DownloadError
from ..utils import handle_request_response, implement_method, request_timeout, session


class Downloader(object):
    """Files downloader."""

    def __init__(self: Self, config: RevancedConfig) -> None:
        self._CHUNK_SIZE = 10485760
        self._QUEUE: PriorityQueue[tuple[float, str]] = PriorityQueue()
        self._QUEUE_LENGTH = 0
        self.config = config
        self.global_archs_priority: Any = None
        self.app_version: Any = None

    def _download(self: Self, url: str, file_name: str) -> None:
        if not url:
            msg = "No url provided to download"
            raise DownloadError(msg)

        file_path = self.config.temp_folder.joinpath(file_name)

        if self.config.dry_run:
            logger.debug(f"Skipping download of {file_name} from {url}. Dry running.")
            return

        logger.info(f"Trying to download {file_name} from {url}")
        self._QUEUE_LENGTH += 1
        start = perf_counter()
        headers = {}
        if self.config.personal_access_token and "github" in url:
            logger.debug("Using personal access token")
            headers["Authorization"] = f"token {self.config.personal_access_token}"

    def _download_loop(self, url: str, file_path: Path, file_name: str, headers: dict) -> None:
        max_retries = 5
        retry_count = 0

        while retry_count < max_retries:
            try:
                if self._perform_download(url, file_path, file_name, headers):
                    return
            except (requests.exceptions.RequestException, OSError) as e:
                retry_count += 1
                logger.warning(f"Error downloading {file_name}: {e}. Retry {retry_count}/{max_retries}")
                time.sleep(2)

        msg = f"Failed to download {file_name} after {max_retries} attempts"
        raise DownloadError(msg)

    def _perform_download(self, url: str, file_path: Path, file_name: str, headers: dict) -> bool:
        resume_headers = headers.copy()
        downloaded_bytes = 0
        mode = "wb"

        if file_path.exists():
            downloaded_bytes = file_path.stat().st_size
            resume_headers["Range"] = f"bytes={downloaded_bytes}-"
            mode = "ab"

        response = session.get(url, stream=True, headers=resume_headers, timeout=request_timeout)

        if response.status_code == HTTP_RANGE_NOT_SATISFIABLE:
            content_range = response.headers.get("content-range", "")
            if "/" in content_range:
                remote_size = int(content_range.split("/")[1])
                if downloaded_bytes == remote_size:
                    logger.debug(f"File {file_name} already fully downloaded.")
                    return True

            logger.warning(f"File {file_name} size mismatch. Restarting download.")
            mode = "wb"
            downloaded_bytes = 0
            response = session.get(url, stream=True, headers=headers, timeout=request_timeout)

        if response.status_code == HTTP_PARTIAL_CONTENT:
            content_range = response.headers.get("content-range", "")
            if "/" in content_range:
                total_size = int(content_range.split("/")[1])
            else:
                total_size = downloaded_bytes + int(response.headers.get("content-length", 0))
            logger.debug(f"Resuming download of {file_name} from {downloaded_bytes} bytes")

        elif response.status_code == HTTP_OK:
            total_size = int(response.headers.get("content-length", 0))
            if downloaded_bytes > 0:
                logger.debug("Server does not support resume. Restarting download.")
            mode = "wb"
            downloaded_bytes = 0

        else:
            handle_request_response(response, url)
            total_size = 0  # Should be unreachable if handle_request_response raises

        self._write_file(response, file_path, mode, total_size, downloaded_bytes)
        return True

    def _write_file(
        self,
        response: requests.Response,
        file_path: Path,
        mode: str,
        total_size: int,
        initial_bytes: int,
    ) -> None:
        with file_path.open(mode) as dl_file:
            with tqdm(
                desc=file_path.name,
                total=total_size,
                initial=initial_bytes,
                unit="iB",
                unit_scale=True,
                unit_divisor=1024,
                colour="green",
            ) as bar:
                for chunk in response.iter_content(self._CHUNK_SIZE):
                    if chunk:
                        size = dl_file.write(chunk)
                        bar.update(size)

    def extract_download_link(self: Self, page: str, app: str) -> tuple[str, str]:
        """Extract download link from web page."""
        raise NotImplementedError(implement_method)

    def specific_version(self: Self, app: "APP", version: str) -> tuple[str, str]:
        """Function to download the specified version of app..

        :param app: Name of the application
        :param version: Version of the application to download
        :return: Version of downloaded apk
        """
        raise NotImplementedError(implement_method)

    def latest_version(self: Self, app: APP, **kwargs: Any) -> tuple[str, str]:
        """Function to download the latest version of app.

        :param app: Name of the application
        :return: Version of downloaded apk
        """
        raise NotImplementedError(implement_method)

    def convert_to_apk(self: Self, file_name: str) -> str:
        """Convert apks to apk."""
        if file_name.endswith(".apk"):
            return file_name
        output_apk_file = self.replace_file_extension(file_name, ".apk")
        output_path = f"{self.config.temp_folder}/{output_apk_file}"
        Path(output_path).unlink(missing_ok=True)
        subprocess.run(
            [
                "java",
                "-jar",
                f"{self.config.temp_folder}/{self.config.apk_editor}",
                "m",
                "-i",
                f"{self.config.temp_folder}/{file_name}",
                "-o",
                output_path,
            ],
            capture_output=True,
            check=True,
        )
        logger.info("Converted zip to apk.")
        return output_apk_file

    @staticmethod
    def replace_file_extension(filename: str, new_extension: str) -> str:
        """Replace the extension of a file."""
        base_name, _ = os.path.splitext(filename)
        return base_name + new_extension

    def download(self: Self, version: str | None, app: APP, **kwargs: Any) -> tuple[str, str]:
        """Public function to download apk to patch.

        :param version: version to download
        :param app: App to download
        """
        if self.config.dry_run:
            return "", ""
        if app in self.config.existing_downloaded_apks:
            logger.debug(f"Will not download {app.app_name} -v{version} from the internet.")
            return app.app_name, f"local://{app.app_name}"
        if version and version != "latest":
            file_name, app_dl = self.specific_version(app, version)
        else:
            file_name, app_dl = self.latest_version(app, **kwargs)
        return self.convert_to_apk(file_name), app_dl

    def direct_download(self: Self, dl: str, file_name: str) -> None:
        """Download from DL."""
        self._download(dl, file_name)

    @staticmethod
    def extra_downloads(config: RevancedConfig) -> None:
        """The function `extra_downloads` downloads extra files specified.

        Parameters
        ----------
        config : RevancedConfig
            The `config` parameter is an instance of the `RevancedConfig` class. It is used to provide
        configuration settings for the download process.
        """
        try:
            for extra in config.extra_download_files:
                url, file_name = extra.split("@")
                file_name_without_extension, file_extension = os.path.splitext(file_name)
                new_file_name = f"{file_name_without_extension}-output{file_extension}"
                APP.download(
                    url,
                    config,
                    assets_filter=f".*{file_extension}",
                    file_name=new_file_name,
                )
        except (ValueError, IndexError):
            logger.info("Unable to download extra file. Provide input in url@name.apk format.")
