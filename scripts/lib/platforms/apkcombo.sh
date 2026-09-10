#!/usr/bin/env bash
# APKCombo platform downloader - fallback, uses apkeep when possible

get_latest_version() {
    local _app_name="$1" # reserved: uniform get_latest_version signature
    local config="$2"
    
    local package
    package=$(echo "$config" | jq -r '.package // ""')
    
    if [[ -z "$package" ]]; then
        return 1
    fi
    
    # APKCombo search URL
    local url="https://apkcombo.com/search/${package}/download"
    
    local response
    response=$(curl -sL -H "User-Agent: Mozilla/5.0" "$url" 2>/dev/null || true)
    
    if [[ -n "$response" ]]; then
        # Extract versions from page
        local version
        version=$(echo "$response" | grep -oP 'phone-([\d.]+[^-]*)-(?:apk|xapk|apks)' | \
            sed 's/phone-//' | sed 's/-[a-z]*$//' | sort -V | tail -1)
        
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
    
    if [[ -z "$package" ]] || [[ -z "$version" ]]; then
        return 1
    fi
    
    # Try apkeep first
    if command -v apkeep &>/dev/null; then
        # APKCombo direct download URL pattern
        for ext in apk xapk apks; do
            local url="https://apkcombo.com/search/${package}/download/phone-${version}-${ext}"
            
            apkeep "$url" -d . 2>/dev/null && {
                local apk_file
                apk_file=$(find . -maxdepth 1 -name '*.apk' -o -name '*.apkm' -o -name '*.xapk' | head -1)
                if [[ -n "$apk_file" ]]; then
                    echo "$apk_file"
                    return 0
                fi
            }
        done
    fi
    
    # Fallback: scrape for download link
    for ext in apk xapk apks; do
        local url="https://apkcombo.com/search/${package}/download/phone-${version}-${ext}"
        
        local response
        response=$(curl -sL -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131 Safari/537.36" \
            "$url" 2>/dev/null || true)
        
        if [[ -n "$response" ]]; then
            # Look for variant download links (these are /r2?u=... redirects)
            local dl
            dl=$(echo "$response" | grep -oP 'class="variant"[^>]*href="([^"]+)"' | head -1 | cut -d'"' -f2)
            
            if [[ -n "$dl" ]]; then
                # Follow redirect
                local final_url
                final_url=$(curl -sL "$dl" 2>/dev/null || true)
                if [[ -n "$final_url" ]] && [[ "$final_url" != "$dl" ]]; then
                    echo "$final_url"
                    return 0
                fi
                echo "$dl"
                return 0
            fi
            
            # Try AJAX endpoint for dynamic download
            local xid
            xid=$(echo "$response" | grep -oP 'xid\s*=\s*"([^"]+)"' | head -1 | cut -d'"' -f2)
            
            if [[ -n "$xid" ]]; then
                local app_path
                app_path="${url%%/download*}/"
                local endpoint="https://apkcombo.com${app_path}${xid}/dl"
                
                local ajax_response
                ajax_response=$(curl -sL -X POST "$endpoint" \
                    -H "User-Agent: Mozilla/5.0" \
                    -H "X-Requested-With: XMLHttpRequest" \
                    -H "Referer: $url" \
                    -d "package_name=${package}&version=" 2>/dev/null || true)
                
                if [[ -n "$ajax_response" ]]; then
                    local variant_link
                    variant_link=$(echo "$ajax_response" | grep -oP 'class="variant"[^>]*href="([^"]+)"' | head -1 | cut -d'"' -f2)
                    
                    if [[ -n "$variant_link" ]]; then
                        echo "https://apkcombo.com${variant_link}"
                        return 0
                    fi
                fi
            fi
        fi
    done
    
    return 1
}
