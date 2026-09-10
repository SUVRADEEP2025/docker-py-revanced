#!/usr/bin/env bash
# APKMirror platform downloader - prefers apkeep, falls back to scraping

get_latest_version() {
    local _app_name="$1" # reserved: uniform get_latest_version signature
    local config="$2"

    local org name
    org=$(echo "$config" | jq -r '.org // ""')
    name=$(echo "$config" | jq -r '.name // ""')

    # Try to get latest version from APKMirror listing
    local main_url="https://www.apkmirror.com/apk/${org}/${name}/"

    # Use curl to fetch and parse
    local response
    response=$(curl -sL "$main_url" 2>/dev/null || true)

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Extract version from h5.appRowTitle elements
    local version
    version=$(echo "$response" | grep -oP 'class="appRowTitle"[^>]*>[^<]*\((\d+\.\d+[^<]*)\)' | \
        grep -oP '\d+\.\d+[^)]*' | head -1)

    if [[ -z "$version" ]]; then
        # Fallback: search page
        local search_url="https://www.apkmirror.com/?post_type=app_release&searchtype=app&s=${name}"
        response=$(curl -sL "$search_url" 2>/dev/null || true)
        version=$(echo "$response" | grep -oP 'class="appRowTitle"[^>]*>[^<]*\(\d+\.\d+[^<]*\)' | \
            grep -oP '\d+\.\d+[^)]*' | head -1)
    fi

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi

    return 1
}

get_download_link() {
    local version="$1"
    local _app_name="$2" # reserved: uniform get_download_link signature
    local config="$3"

    local org name arch dpi
    org=$(echo "$config" | jq -r '.org // ""')
    name=$(echo "$config" | jq -r '.name // ""')
    arch=$(echo "$config" | jq -r '.arch // "universal"')
    dpi=$(echo "$config" | jq -r '.dpi // "nodpi"')

    # Try apkeep first - it handles APKMirror natively
    if command -v apkeep &>/dev/null; then
        # apkeep can download from APKMirror URL directly
        # We need to find the correct URL first

        # Search for the app on APKMirror
        local search_url="https://www.apkmirror.com/?post_type=app_release&searchtype=app&s=${name}"
        local search_response
        search_response=$(curl -sL "$search_url" 2>/dev/null || true)

        if [[ -n "$search_response" ]]; then
            # Find the app page URL
            local app_page
            app_page=$(echo "$search_response" | grep -oP 'href="(/apk/[^"]+)"' | head -1 | cut -d'"' -f2)

            if [[ -n "$app_page" ]]; then
                # The app page should contain download links
                # For apkeep, we can pass the direct APK URL

                # Construct potential download URL patterns
                # apkeep --apkmirror <url>
                local base_url="https://www.apkmirror.com/apk/${org}/${name}"

                # Try to find the exact version page
                local version_page_url="${base_url}/${version}-release/"

                local version_response
                version_response=$(curl -sL "$version_page_url" 2>/dev/null || true)

                if [[ -n "$version_response" ]]; then
                    # Extract download link from the page
                    local dl_link
                    dl_link=$(echo "$version_response" | grep -oP 'href="([^"]*-android-apk-download[^"]*)"' | head -1 | cut -d'"' -f2)

                    if [[ -n "$dl_link" ]]; then
                        local full_dl_url="https://www.apkmirror.com${dl_link}"
                        # Use apkeep to download
                        apkeep --apkmirror "$full_dl_url" -d . 2>/dev/null && {
                            local apk_file
                            apk_file=$(find . -maxdepth 1 -name '*.apk' -o -name '*.apkm' | head -1)
                            if [[ -n "$apk_file" ]]; then
                                echo "$apk_file"
                                return 0
                            fi
                        }
                    fi
                fi
            fi
        fi
    fi

    # Fallback: scrape the page to find download URL
    local base_url="https://www.apkmirror.com/apk/${org}/${name}"

    # Try to find the version page
    local version_url="${base_url}/${version}-release/"
    local ver_response
    ver_response=$(curl -sL "$version_url" 2>/dev/null || true)

    if [[ -n "$ver_response" ]]; then
        # Look for download link
        local dl_url
        dl_url=$(echo "$ver_response" | grep -oP 'href="([^"]*-android-apk-download[^"]*)"' | head -1 | cut -d'"' -f2)

        if [[ -n "$dl_url" ]]; then
            dl_url="https://www.apkmirror.com${dl_url}"
            local dl_response
            dl_response=$(curl -sL "$dl_url" 2>/dev/null || true)

            if [[ -n "$dl_response" ]]; then
                # Get the actual download link
                local final_url
                final_url=$(echo "$dl_response" | grep -oP 'id="download-link"[^>]*href="([^"]+)"' | head -1 | \
                    grep -oP 'href="([^"]+)"' | cut -d'"' -f2)

                if [[ -n "$final_url" ]]; then
                    echo "$final_url"
                    return 0
                fi
            fi
        fi
    fi

    # If direct URL failed, try to construct it

    # Build URL from components
    local url_pattern="${base_url}/${name}-${version}-${arch}-${dpi}-release/"

    local test_response
    test_response=$(curl -sI "$url_pattern" 2>/dev/null || true)

    if [[ "$test_response" == *"200"* ]]; then
        # Found the page, now get download link
        local page
        page=$(curl -sL "$url_pattern" 2>/dev/null || true)
        local dl
        dl=$(echo "$page" | grep -oP 'href="([^"]*-android-apk-download[^"]*)"' | head -1 | cut -d'"' -f2)
        [[ -n "$dl" ]] && echo "https://www.apkmirror.com${dl}" && return 0
    fi

    return 1
}
