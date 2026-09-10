#!/usr/bin/env bash
# GitHub platform downloader - uses gh CLI and GitHub API

get_latest_version() {
    local app_name="$1"
    local config="$2"
    
    local repo tag
    repo=$(echo "$config" | jq -r '.repo // ""')
    tag=$(echo "$config" | jq -r '.tag // ""')
    
    if [[ -z "$repo" ]] || [[ -z "$tag" ]]; then
        log_error "Missing 'repo' or 'tag' in github config for $app_name"
        return 1
    fi
    
    # Get release from GitHub API
    local release
    release=$(gh api "repos/${repo}/releases/tags/${tag}" --jq '.' 2>/dev/null || true)
    
    if [[ -z "$release" ]] || [[ "$release" == "null" ]]; then
        return 1
    fi
    
    # Extract version from asset names (format: package-version-arch.apk)
    local version
    version=$(echo "$release" | jq -r '.assets[]? | .name' | grep -oP '-\K[\d.]+-(?:arm64|armeabi|x86|universal)' | \
        cut -d'-' -f1 | sort -V | tail -1)
    
    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi
    
    return 1
}

get_download_link() {
    local version="$1"
    local app_name="$2"
    local config="$3"
    
    local repo tag arch
    repo=$(echo "$config" | jq -r '.repo // ""')
    tag=$(echo "$config" | jq -r '.tag // ""')
    arch=$(echo "$config" | jq -r '.arch // "arm64-v8a"')
    
    if [[ -z "$repo" ]] || [[ -z "$tag" ]]; then
        return 1
    fi
    
    # Get release assets
    local release
    release=$(gh api "repos/${repo}/releases/tags/${tag}" --jq '.' 2>/dev/null || true)
    
    if [[ -z "$release" ]] || [[ "$release" == "null" ]]; then
        return 1
    fi
    
    # Find matching asset
    local download_url
    download_url=$(echo "$release" | jq -r --arg v "$version" --arg a "$arch" \
        '.assets[]? | select(
            (.name | test($v; "i")) and
            (.name | endswith(".apk") or endswith(".apkm") or endswith(".xapk")) and
            (( $a == "all" or $a == "both" ) or (.name | test($a; "i")))
        ) | .browser_download_url' | head -1)
    
    if [[ -n "$download_url" ]]; then
        echo "$download_url"
        return 0
    fi
    
    # Fallback: just match version, ignore arch
    download_url=$(echo "$release" | jq -r --arg v "$version" \
        '.assets[]? | select(
            (.name | test($v; "i")) and
            (.name | endswith(".apk") or endswith(".apkm") or endswith(".xapk"))
        ) | .browser_download_url' | head -1)
    
    if [[ -n "$download_url" ]]; then
        echo "$download_url"
        return 0
    fi
    
    return 1
}
