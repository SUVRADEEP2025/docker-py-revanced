#!/usr/bin/env bash
# GitHub API helpers (bash)

# GH token setup
get_gh_token() {
    echo "${GITHUB_TOKEN:-${GH_TOKEN:-}}"
}

# Make GitHub API request
gh_api() {
    local endpoint="$1"
    local token
    token=$(get_gh_token)
    
    if [[ -n "$token" ]]; then
        gh api "$endpoint" --jq '.' 2>/dev/null || \
        curl -sL -H "Authorization: Bearer $token" "https://api.github.com/$endpoint"
    else
        gh api "$endpoint" --jq '.' 2>/dev/null || \
        curl -sL "https://api.github.com/$endpoint"
    fi
}

# Get latest release for a repo
detect_github_release() {
    local user="$1"
    local repo="$2"
    local tag="${3:-latest}"
    local token
    token=$(get_gh_token)
    
    local api_url="repos/${user}/${repo}/releases"
    
    case "$tag" in
        latest)
            api_url="${api_url}/latest"
            ;;
        ""|dev|prerelease)
            api_url="${api_url}?per_page=10"
            ;;
        *)
            api_url="${api_url}/tags/${tag}"
            ;;
    esac
    
    local response
    response=$(gh_api "$api_url")
    
    if [[ -z "$response" ]] || [[ "$response" == "null" ]]; then
        # Fallback for repos with only prereleases
        if [[ "$tag" == "latest" ]]; then
            response=$(gh_api "repos/${user}/${repo}/releases?per_page=10")
            if [[ -n "$response" ]]; then
                # Pick most recent
                response=$(echo "$response" | jq 'sort_by(.created_at) | last')
            fi
        fi
    fi
    
    if [[ "$tag" == "" ]]; then
        response=$(echo "$response" | jq 'sort_by(.created_at) | last')
    elif [[ "$tag" == "dev" ]]; then
        response=$(echo "$response" | jq '[.[] | select(.tag_name | test("dev"; "i"))] | sort_by(.created_at) | last')
    elif [[ "$tag" == "prerelease" ]]; then
        response=$(echo "$response" | jq '[.[] | select(.prerelease == true)] | sort_by(.created_at) | last')
    fi
    
    echo "$response"
}

# Get release assets
get_release_assets() {
    local release_json="$1"
    echo "$release_json" | jq -c '.assets[]? | select(.name != null)'
}

# Fetch JSON from URL (best-effort)
fetch_json() {
    local url="$1"
    local headers="${2:-}"
    
    if [[ -n "$headers" ]]; then
        curl -sL -H "$headers" "$url"
    else
        curl -sL "$url"
    fi
}

# Extract filename from Content-Disposition header
extract_filename_from_headers() {
    local headers="$1"
    local fallback_url="${2:-}"
    
    local filename
    filename=$(echo "$headers" | grep -i 'Content-Disposition' | sed -n 's/.*filename\*?="\?\([^";\n]*\)"\?.*/\1/p' | head -1)
    
    if [[ -z "$filename" ]] && [[ -n "$fallback_url" ]]; then
        filename=$(basename "$fallback_url" | sed 's/.*\///')
    fi
    
    echo "${filename:-downloaded-file}"
}

# Normalize version for comparison
normalize_version() {
    local version="$1"
    # Extract numeric parts: 6.6 -> 6 6, 6.6 build 002 -> 6 6 2, 32.30.0(1575420) -> 32 30 0 1575420
    local cleaned
    cleaned=$(echo "$version" | sed 's/[^0-9.]//g' | tr '.' ' ')
    echo "$cleaned"
}

# Compare two versions, return 0 if $1 > $2
version_greater_than() {
    local v1="$1"
    local v2="$2"
    
    local n1 n2
    n1=$(normalize_version "$v1" | awk '{for(i=1;i<=NF;i++) printf "%010d", $i}')
    n2=$(normalize_version "$v2" | awk '{for(i=1;i<=NF;i++) printf "%010d", $i}')
    
    [[ "$n1" > "$n2" ]]
}

# Get highest version from list
get_highest_version() {
    local versions=("$@")
    local highest=""
    
    for v in "${versions[@]}"; do
        if [[ -z "$highest" ]] || version_greater_than "$v" "$highest"; then
            highest="$v"
        fi
    done
    
    echo "$highest"
}

# Get supported versions from CLI
get_supported_versions() {
    local package="$1"
    local cli="$2"
    local patches="$3"
    
    local cli_name
    cli_name=$(basename "$cli" | tr '[:upper:]' '[:lower:]')
    
    local cmd=()
    
    if [[ "$cli_name" == *"morphe"* ]]; then
        cmd=(java -jar "$cli" list-versions -f "$package" --patches "$patches")
    elif [[ "$cli_name" == *"revanced-cli-6"* ]] || [[ "$cli_name" == *"revanced-cli-7"* ]] || [[ "$cli_name" == *"revanced-cli-8"* ]]; then
        cmd=(java -jar "$cli" list-versions -p "$patches" -b -f "$package")
    else
        cmd=(java -jar "$cli" list-versions -f "$package" "$patches")
    fi
    
    local output
    output=$("${cmd[@]}" 2>/dev/null || true)
    
    if [[ -z "$output" ]]; then
        echo ""
        return
    fi
    
    # Parse version lines (skip header lines)
    local versions=()
    while IFS= read -r line; do
        # Skip header/error lines
        if [[ "$line" =~ ^(usage|error|unmatched) ]] || [[ "$line" == *"Any"* ]]; then
            continue
        fi
        
        # Extract version (first word, must start with digit)
        local ver
        ver=$(echo "$line" | awk '{print $1}')
        
        if [[ -n "$ver" ]] && [[ "$ver" =~ ^[0-9] ]]; then
            # Check for "build XXX" suffix
            if [[ "$line" =~ build[[:space:]]+([0-9]+) ]]; then
                local build_num="${BASH_REMATCH[1]}"
                ver="${ver} build ${build_num}"
            fi
            versions+=("$ver")
        fi
    done <<< "$output"
    
    # Sort highest to lowest
    if [[ ${#versions[@]} -gt 0 ]]; then
        # Simple sort by normalized version
        local sorted=()
        for v in "${versions[@]}"; do
            sorted+=("$v")
        done
        
        # Bubble sort (simple but works for small lists)
        local n=${#sorted[@]}
        for ((i=0; i<n; i++)); do
            for ((j=i+1; j<n; j++)); do
                if version_greater_than "${sorted[j]}" "${sorted[i]}"; then
                    local tmp="${sorted[i]}"
                    sorted[i]="${sorted[j]}"
                    sorted[j]="$tmp"
                fi
            done
        done
        
        printf '%s\n' "${sorted[@]}"
    fi
}

# Validate GitHub auth
validate_github_auth() {
    local token
    token=$(get_gh_token)
    
    if [[ -z "$token" ]]; then
        echo "GitHub auth validation failed: missing GITHUB_TOKEN/GH_TOKEN" >&2
        return 1
    fi
    
    local rate_limit
    rate_limit=$(gh_api "rate_limit" 2>/dev/null | jq -r '.resources.core.limit // "unknown"')
    
    if [[ -z "$rate_limit" ]]; then
        echo "GitHub auth validation failed: gh api rate_limit failed" >&2
        return 1
    fi
    
    echo "GitHub auth OK: Authenticated via API (rate limit: ${rate_limit} hourly)"
    return 0
}
