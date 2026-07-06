import json
import logging
import re
from urllib.parse import quote

from bs4 import BeautifulSoup

from src import session, utils

base_url = "https://www.apkmirror.com"

REQUIRED_CONFIG_KEYS = ["org", "name", "type", "dpi", "package"]


def _validate_config(config: dict, context: str = "") -> bool:
    """Validate that config has required keys."""
    missing = [k for k in REQUIRED_CONFIG_KEYS if k not in config]
    if missing:
        logging.error(f"Missing required config keys {missing} for {context}")
        return False
    return True


def get_build_number_for_version(version: str, config: dict) -> tuple[str | None, str]:
    """Fetch build number for a specific version from APKMirror.
    Returns (build_number, format_type) where format_type is 'parentheses' or 'build_suffix'.
    Returns the LOWEST build number found, since patches are typically made for initial builds."""
    try:
        main_url = f"{base_url}/apk/{config['org']}/{config['name']}/"
        response = session.get(main_url)
        if response.status_code == 200:
            soup = BeautifulSoup(response.content, "html.parser")
            # Collect all build numbers for this version
            builds_found = []
            for link in soup.find_all("a", href=True):
                text = link.get_text()
                if version in text:
                    # Format 1: "32.30.0(1575420)" -> parentheses
                    build_match = re.search(rf"{re.escape(version)}\((\d+)\)", text)
                    if build_match:
                        builds_found.append((build_match.group(1), "parentheses"))
                    # Format 2: "6.6 build 006" -> build suffix
                    build_match = re.search(
                        rf"{re.escape(version)}\s+build\s+(\d+)", text, re.IGNORECASE
                    )
                    if build_match:
                        builds_found.append((build_match.group(1), "build_suffix"))

            # Return the lowest build number (patches are typically for initial builds)
            if builds_found:
                # Sort by build number (as integer) and return the lowest
                builds_found.sort(key=lambda x: int(x[0]))
                return builds_found[0]
    except Exception as e:
        logging.debug(f"Could not fetch build number: {e}")
    return None, None


def discover_app_main_url(config: dict) -> str | None:
    """Use APKMirror's search endpoint to discover the correct main app page URL when
    the configured 'org/name' combination doesn't match APKMirror's actual URL slugs.

    For example, config has org='duolingo', name='duolingo' but the actual page is at
    /apk/duolingo/duolingo-duolingo/. This function searches APKMirror and finds the
    correct main page URL by matching the org and the package name (most reliable).

    Returns the full main page URL if found, or None if discovery fails."""
    try:
        org = config.get("org", "")
        name = config.get("name", "")
        package = config.get("package", "")

        # Build search query - use package name if available (most precise), else app name
        # Strip ".apk" or trailing dashes from name for cleaner search
        query_terms = []
        if package:
            query_terms.append(package)
        if name:
            query_terms.append(name.replace("-", " "))

        for query in query_terms:
            search_url = (
                f"{base_url}/?post_type=app_release&searchtype=app&s={quote(query)}"
            )
            logging.info(f"Searching APKMirror for app: {search_url}")

            try:
                response = session.get(search_url)
                if response.status_code != 200:
                    continue

                soup = BeautifulSoup(response.content, "html.parser")

                # Find all /apk/{org}/{slug}/ links - these are candidate main app pages
                # We prioritize matches under the same 'org' as the config
                found_links = set()
                for link in soup.find_all("a", href=True):
                    href = link["href"]
                    # Match pattern /apk/{org}/{slug}/ but NOT /apk/{org}/{slug}/{anything-else}
                    m = re.match(r"^(/apk/[a-z0-9._-]+/[a-z0-9._-]+/)$", href)
                    if m:
                        found_links.add(m.group(1))

                if not found_links:
                    continue

                # Prefer links under the configured org
                org_links = [
                    link for link in found_links if link.startswith(f"/apk/{org}/")
                ]

                # Among org-matching links, find the one most likely to be the right app
                # Strategy: pick one whose slug contains the configured name as a substring
                # If multiple, prefer the shorter slug (more "exact" match)
                candidates = org_links if org_links else list(found_links)

                # Filter candidates: prefer those containing 'name' in the slug
                name_matches = [link for link in candidates if name and name in link]
                if name_matches:
                    candidates = name_matches

                # Sort by slug length (shorter = more specific match)
                candidates.sort(key=lambda x: len(x))

                if candidates:
                    discovered = base_url + candidates[0]
                    logging.info(f"✓ Discovered main app page via search: {discovered}")
                    return discovered
            except Exception as e:
                logging.debug(f"Error during search query '{query}': {e}")
                continue

        logging.debug("No matching app found via search")
        return None

    except Exception as e:
        logging.debug(f"Error in discover_app_main_url: {e}")
        return None


def _scrape_release_url_from_soup(
    soup, version: str, config: dict, build_number: str = None, build_format: str = None
) -> str | None:
    """Scan a BeautifulSoup-parsed main app page for a release link matching the version.
    Returns the full release page URL if found, else None."""
    version_parts = version.split(".")

    # Try full version first, then progressively strip parts (e.g., 6.77.5 -> 6.77 -> 6)
    for i in range(len(version_parts), 0, -1):
        current_ver = ".".join(version_parts[:i])
        current_ver_dash = "-".join(version_parts[:i])

        # Build search patterns for matching
        search_patterns = [current_ver, current_ver_dash]
        if build_number and i == len(version_parts):
            if build_format == "build_suffix":
                search_patterns.append(f"{current_ver} build {build_number}")
            else:
                search_patterns.append(f"{current_ver}({build_number})")

        # Find candidate release links (those containing the dashed version)
        # APKMirror release URLs look like: /apk/{org}/{app-slug}/{release-slug}-{version}-release/
        candidates = []
        for link in soup.find_all("a", href=True):
            href = link["href"]
            if not href.startswith("/apk/"):
                continue
            # Must look like a release page: contain the dashed version
            # Use regex to check the version is properly bounded (not part of a longer number)
            # e.g., for "6-77-5", match -6-77-5- or -6-77-5/
            ver_pattern = re.escape(current_ver_dash)
            if re.search(rf"(?:^|[/-]){ver_pattern}(?:[/-]|$)", href):
                # Prefer URLs ending with -release/
                priority = 0 if href.rstrip("/").endswith("-release") else 1
                candidates.append((priority, href))

        if candidates:
            # Sort by priority (release pages first), then by length (shorter = more specific)
            candidates.sort(key=lambda x: (x[0], len(x[1])))
            chosen = candidates[0][1]
            full_url = base_url + chosen
            logging.info(
                f"✓ Found release page on main listing for {current_ver}: {full_url}"
            )
            return full_url

    return None


def find_release_page_from_main(
    version: str, config: dict, build_number: str = None, build_format: str = None
) -> str | None:
    """Scrape the main app listing page on APKMirror to find the correct release page URL
    for a specific version. This avoids URL construction from config fields, which may not
    match APKMirror's actual URL slugs (e.g., 'duolingo' vs 'duolingo-language-lessons').

    Strategy:
    1. Try the configured main page (org/name from config)
    2. If that 404s, use APKMirror search to discover the correct main page URL
    3. Scrape release links from whichever main page works

    Returns the full release page URL if found, or None if scraping fails."""
    try:
        # Step 1: Try configured main page first (works for most apps)
        main_url = f"{base_url}/apk/{config['org']}/{config['name']}/"
        response = session.get(main_url)

        soup = None
        if response.status_code == 200:
            soup = BeautifulSoup(response.content, "html.parser")
            result = _scrape_release_url_from_soup(
                soup, version, config, build_number, build_format
            )
            if result:
                return result
            logging.debug(f"Main page accessible but no version match: {main_url}")
        else:
            logging.info(
                f"Configured main page returned {response.status_code}: {main_url}"
            )

        # Step 2: If configured main page failed or didn't yield a match, try discovering
        # the correct main page via APKMirror's search endpoint
        discovered_url = discover_app_main_url(config)
        if discovered_url and discovered_url != main_url:
            logging.info(f"Trying discovered main page: {discovered_url}")
            response = session.get(discovered_url)
            if response.status_code == 200:
                soup = BeautifulSoup(response.content, "html.parser")
                result = _scrape_release_url_from_soup(
                    soup, version, config, build_number, build_format
                )
                if result:
                    return result

        logging.debug(
            f"Could not find release page URL from main listing for version {version}"
        )
        return None

    except Exception as e:
        logging.debug(f"Error scraping main page for release URL: {e}")
        return None


def get_download_link(
    version: str, app_name: str, config: dict, arch: str = None
) -> str | None:
    if not version:
        logging.error(f"No version provided for {app_name}")
        return None

    if not _validate_config(config, app_name):
        return None

    target_arch = arch if arch else config.get("arch", "universal")

    criteria = [config["type"], target_arch, config["dpi"]]

    # --- UNIVERSAL URL FINDER WITH VALIDATION ---
    # Extract build number if present (e.g., "32.30.0(1575420)" -> version="32.30.0", build="1575420")
    build_number = None
    build_format = None

    # Check for parentheses format: "32.30.0(1575420)"
    build_match = re.search(r"\((\d+)\)$", version)
    if build_match:
        build_number = build_match.group(1)
        build_format = "parentheses"
        version = version[: build_match.start()]
    else:
        # Check for build suffix format: "6.6 build 002"
        build_match = re.search(r"\s+build\s+(\d+)$", version, re.IGNORECASE)
        if build_match:
            build_number = build_match.group(1)
            build_format = "build_suffix"
            version = version[: build_match.start()]
        else:
            # Try to fetch build number from APKMirror for this version
            build_number, build_format = get_build_number_for_version(version, config)
            if build_number:
                logging.info(
                    f"Found build number {build_number} for version {version} (format: {build_format})"
                )

    version_parts = version.split(".")
    found_soup = None
    correct_version_page = False

    # --- PRIMARY APPROACH: Scrape the main app page for the correct release URL ---
    # This is more reliable than constructing URLs from config fields, because
    # APKMirror's actual URL slugs often differ from config values
    # (e.g., 'duolingo' slug vs 'duolingo-language-lessons' actual release name)
    scraped_url = find_release_page_from_main(
        version, config, build_number, build_format
    )
    if scraped_url:
        logging.info(f"Trying scraped release URL: {scraped_url}")
        try:
            response = session.get(scraped_url)
            if response.status_code == 200:
                soup = BeautifulSoup(response.content, "html.parser")
                page_text = soup.get_text()
                # Quick validation: check version appears on page
                if version in page_text or version.replace(".", "-") in page_text:
                    logging.info(f"✓ Scraped release page validated: {response.url}")
                    found_soup = soup
                    correct_version_page = True
                else:
                    logging.warning(
                        f"Scraped URL returned page but version {version} not found in content"
                    )
        except Exception as e:
            logging.warning(f"Error fetching scraped URL: {e}")

    # --- FALLBACK: Construct URLs from config fields ---
    # Only used if scraping the main page didn't work
    if not correct_version_page:
        logging.info(
            "Scraping didn't find the page, falling back to URL construction..."
        )

    # Use release_prefix if available, otherwise use app name
    release_name = config.get("release_prefix", config["name"])

    # Limit version stripping to 2 levels to reduce HTTP requests
    max_version_parts = min(len(version_parts), 2)

    for i in range(
        len(version_parts), max(len(version_parts) - max_version_parts, 0), -1
    ):
        current_ver_str = "-".join(version_parts[:i])

        # If build number exists, append it to the last version part in URL
        if build_number and i == len(version_parts):
            if build_format == "build_suffix":
                # e.g., "6-6" + "build-006" -> "6-6-build-006"
                current_ver_str = current_ver_str + "-build-" + build_number
            else:
                # e.g., "32-30-0" + "1575420" -> "32-30-01575420"
                parts = version_parts[:i]
                parts[-1] = parts[-1] + build_number
                current_ver_str = "-".join(parts)

        # Generate ALL possible URL patterns in priority order
        url_patterns = []

        # URL-encode the release_name to handle unicode characters like ․
        encoded_release_name = quote(release_name, safe="")
        encoded_name = quote(config["name"], safe="")

        # Priority 1: With release_name and -release suffix (most specific)
        url_patterns.append(
            f"{base_url}/apk/{config['org']}/{encoded_name}/{encoded_release_name}-{current_ver_str}-release/"
        )

        # Priority 2: With app name and -release suffix
        if release_name != config["name"]:
            url_patterns.append(
                f"{base_url}/apk/{config['org']}/{encoded_name}/{encoded_name}-{current_ver_str}-release/"
            )

        # Priority 3: With release_name without -release
        url_patterns.append(
            f"{base_url}/apk/{config['org']}/{encoded_name}/{encoded_release_name}-{current_ver_str}/"
        )

        # Priority 4: With app name without -release
        if release_name != config["name"]:
            url_patterns.append(
                f"{base_url}/apk/{config['org']}/{encoded_name}/{encoded_name}-{current_ver_str}/"
            )

        # Remove duplicate patterns
        url_patterns = list(dict.fromkeys(url_patterns))

        for url in url_patterns:
            logging.info(f"Checking potential release URL: {url}")

            try:
                response = session.get(url)
                if response.status_code == 200:
                    soup = BeautifulSoup(response.content, "html.parser")
                    page_text = soup.get_text()

                    # VALIDATION: Check if this page is for our EXACT version
                    # Check multiple possible version formats
                    version_checks = [
                        version,  # 6.6
                        version.replace(".", "-"),  # 6-6
                        current_ver_str,  # 6-6-build-002 (if stripped)
                        ".".join(version_parts[:i]),  # 6.6 (if stripped)
                    ]

                    # Add build suffix format if we have a build number
                    if build_number:
                        if build_format == "build_suffix":
                            version_checks.append(
                                f"{version} build {build_number}"
                            )  # 6.6 build 002
                            version_checks.append(
                                f"{version.replace('.', '-')}-build-{build_number}"
                            )  # 6-6-build-002
                        else:
                            version_checks.append(
                                f"{version}({build_number})"
                            )  # 32.30.0(1575420)

                    # Also check page title and headings for version
                    title_tag = soup.find("title")
                    headings = soup.find_all(["h1", "h2", "h3"])

                    is_correct_page = False

                    # Check in page text
                    for check in version_checks:
                        if check and check in page_text:
                            # Accept version match if it's the base version or includes build info
                            if (
                                check == version
                                or check == version.replace(".", "-")
                                or check == current_ver_str
                            ):
                                is_correct_page = True
                                break

                    # Check in title and headings
                    if not is_correct_page:
                        for heading in headings:
                            heading_text = heading.get_text()
                            for check in version_checks:
                                if check and check in heading_text:
                                    is_correct_page = True
                                    break
                            if is_correct_page:
                                break

                    if not is_correct_page and title_tag:
                        title_text = title_tag.get_text()
                        for check in version_checks:
                            if check and check in title_text:
                                is_correct_page = True
                                break

                    if is_correct_page:
                        content_size = len(response.content)
                        logging.info(f"✓ Correct version page found: {response.url}")
                        found_soup = soup
                        correct_version_page = True
                        break  # Found correct page!
                    else:
                        # Page exists but doesn't have our version as primary
                        logging.warning(
                            f"Page found but not for version {version}: {url}"
                        )
                        # Save as fallback ONLY if we haven't found any page yet
                        if found_soup is None:
                            found_soup = soup
                            logging.warning(
                                f"Saved as fallback page (may list multiple versions)"
                            )
                        continue

                elif response.status_code == 404:
                    logging.info(f"URL not found (404): {url}")
                    continue
                else:
                    logging.warning(f"URL {url} returned status {response.status_code}")
                    continue

            except Exception as e:
                logging.warning(f"Error checking {url}: {e}")
                continue

        if correct_version_page:
            break  # Found correct page for this version part

    # If we didn't find the exact version page but found a fallback
    if not correct_version_page and found_soup:
        logging.warning(
            f"Using fallback page for {app_name} {version} (may contain multiple versions)"
        )

    if not found_soup:
        logging.error(f"Could not find any release page for {app_name} {version}")
        return None

    # --- VARIANT FINDER (works with both exact pages and fallback pages) ---
    rows = found_soup.find_all("div", class_="table-row headerFont")
    download_page_url = None

    # Try to find exact version match first
    for row in rows:
        row_text = row.get_text()

        # Check if row contains our exact version
        if version in row_text or version.replace(".", "-") in row_text:
            # Check criteria
            if all(criterion in row_text for criterion in criteria):
                sub_url = row.find("a", class_="accent_color")
                if sub_url:
                    download_page_url = base_url + sub_url["href"]
                    break

    # If exact version not found, try to find any variant matching criteria
    if not download_page_url:
        for row in rows:
            row_text = row.get_text()
            if all(criterion in row_text for criterion in criteria):
                # Check if this looks like a variant row (has version numbers)
                if re.search(r"\d+(\.\d+)+", row_text):
                    sub_url = row.find("a", class_="accent_color")
                    if sub_url:
                        download_page_url = base_url + sub_url["href"]
                        # Extract version for logging
                        match = re.search(r"(\d+(\.\d+)+(\.\w+)*)", row_text)
                        if match:
                            actual_version = match.group(1)
                            logging.warning(
                                f"Using variant {actual_version} (criteria match)"
                            )
                        break

    if not download_page_url:
        logging.error(
            f"No variant found for {app_name} {version} with criteria {criteria}"
        )
        # Debug: log what rows we found
        logging.debug(f"Found {len(rows)} rows total")
        for idx, row in enumerate(rows[:5]):  # First 5 rows
            logging.debug(f"Row {idx}: {row.get_text()[:100]}...")
        return None

    # --- STANDARD DOWNLOAD FLOW ---
    try:
        response = session.get(download_page_url)
        response.raise_for_status()
        content_size = len(response.content)
        logging.info(
            f"URL:{response.url} [{content_size}/{content_size}] -> Variant Page"
        )
        soup = BeautifulSoup(response.content, "html.parser")

        sub_url = soup.find("a", class_="downloadButton")
        if sub_url:
            final_download_page_url = base_url + sub_url["href"]
            response = session.get(final_download_page_url)
            response.raise_for_status()
            content_size = len(response.content)
            logging.info(
                f"URL:{response.url} [{content_size}/{content_size}] -> Download Page"
            )
            soup = BeautifulSoup(response.content, "html.parser")

            button = soup.find("a", id="download-link")
            if button:
                return base_url + button["href"]
    except Exception as e:
        logging.error(f"Error in download flow: {e}")

    return None


def get_architecture_criteria(arch: str) -> dict:
    """Map architecture names to APKMirror criteria"""
    arch_mapping = {
        "arm64-v8a": "arm64-v8a",
        "armeabi-v7a": "armeabi-v7a",
        "universal": "universal",
    }
    return arch_mapping.get(arch, "universal")


def get_latest_version(app_name: str, config: dict) -> str | None:
    if not _validate_config(config, app_name):
        return None

    # First try: get from main app page
    try:
        main_url = f"{base_url}/apk/{config['org']}/{config['name']}/"
        response = session.get(main_url)
        if response.status_code == 200:
            soup = BeautifulSoup(response.content, "html.parser")
            # Try to find version in the page
            version_elem = soup.find("span", string=re.compile(r"\d+\.\d+"))
            if version_elem:
                version_text = version_elem.text.strip()
                match = re.search(r"(\d+(\.\d+)+)", version_text)
                if match:
                    return match.group(1)
    except Exception as e:
        logging.debug(f"Main page version scan failed: {e}")

    # Original method (keep exactly as you had it)
    url = f"{base_url}/uploads/?appcategory={config['name']}"

    response = session.get(url)
    response.raise_for_status()
    content_size = len(response.content)
    logging.info(f'URL:{response.url} [{content_size}/{content_size}] -> "-" [1]')
    soup = BeautifulSoup(response.content, "html.parser")

    app_rows = soup.find_all("div", class_="appRow")
    version_pattern = re.compile(r"\d+(\.\d+)*(-[a-zA-Z0-9]+(\.\d+)*)*")

    for row in app_rows:
        version_text = row.find("h5", class_="appRowTitle").a.text.strip()
        if "alpha" not in version_text.lower() and "beta" not in version_text.lower():
            match = version_pattern.search(version_text)
            if match:
                version = match.group()
                version_parts = version.split(".")
                base_version_parts = []
                for part in version_parts:
                    if part.isdigit():
                        base_version_parts.append(part)
                    else:
                        break
                if base_version_parts:
                    base_version = ".".join(base_version_parts)

                    # Check for build number in parentheses like "32.30.0(1575420)"
                    build_match = re.search(r"\((\d+)\)", version_text)
                    if build_match:
                        build_number = build_match.group(1)
                        return f"{base_version}({build_number})"

                    return base_version

    return None
