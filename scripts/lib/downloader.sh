#!/usr/bin/env bash
# Download helper - uses apkeep for APK downloads where possible

set -euo pipefail

# Use LIB_DIR (not SCRIPT_DIR) so sourcing this library doesn't clobber the caller's SCRIPT_DIR
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/github-helpers.sh"

# Download a resource via HTTP, using apkeep for APK URLs when available
download_resource() {
    local url="$1"
    local name="${2:-}"
    
    # For APK files, use apkeep which handles store-specific download logic
    if [[ "$url" == *.apk ]] || [[ "$url" == *.apkm ]] || [[ "$url" == *.xapk ]] || [[ "$url" == *.apks ]]; then
        if command -v apkeep &>/dev/null; then
            if [[ -z "$name" ]]; then
                name="$(basename "$url" | sed 's/[?].*$//')"
            fi
            
            # apkeep can download directly from APKCombo, Aptoide, etc.
            # For GitHub releases, we still use curl as apkeep doesn't support that
            if [[ "$url" == github.com* ]] || [[ "$url" == */releases/*download/* ]]; then
                # GitHub release assets - use curl
                download_with_curl "$url" "$name"
            else
                # APK store URLs - use apkeep
                if apkeep "$url" -d . 2>&1; then
                    # apkeep downloads to current dir with original filename
                    local apk_path
                    apk_path=$(find . -maxdepth 1 \( -name '*.apk' -o -name '*.apkm' -o -name '*.xapk' -o -name '*.apks' \) | head -1)
                    if [[ -n "$apk_path" ]] && [[ "$apk_path" != "$name" ]]; then
                        mv "$apk_path" "$name" 2>/dev/null || true
                    fi
                    echo "$name"
                    return 0
                else
                    # apkeep failed, fall back to curl
                    log_warn "apkeep failed for $url, falling back to curl"
                    download_with_curl "$url" "$name"
                fi
            fi
        else
            # apkeep not available, use curl
            download_with_curl "$url" "$name"
        fi
    else
        # Non-APK files (JAR, MPP, etc.) - use curl
        download_with_curl "$url" "$name"
    fi
}

# Download using curl with progress info
download_with_curl() {
    local url="$1"
    local name="${2:-}"
    
    if [[ -z "$name" ]]; then
        # Extract filename from URL
        name=$(basename "$url" | sed 's/[?].*$//')
    fi
    
    log_info "Downloading: $url -> $name"
    
    # Get content length
    local total_size=0
    local headers
    headers=$(curl -sI "$url")
    total_size=$(echo "$headers" | grep -i 'Content-Length' | awk '{print $2}' | tr -d '\r' || echo "0")
    [[ -z "$total_size" ]] && total_size=0
    
    # Download with progress
    local downloaded=0
    local tmpfile
    tmpfile=$(mktemp)
    
    if curl -sL "$url" -o "$tmpfile" 2>/dev/null; then
        downloaded=$(stat -c%s "$tmpfile" 2>/dev/null || stat -f%z "$tmpfile" 2>/dev/null || echo "0")
        mv "$tmpfile" "$name"
        
        log_info "URL: $url [${downloaded}/${total_size}] -> \"$name\" [1]"
        echo "$name"
        return 0
    else
        rm -f "$tmpfile"
        return 1
    fi
}

# Download APK using apkeep specifically (for store URLs)
download_apk_with_apkeep() {
    local url="$1"
    local output_name="${2:-}"
    
    if ! command -v apkeep &>/dev/null; then
        log_warn "apkeep not available, falling back to curl"
        download_with_curl "$url" "$output_name"
        return $?
    fi
    
    log_info "Using apkeep for: $url"
    
    # apkeep supports these store types natively:
    # - APKPure: apkeep --apkpure <url>
    # - Aptoide: apkeep --aptoide <url>
    # - APKMirror: apkeep --apkmirror <url>
    # - Uptodown: apkeep --uptodown <url>
    # - F-Droid: apkeep --fdroid <url>
    
    local store_type=""
    case "$url" in
        *apkpure.com*|*apkpure.net*)
            store_type="apkpure"
            ;;
        *aptoide.com*)
            store_type="aptoide"
            ;;
        *apkmirror.com*)
            store_type="apkmirror"
            ;;
        *uptodown.com*)
            store_type="uptodown"
            ;;
        *fdroid.org*)
            store_type="fdroid"
            ;;
    esac
    
    local tmpdir
    tmpdir=$(mktemp -d)
    
    if [[ -n "$store_type" ]]; then
        # Use apkeep with explicit store type
        if [[ -n "$output_name" ]]; then
            apkeep --"$store_type" "$url" -d "$tmpdir" 2>&1 && {
                local downloaded
                downloaded=$(find "$tmpdir" -type f \( -name '*.apk' -o -name '*.apkm' -o -name '*.xapk' \) | head -1)
                if [[ -n "$downloaded" ]]; then
                    cp "$downloaded" "$output_name"
                    rm -rf "$tmpdir"
                    log_info "apkeep download success: $output_name"
                    echo "$output_name"
                    return 0
                fi
            }
        else
            apkeep --"$store_type" "$url" -d "$tmpdir" 2>&1 && {
                local downloaded
                downloaded=$(find "$tmpdir" -type f \( -name '*.apk' -o -name '*.apkm' -o -name '*.xapk' \) | head -1)
                if [[ -n "$downloaded" ]]; then
                    local basename_url
                    basename_url=$(basename "$url" | sed 's/[?].*$//')
                    mv "$downloaded" "${basename_url%.*}.apk" 2>/dev/null || true
                    cp "$downloaded" . 2>/dev/null || true
                    rm -rf "$tmpdir"
                    echo "$downloaded"
                    return 0
                fi
            }
        fi
    else
        # Generic download (e.g., direct APK link)
        if [[ -n "$output_name" ]]; then
            apkeep "$url" -d "$tmpdir" 2>&1 && {
                local downloaded
                downloaded=$(find "$tmpdir" -type f \( -name '*.apk' -o -name '*.apkm' -o -name '*.xapk' \) | head -1)
                if [[ -n "$downloaded" ]]; then
                    cp "$downloaded" "$output_name"
                    rm -rf "$tmpdir"
                    echo "$output_name"
                    return 0
                fi
            }
        else
            apkeep "$url" -d "$tmpdir" 2>&1 && {
                local downloaded
                downloaded=$(find "$tmpdir" -type f \( -name '*.apk' -o -name '*.apkm' -o -name '*.xapk' \) | head -1)
                if [[ -n "$downloaded" ]]; then
                    mv "$downloaded" . 2>/dev/null || true
                    rm -rf "$tmpdir"
                    echo "$downloaded"
                    return 0
                fi
            }
        fi
    fi
    
    rm -rf "$tmpdir"
    
    # apkeep failed or not applicable, fall back to curl
    log_warn "apkeep failed for $url, falling back to curl"
    download_with_curl "$url" "$output_name"
}

# Download APK from APKMirror using apkeep
download_from_apkmirror() {
    local app_slug="$1"  # e.g., "org/com-app"
    local version="$2"
    local arch="${3:-universal}"
    local dpi="${4:-nodpi}"
    local output_name="${5:-}"
    
    # apkeep can download from APKMirror directly
    # Format: apkeep --apkmirror "https://www.apkmirror.com/apk/org/name/version-arch-dpi/file.apk"
    
    local url="https://www.apkmirror.com/apk/${app_slug}/${version}-${arch}-${dpi}/"
    
    if [[ -n "$output_name" ]]; then
        download_apk_with_apkeep "$url" "$output_name"
    else
        download_apk_with_apkeep "$url"
    fi
}

# Download APK from APKPure using apkeep
download_from_apkpure() {
    local app_name="$1"
    local package="$2"
    local version="$3"
    local output_name="${4:-}"
    
    # APKPure URL format
    local url="https://apkpure.net/${app_name}/${package}/download/${version}"
    
    if [[ -n "$output_name" ]]; then
        download_apk_with_apkeep "$url" "$output_name"
    else
        download_apk_with_apkeep "$url"
    fi
}

# Download APK from Uptodown using apkeep
download_from_uptodown() {
    local app_slug="$1"
    local version="$2"
    local output_name="${3:-}"
    
    local url="https://uptodown.com/${app_slug}/android/${version}/"
    
    if [[ -n "$output_name" ]]; then
        download_apk_with_apkeep "$url" "$output_name"
    else
        download_apk_with_apkeep "$url"
    fi
}

# Download APK from Aptoide using apkeep (apkeep has native Aptoide support)
download_from_aptoide() {
    local package="$1"
    local version="$2"
    local output_name="${3:-}"
    
    # Aptoide package URL
    local url="https://en.aptoide.com/app/${package}"
    
    if [[ -n "$output_name" ]]; then
        download_apk_with_apkeep "$url" "$output_name"
    else
        download_apk_with_apkeep "$url"
    fi
}

log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
