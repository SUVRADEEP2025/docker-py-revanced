#!/usr/bin/env bash
# APKPure platform downloader - uses apkeep natively

get_latest_version() {
    local _app_name="$1" # reserved: uniform get_latest_version signature
    local config="$2"
    
    local app_slug pkg
    app_slug=$(echo "$config" | jq -r '.name // ""')
    pkg=$(echo "$config" | jq -r '.package // ""')
    
    # APKPure URL for versions page
    local url="https://apkpure.net/${app_slug}/${pkg}/versions"
    
    local response
    response=$(curl -sL -H "User-Agent: Mozilla/5.0" "$url" 2>/dev/null || true)
    
    if [[ -n "$response" ]]; then
        # Extract version from data-dt-version attribute
        local version
        version=$(echo "$response" | grep -oP 'data-dt-version="([0-9.]+)"' | head -1 | cut -d'"' -f2)
        
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi
    
    return 1
}

get_download_link() {
    local version="$1"
    local _app_name="$2" # reserved: uniform get_download_link signature
    local config="$3"
    
    local app_slug pkg
    app_slug=$(echo "$config" | jq -r '.name // ""')
    pkg=$(echo "$config" | jq -r '.package // ""')
    
    # Try apkeep first - it has native APKPure support
    if command -v apkeep &>/dev/null; then
        local url="https://apkpure.net/${app_slug}/${pkg}/download/${version}"
        
        # apkeep --apkpure <url>
        apkeep --apkpure "$url" -d . 2>/dev/null && {
            local apk_file
            apk_file=$(find . -maxdepth 1 -name '*.apk' -o -name '*.apkm' | head -1)
            if [[ -n "$apk_file" ]]; then
                echo "$apk_file"
                return 0
            fi
        }
    fi
    
    # Fallback: scrape the download page
    local url="https://apkpure.net/${app_slug}/${pkg}/download/${version}"
    
    local response
    response=$(curl -sL -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -H "Referer: https://apkpure.net/" "$url" 2>/dev/null || true)
    
    if [[ -n "$response" ]]; then
        # Look for download_link element
        local dl
        dl=$(echo "$response" | grep -oP 'id="download_link"[^>]*href="([^"]+)"' | head -1 | cut -d'"' -f2)
        
        if [[ -n "$dl" ]]; then
            echo "$dl"
            return 0
        fi
    fi
    
    return 1
}
