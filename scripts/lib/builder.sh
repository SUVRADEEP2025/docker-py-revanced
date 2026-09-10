#!/usr/bin/env bash
# Builder library - shared build functions

set -euo pipefail

# Use LIB_DIR (not SCRIPT_DIR) so sourcing this library doesn't clobber the caller's SCRIPT_DIR
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/github-helpers.sh"
source "$LIB_DIR/downloader.sh"

# Logging
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
log_info() { log "INFO: $*"; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG: $*" || true; }

# Get app config from JSON file
get_app_config() {
    local app_name="$1"
    local platform="${2:-apkmirror}"
    
    local config_file="apps/${platform}/${app_name}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
        return 0
    fi
    
    # Fallback: search other platform config directories
    for other_platform in apkmirror apkpure uptodown aptoide github apkcombo; do
        if [[ "$other_platform" == "$platform" ]]; then
            continue
        fi
        local other_path="apps/${other_platform}/${app_name}.json"
        if [[ -f "$other_path" ]]; then
            local other_cfg
            other_cfg=$(cat "$other_path")
            local pkg
            pkg=$(echo "$other_cfg" | jq -r '.package // empty')
            if [[ -n "$pkg" ]]; then
                # Synthesize a config for this platform
                jq -n \
                    --arg name "$(echo "$other_cfg" | jq -r '.name // $app_name // ""')" \
                    --arg package "$pkg" \
                    --arg version "$(echo "$other_cfg" | jq -r '.version // ""')" \
                    --arg arch "$(echo "$other_cfg" | jq -r '.arch // "universal"')" \
                    --arg type "$(echo "$other_cfg" | jq -r '.type // "APK"')" \
                    --arg dpi "$(echo "$other_cfg" | jq -r '.dpi // "nodpi"')" \
                    --arg org "$(echo "$other_cfg" | jq -r '.org // $app_name // ""')" \
                    '{
                        name: $name,
                        package: $package,
                        version: $version,
                        arch: $arch,
                        type: $type,
                        dpi: $dpi,
                        org: $org
                    }'
                log_info "Synthesized ${platform} config for ${app_name} from ${other_platform}"
                return 0
            fi
        fi
    done
    
    return 1
}

# Parse JSON config value
config_get() {
    local config="$1"
    local key="$2"
    echo "$config" | jq -r ".${key} // empty"
}

# Detect release from source config
detect_release() {
    local source="$1"
    local source_file="sources/${source}.json"
    
    if [[ ! -f "$source_file" ]]; then
        log_error "Source file not found: $source_file"
        return 1
    fi
    
    local data
    data=$(cat "$source_file")
    
    # Handle bundle format
    if echo "$data" | jq -e 'has("bundle_url")' >/dev/null 2>&1; then
        local bundle_url
        bundle_url=$(echo "$data" | jq -r '.bundle_url')
        local name
        name=$(echo "$data" | jq -r '.name // "bundle-patches"')
        
        log_info "Downloading bundle from ${bundle_url}"
        
        # Download bundle JSON
        local bundle_data
        bundle_data=$(gh api "$bundle_url" --jq '.' 2>/dev/null || curl -sL "$bundle_url")
        
        # Download patches
        if echo "$bundle_data" | jq -e 'has("patches")' >/dev/null 2>&1; then
            echo "$bundle_data" | jq -c '.patches[]? | select(has("url"))' | while read -r patch; do
                local url name
                url=$(echo "$patch" | jq -r '.url')
                name=$(echo "$patch" | jq -r '.name // "unknown"')
                download_resource "$url"
                log_info "Downloaded patch: $name"
            done
        fi
        
        # Download integrations
        if echo "$bundle_data" | jq -e 'has("integrations")' >/dev/null 2>&1; then
            echo "$bundle_data" | jq -c '.integrations[]? | select(has("url"))' | while read -r integration; do
                local url name
                url=$(echo "$integration" | jq -r '.url')
                name=$(echo "$integration" | jq -r '.name // "unknown"')
                download_resource "$url"
                log_info "Downloaded integration: $name"
            done
        fi
        
        # Download CLI (ReVanced CLI) - use apkeep for JAR if possible, otherwise curl
        local cli_release
        cli_release=$(detect_github_release "revanced" "revanced-cli" "latest")
        
        if [[ -n "$cli_release" ]] && [[ "$cli_release" != "null" ]]; then
            local cli_jar
            cli_jar=$(echo "$cli_release" | jq -r '.assets[]? | select(.name | endswith(".jar") and (contains("cli"))) | .browser_download_url' | head -1)
            if [[ -n "$cli_jar" ]]; then
                download_resource "$cli_jar"
                log_info "Downloaded ReVanced CLI"
            fi
        fi
        
        return 0
    fi
    
    # Handle old list format
    local name
    name=$(echo "$data" | jq -r '.[0].name // ""')
    
    # Process each repo entry
    echo "$data" | jq -c '.[]? | select(.user and .repo)' | while read -r entry; do
        local user repo tag
        user=$(echo "$entry" | jq -r '.user')
        repo=$(echo "$entry" | jq -r '.repo')
        tag=$(echo "$entry" | jq -r '.tag // "latest"')
        
        local release
        release=$(detect_github_release "$user" "$repo" "$tag")
        
        if [[ -n "$release" ]] && [[ "$release" != "null" ]]; then
            echo "$release" | jq -c '.assets[]? | select(.name != null and (endswith(".asc") | not))' | while read -r asset; do
                local asset_name asset_url
                asset_name=$(echo "$asset" | jq -r '.name')
                asset_url=$(echo "$asset" | jq -r '.browser_download_url')
                
                local entry_name
                entry_name=$(echo "$entry" | jq -r '(.repo // .project // .name // "") | ascii_downcase')
                
                # Morphe-specific filtering
                if [[ "$entry_name" == *"morphe-patches"* ]] || [[ "$entry_name" == *"morphe-cli"* ]]; then
                    if [[ "$asset_name" == *.mpp ]] || [[ "$asset_name" == *.jar ]]; then
                        download_resource "$asset_url"
                    fi
                else
                    # Download APK/JAR files
                    if [[ "$asset_name" == *.apk ]] || [[ "$asset_name" == *.apkm ]] || [[ "$asset_name" == *.jar ]] || [[ "$asset_name" == *.xapk ]]; then
                        download_resource "$asset_url"
                    fi
                fi
            done
        fi
    done
}

# Download APKEditor
download_apkeditor() {
    local max_retries=3
    
    for ((attempt=0; attempt<max_retries; attempt++)); do
        local release
        release=$(detect_github_release "REAndroid" "APKEditor" "latest")
        
        if [[ -n "$release" ]] && [[ "$release" != "null" ]]; then
            local jar_url
            jar_url=$(echo "$release" | jq -r '.assets[]? | select(.name | startswith("APKEditor") and endswith(".jar")) | .browser_download_url' | head -1)
            
            if [[ -n "$jar_url" ]]; then
                download_resource "$jar_url"
                return 0
            fi
        fi
        
        if [[ $attempt -lt $((max_retries - 1)) ]]; then
            log_warn "APKEditor download attempt $((attempt + 1)) failed, retrying..."
            sleep 2
        fi
    done
    
    log_error "Failed to download APKEditor after $max_retries attempts"
    return 1
}

# Check APK integrity
check_apk_integrity() {
    local apk_path="$1"
    
    if [[ ! -f "$apk_path" ]] || [[ ! -s "$apk_path" ]]; then
        return 1
    fi
    
    # Check if it's a valid zip (APK is a zip)
    if command -v unzip &>/dev/null; then
        unzip -t "$apk_path" >/dev/null 2>&1
        return $?
    fi
    
    # Fallback: check magic bytes (PK\x03\x04)
    local magic
    magic=$(od -An -tx1 -N4 "$apk_path" 2>/dev/null | tr -d ' \n')
    if [[ "$magic" == "504b0304" ]]; then
        return 0
    fi
    
    return 1
}

# Extract version from APK filename
extract_version_from_filename() {
    local filename="$1"
    
    # APK names: {app}-{arch}-{name}-v{version}.apk
    # Extract the version after the last -v that's followed by a dotted version
    local version
    version=$(echo "$filename" | sed -n 's/.*-v\([0-9][0-9.]*[a-zA-Z0-9.+\-() ]*\)\.apk$/\1/p')
    
    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi
    
    echo ""
}

# Detect architecture from filename
detect_arch_from_filename() {
    local filename="$1"
    local default="${2:-universal}"
    
    local lower_name
    lower_name=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
    
    case "$lower_name" in
        *arm64-v8a*)
            echo "arm64-v8a"
            return 0
            ;;
        *armeabi-v7a*)
            echo "armeabi-v7a"
            return 0
            ;;
        *x86_64*|*x86-64*)
            echo "x86_64"
            return 0
            ;;
        *x86*)
            echo "x86"
            return 0
            ;;
        *universal*)
            echo "universal"
            return 0
            ;;
    esac
    
    echo "$default"
}
