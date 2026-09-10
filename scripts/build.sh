#!/usr/bin/env bash
# Main build entry point (bash pipeline, run via mise + just)
# Uses mise-installed tools: gh, jq, java, curl, etc.

set -euo pipefail

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/builder.sh"
source "$SCRIPT_DIR/lib/github-helpers.sh"
source "$SCRIPT_DIR/lib/downloader.sh"

# Logging setup
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
log_info() { log "INFO: $*"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }

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
        
        # Download CLI (ReVanced CLI)
        local cli_release
        cli_release=$(detect_github_release "revanced" "revanced-cli" "latest")
        echo "$cli_release" | jq -c '.assets[]? | select(.name | endswith(".jar") and (contains("cli"))) | select(.name | endswith(".asc") | not)' | while read -r asset; do
            local url
            url=$(echo "$asset" | jq -r '.browser_download_url')
            download_resource "$url"
            log_info "Downloaded ReVanced CLI"
            break
        done
        
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
        
        echo "$release" | jq -c '.assets[]? | select(.name | endswith(".asc") | not)' | while read -r asset; do
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
            elif [[ "$asset_name" == *.apk ]] || [[ "$asset_name" == *.apkm ]] || [[ "$asset_name" == *.jar ]] || [[ "$asset_name" == *.xapk ]]; then
                download_resource "$asset_url"
            fi
        done
    done
}

# Download platform-specific APK
download_platform() {
    local app_name="$1"
    local platform="$2"
    local cli="$3"
    local patches="$4"
    local arch="${5:-}"
    local override_version="${6:-}"
    
    local config_file="apps/${platform}/${app_name}.json"
    local config
    
    if [[ -f "$config_file" ]]; then
        config=$(cat "$config_file")
    else
        # Fallback: search other platforms
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
                    config=$(jq -n \
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
                        }')
                    log_info "Synthesized ${platform} config for ${app_name} from ${other_platform}"
                    break
                fi
            fi
        done
    fi
    
    if [[ -z "$config" ]] || [[ -z "$(echo "$config" | jq -r '.package // empty')" ]]; then
        log_error "Config file not found for ${app_name} on ${platform}"
        return 1
    fi
    
    # Override arch if specified
    if [[ -n "$arch" ]] && [[ "$arch" != "universal" ]]; then
        config=$(echo "$config" | jq --arg arch "$arch" '.arch = $arch')
    elif [[ -z "$(echo "$config" | jq -r '.arch // empty')" ]]; then
        config=$(echo "$config" | jq --arg arch "${arch:-universal}" '.arch = $arch')
    fi
    
    # Get platform module functions
    case "$platform" in
        apkmirror) source "$SCRIPT_DIR/lib/platforms/apkmirror.sh" ;;
        apkpure) source "$SCRIPT_DIR/lib/platforms/apkpure.sh" ;;
        uptodown) source "$SCRIPT_DIR/lib/platforms/uptodown.sh" ;;
        aptoide) source "$SCRIPT_DIR/lib/platforms/aptoide.sh" ;;
        github) source "$SCRIPT_DIR/lib/platforms/github.sh" ;;
        apkcombo) source "$SCRIPT_DIR/lib/platforms/apkcombo.sh" ;;
        *) log_error "Unknown platform: $platform"; return 1 ;;
    esac
    
    # Build candidate versions list
    local pinned
    pinned=$(echo "$config" | jq -r '.version // ""' | tr -d '[:space:]')
    
    local candidates=()
    if [[ -n "$override_version" ]]; then
        candidates+=("$override_version")
    elif [[ -n "$pinned" ]]; then
        candidates+=("$pinned")
    else
        # Get supported versions from CLI
        local cli_versions
        cli_versions=$(get_supported_versions "$(echo "$config" | jq -r '.package')" "$cli" "$patches")
        candidates+=("$cli_versions")
        
        # Add latest from platform
        local latest
        latest=$(get_latest_version "$app_name" "$config")
        if [[ -n "$latest" ]] && [[ ! " ${candidates[*]} " =~ [[:space:]"${latest}"[:space:]] ]]; then
            candidates+=("$latest")
        fi
    fi
    
    # Try each candidate
    local last_error=""
    for version in "${candidates[@]}"; do
        [[ -z "$version" ]] && continue
        
        local download_link
        download_link=$(get_download_link "$version" "$app_name" "$config")
        
        if [[ -z "$download_link" ]]; then
            last_error="No download link found for ${app_name} version ${version}"
            continue
        fi
        
        local filepath
        if filepath=$(download_resource "$download_link" 2>/dev/null); then
            echo "$filepath"
            echo "$version"
            echo "${candidates[*]}"
            return 0
        else
            last_error="Failed to download ${app_name} version ${version}"
        fi
    done
    
    log_error "$last_error"
    return 1
}

# Main entry
main() {
    local cmd="${1:-build}"
    
    case "$cmd" in
        build)
            local app_name="${APP_NAME:-}"
            local source="${SOURCE:-}"
            local arch="${ARCH:-universal}"
            
            if [[ -z "$app_name" ]] || [[ -z "$source" ]]; then
                log_error "APP_NAME and SOURCE environment variables required"
                exit 1
            fi
            
            # Download required resources
            detect_release "$source"
            
            # Download the APK from the appropriate platform
            # CLI/PATCHES are optional pre-set tool paths; detect_release downloads them otherwise
            local cli="${CLI:-}"
            local patches="${PATCHES:-}"
            download_platform "$app_name" "$source" "$cli" "$patches" "$arch"
            ;;
            
        download)
            local source="${1:-}"
            if [[ -z "$source" ]]; then
                log_error "Source name required"
                exit 1
            fi
            detect_release "$source"
            ;;
            
        *)
            log_error "Unknown command: $cmd"
            echo "Usage: $0 {build|download} [args...]"
            exit 1
            ;;
    esac
}

main "$@"
