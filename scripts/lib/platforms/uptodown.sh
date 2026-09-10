#!/usr/bin/env bash
# Uptodown platform downloader - uses apkeep natively

get_latest_version() {
    local _app_name="$1" # reserved: uniform get_latest_version signature
    local config="$2"
    
    local slug
    slug=$(echo "$config" | jq -r '.slug // .name // ""')
    
    # Try multiple locale hosts
    local locales=("en" "de" "fr" "in" "it" "ru" "jp" "kr")
    
    for locale in "${locales[@]}"; do
        local url="https://${slug}.${locale}.uptodown.com/android/versions"
        
        local response
        response=$(curl -sL -H "User-Agent: Mozilla/5.0" "$url" 2>/dev/null || true)
        
        if [[ -n "$response" ]]; then
            # Check if it's an app page
            if echo "$response" | grep -q 'id="detail-app-name"'; then
                # Extract version from versions list
                local version
                version=$(echo "$response" | grep -oP 'class="version"[^>]*>([^<]+)<' | head -1 | \
                    grep -oP '>([^<]+)<' | cut -d'>' -f2 | cut -d'<' -f1)
                
                if [[ -n "$version" ]]; then
                    echo "$version"
                    return 0
                fi
                
                # Alternative: try itemprop
                version=$(echo "$response" | grep -oP 'itemprop="softwareVersion"[^>]*content="([^"]+)"' | \
                    head -1 | cut -d'"' -f2)
                
                if [[ -n "$version" ]]; then
                    echo "$version"
                    return 0
                fi
            fi
        fi
    done
    
    return 1
}

get_download_link() {
    local version="$1"
    local _app_name="$2" # reserved: uniform get_download_link signature
    local config="$3"
    
    local slug
    slug=$(echo "$config" | jq -r '.slug // .name // ""')
    
    # Try apkeep first - it has native Uptodown support
    if command -v apkeep &>/dev/null; then
        # Uptodown app URL format
        local url="https://uptodown.com/${slug}/android/${version}/"
        
        # apkeep --uptodown <url>
        apkeep --uptodown "$url" -d . 2>/dev/null && {
            local apk_file
            apk_file=$(find . -maxdepth 1 -name '*.apk' -o -name '*.apkm' -o -name '*.xapk' | head -1)
            if [[ -n "$apk_file" ]]; then
                echo "$apk_file"
                return 0
            fi
        }
    fi
    
    # Fallback: scrape to find download URL
    local locales=("en" "de" "fr" "in" "it" "ru" "jp" "kr")
    
    for locale in "${locales[@]}"; do
        local base_url="https://${slug}.${locale}.uptodown.com/android"
        
        # Get versions page
        local versions_response
        versions_response=$(curl -sL -H "User-Agent: Mozilla/5.0" "$base_url/versions" 2>/dev/null || true)
        
        if [[ -n "$versions_response" ]] && echo "$versions_response" | grep -q 'id="detail-app-name"'; then
            # Get app code
            local data_code
            data_code=$(echo "$versions_response" | grep -oP 'id="detail-app-name"[^>]*data-code="([^"]+)"' | \
                head -1 | cut -d'"' -f2)
            
            if [[ -n "$data_code" ]]; then
                # Search for the specific version
                for page in {1..10}; do
                    local page_url="${base_url}/apps/${data_code}/versions/${page}"
                    local page_response
                    page_response=$(curl -sL "$page_url" 2>/dev/null || true)
                    
                    if [[ -n "$page_response" ]]; then
                        # Parse JSON response
                        local version_url
                        version_url=$(echo "$page_response" | jq -r --arg v "$version" \
                            '.data[]? | select(.version == $v) | .versionURL | join("/")' 2>/dev/null || true)
                        
                        if [[ -n "$version_url" ]]; then
                            local version_page_response
                            version_page_response=$(curl -sL "$version_url" 2>/dev/null || true)
                            
                            if [[ -n "$version_page_response" ]]; then
                                # Look for download button
                                local dl_url
                                dl_url=$(echo "$version_page_response" | grep -oP 'id="detail-download-button"[^>]*data-url="([^"]+)"' | \
                                    head -1 | cut -d'"' -f2)
                                
                                if [[ -n "$dl_url" ]]; then
                                    echo "https://dw.uptodown.com/dwn/${dl_url}"
                                    return 0
                                fi
                                
                                # Alternative: direct link
                                dl_url=$(echo "$version_page_response" | grep -oP 'class="download"[^>]*href="([^"]+\.apk[^"]*)"' | \
                                    head -1 | cut -d'"' -f2)
                                
                                if [[ -n "$dl_url" ]]; then
                                    echo "https://uptodown.com${dl_url}"
                                    return 0
                                fi
                            fi
                        fi
                    fi
                    
                    # Check if we've gone past the target version
                    local max_ver
                    max_ver=$(echo "$page_response" | jq -r '.data[-1].version // ""' 2>/dev/null || true)
                    if [[ -n "$max_ver" ]] && [[ "$(echo "$max_ver" | tr '.' ' ')" < "$(echo "$version" | tr '.' ' ')" ]]; then
                        break
                    fi
                done
            fi
        fi
    done
    
    return 1
}
