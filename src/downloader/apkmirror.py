"""Downloader Class."""

from typing import Any, Self

import requests
from bs4 import BeautifulSoup, Tag
from loguru import logger

from ..app import APP
from .download import Downloader
from .sources import APK_MIRROR_BASE_URL
from ..exceptions import APKMirrorAPKDownloadError, ScrapingError
from ..utils import bs4_parser, contains_any_word, handle_request_response, request_header, request_timeout, slugify


class ApkMirror(Downloader):
    """Files downloader."""

    def _extract_force_download_link(self: Self, link: str, app: str) -> tuple[str, str]:
        """Extract force download link."""
        link_page_source = self._extract_source(link)
        notes_divs = self._extracted_search_source_div(link_page_source, "tab-pane")
        apk_type = self._extracted_search_source_div(link_page_source, "apkm-badge").get_text()
        extension = "zip" if apk_type == "BUNDLE" else "apk"
        possible_links = notes_divs.find_all("a")
        for possible_link in possible_links:
            if not isinstance(possible_link, Tag):
                continue
            href = possible_link.get("href")
            if href and "download.php?id=" in href:
                file_name = f"{app}.{extension}"
                download_url = APK_MIRROR_BASE_URL + str(possible_link["href"])
                self._download(download_url, file_name)
                return file_name, download_url
        msg = f"Unable to extract force download for {app}"
        raise APKMirrorAPKDownloadError(msg, url=link)

    def extract_download_link(self: Self, page: str, app: str) -> tuple[str, str]:
        """Function to extract the download link from apkmirror html page.

        :param page: Url of the page
        :param app: Name of the app
        """
        logger.debug(f"Extracting download link from\n{page}")
        download_button = self._extracted_search_div(page, "center")
        download_links = download_button.find_all("a")
        final_download_link = None
        for download_link in download_links:
            if not isinstance(download_link, Tag):
                continue
            href = download_link.get("href")
            if href and "download/?key=" in href:
                final_download_link = str(download_link["href"])
                break

        if final_download_link:
            return self._extract_force_download_link(APK_MIRROR_BASE_URL + final_download_link, app)
        msg = f"Unable to extract link from {app} version list"
        raise APKMirrorAPKDownloadError(msg, url=page)

    def get_download_page(self: Self, main_page: str) -> str:
        """Function to get the download page in apk_mirror.

        :param main_page: Main Download Page in APK mirror(Index)
        :return:
        """
        list_widget = self._extracted_search_div(main_page, "tab-pane noPadding")
        table_rows = list_widget.find_all(class_="table-row headerFont")
        links: dict[str, str] = {}
        apk_archs = ["arm64-v8a", "universal", "noarch"]
        for row in table_rows:
            if not isinstance(row, Tag):
                continue
            accent_color_elem = row.find(class_="accent_color")
            if accent_color_elem:
                if not isinstance(accent_color_elem, Tag):
                    continue
                apkm_badge_elem = row.find(class_="apkm-badge")
                if not isinstance(apkm_badge_elem, Tag):
                    continue
                apk_type = apkm_badge_elem.get_text()
                sub_url = str(accent_color_elem["href"])
                text = row.text.strip()
                if apk_type == "APK" and (not contains_any_word(text, apk_archs)):
                    continue
                links[apk_type] = f"{APK_MIRROR_BASE_URL}{sub_url}"
        if preferred_link := links.get("APK", links.get("BUNDLE")):
            return preferred_link
        msg = "Unable to extract download page"
        raise APKMirrorAPKDownloadError(msg, url=main_page)

    @staticmethod
    def _extract_source(url: str) -> str:
        """Extracts the source from the url incase of reuse."""
        response = requests.get(url, headers=request_header, timeout=request_timeout)
        handle_request_response(response, url)
        return response.text

    @staticmethod
    def _extracted_search_source_div(source: str, search_class: str) -> Tag:
        """Extract search div from source."""
        soup = BeautifulSoup(source, bs4_parser)
        return soup.find(class_=search_class)  # type: ignore[return-value]

    def _extracted_search_div(self: Self, url: str, search_class: str) -> Tag:
        """Extract search div from url."""
        return self._extracted_search_source_div(self._extract_source(url), search_class)

    def specific_version(self: Self, app: APP, version: str, main_page: str = "") -> tuple[str, str]:
        """Function to download the specified version of app from  apkmirror.

        :param app: Name of the application
        :param version: Version of the application to download
        :param main_page: Version of the application to download
        :return: Version of downloaded apk
        """
        if not main_page:
            version = version.replace(".", "-")
            apk_main_page = app.download_source
            if apk_main_page is None:
                msg = f"No download source available for {app.app_name}"
                raise APKMirrorAPKDownloadError(msg, url="")
            version_page = apk_main_page + apk_main_page.split("/")[-2]
            main_page = f"{version_page}-{version}-release/"
        download_page = self.get_download_page(main_page)
        if app.app_version == "latest":
            try:
                logger.info(f"Trying to guess {app.app_name} version.")
                appsec_val = self._extracted_search_div(download_page, "appspec-value")
                appsec_version = str(appsec_val.find(text=lambda text: "Version" in text))
                app.app_version = slugify(appsec_version.split(":")[-1].strip())
                logger.info(f"Guessed {app.app_version} for {app.app_name}")
            except ScrapingError:
                pass
        return self.extract_download_link(download_page, app.app_name)

    def latest_version(self: Self, app: APP, **kwargs: Any) -> tuple[str, str]:
        """Function to download whatever the latest version of app from apkmirror.

        :param app: Name of the application
        :return: Version of downloaded apk
        """
        app_main_page = app.download_source
        if app_main_page is None:
            msg = f"No download source available for {app.app_name}"
            raise APKMirrorAPKDownloadError(msg, url="")
        versions_div = self._extracted_search_div(app_main_page, "listWidget p-relative")
        app_rows = versions_div.find_all(class_="appRow")
        version_urls = []
        for app_row in app_rows:
            if not isinstance(app_row, Tag):
                continue
            app_row_title = app_row.find(class_="appRowTitle")
            if not isinstance(app_row_title, Tag):
                continue
            title_text = app_row_title.get_text().lower()
            if "beta" in title_text or "alpha" in title_text:
                continue
            download_link = app_row.find(class_="downloadLink")
            if not isinstance(download_link, Tag):
                continue
            version_urls.append(str(download_link["href"]))
        return self.specific_version(app, "latest", APK_MIRROR_BASE_URL + max(version_urls))
