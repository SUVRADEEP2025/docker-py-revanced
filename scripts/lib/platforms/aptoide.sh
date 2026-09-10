#!/usr/bin/env bash
# Aptoide platform downloader - uses apkeep natively (apkeep has excellent Aptoide support)

get_latest_version() {
    local _app_name="$1" # reserved: uniform get_latest_version signature
    local config="$2"
    
    local package
    package=$(echo "$config" | jq -r '.package // ""')
    
    if [[ -z "$package" ]]; then
        return 1
    fi
    
    # Aptoide API
    local api_url="https://ws75.aptoide.com/api/7/apps/search?q=${package}&limit=1&trusted=true"
    
    local response
    response=$(curl -sL "$api_url" 2>/dev/null || true)
    
    if [[ -n "$response" ]]; then
        # Extract version from response
        local version
        version=$(echo "$response" | jq -r '.data[0].file.vername // empty' 2>/dev/null || true)
        
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
    
    local package
    package=$(echo "$config" | jq -r '.package // ""')
    
    # Try apkeep first - it has native Aptoide support
    if command -v apkeep &>/dev/null; then
        # Aptoide app URL
        local url="https://en.aptoide.com/app/${package}"
        
        # apkeep --aptoide <url>
        apkeep --aptoide "$url" -d . 2>/dev/null && {
            local apk_file
            apk_file=$(find . -maxdepth 1 -name '*.apk' -o -name '*.apkm' | head -1)
            if [[ -n "$apk_file" ]]; then
                echo "$apk_file"
                return 0
            fi
        }
    fi
    
    # Fallback: use Aptoide API directly
    # Get list of versions
    local versions_url="https://ws75.aptoide.com/api/7/listAppVersions?package_name=${package}&limit=100"
    
    local versions_response
    versions_response=$(curl -sL "$versions_url" 2>/dev/null || true)
    
    if [[ -n "$versions_response" ]]; then
        # Find the matching version
        local vercode
        vercode=$(echo "$versions_response" | jq -r --arg v "$version" \
            '.data.list[]? | select((.file.vername // "") == $v or (.file.vername // "") | test($v; "i")) | .file.vercode' | head -1)
        
        # If not found exactly, try normalized match
        if [[ -z "$vercode" ]]; then
            local clean_version
            clean_version=$(printf '%s' "$version" | tr -d '()')
            vercode=$(echo "$versions_response" | jq -r --arg v "$clean_version" \
                '.data.list[]? | select(.file.vername // "" | test($v; "i")) | .file.vercode' | head -1)
        fi
        
        if [[ -z "$vercode" ]]; then
            # Fallback to first version
            vercode=$(echo "$versions_response" | jq -r '.data.list[0].file.vercode // empty' 2>/dev/null || true)
        fi
        
        if [[ -n "$vercode" ]]; then
            # Get download URL
            local meta_url="https://ws75.aptoide.com/api/7/getAppMeta?package_name=${package}&vercode=${vercode}"
            local meta_response
            meta_response=$(curl -sL "$meta_url" 2>/dev/null || true)
            
            if [[ -n "$meta_response" ]]; then
                local dl_url
                dl_url=$(echo "$meta_response" | jq -r '.data.file.path // empty' 2>/dev/null || true)
                
                if [[ -n "$dl_url" ]]; then
                    echo "$dl_url"
                    return 0
                fi
            fi
        fi
    fi
    
    return 1
}
