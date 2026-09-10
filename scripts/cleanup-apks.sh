#!/usr/bin/env bash
# Delete superseded APK assets from a release

set -euo pipefail

RELEASE_TAG="${RELEASE:-latest}"
KEEP_FILE="${KEEP_FILE:-}"
DRY_RUN="${DRY_RUN:-false}"

# APK filename pattern: {app}-{arch}-{name}-v{version}.apk
# Version marker must have digits after -v to avoid matching arch tokens like v8a
VERSION_MARKER_REGEX='-v[0-9][\d.()+\-]*\.apk$'

get_gh_token() {
    echo "${GITHUB_TOKEN:-${GH_TOKEN:-}}"
}

# Get release assets (only APKs)
get_release_assets() {
    local owner_repo="$1"
    local token
    token=$(get_gh_token)
    
    if [[ -z "$owner_repo" ]] || [[ "$owner_repo" != */* ]]; then
        echo "[]"
        return
    fi
    
    local owner name
    owner=${owner_repo%/*}
    name=${owner_repo#*/}
    
    local assets
    assets=$(GH_TOKEN="$token" gh api "repos/${owner}/${name}/releases/tags/${RELEASE_TAG}" \
        --jq '[.assets[]? | select(.name | endswith(".apk")) | {name, id}]' 2>/dev/null || echo "[]")
    
    echo "$assets"
}

# Extract identity prefix from APK filename
# youtube-arm64-v8a-morphe-v2.5.0.apk -> youtube-arm64-v8a-morphe
identity_prefix() {
    local apk_name="$1"
    
    # Find the version marker (last -v followed by version)
    if [[ "$apk_name" =~ $VERSION_MARKER_REGEX ]]; then
        # Extract everything before the -v
        local prefix="${apk_name%%-v*}"
        echo "$prefix"
    else
        # Fallback: use stem without extension
        echo "${apk_name%.apk}"
    fi
}

# Load keep set from file
load_keep_set() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo "()"
        return
    fi
    
    # Read file and create JSON array
    local names=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && names+=("\"$line\"")
    done < "$file"
    
    printf '%s\n' "${names[*]:-}" | jq -s '.'
}

# Delete asset by name using gh release delete-asset
delete_asset_by_name() {
    local release="$1"
    local name="$2"
    local token
    token=$(get_gh_token)
    
    GH_TOKEN="$token" gh release delete-asset "$release" "$name" --yes 2>/dev/null && return 0
    
    return 1
}

# Delete asset by ID using API
delete_asset_by_id() {
    local name="$1"
    local asset_id="$2"
    local token
    token=$(get_gh_token)
    
    local owner_repo="${GITHUB_REPOSITORY:-}"
    if [[ -z "$owner_repo" ]] || [[ "$owner_repo" != */* ]]; then
        echo "false:GITHUB_REPOSITORY not set"
        return 1
    fi
    
    local owner name_repo
    owner=${owner_repo%/*}
    name_repo=${owner_repo#*/}
    
    GH_TOKEN="$token" gh api -X DELETE "repos/${owner}/${name_repo}/releases/assets/${asset_id}" 2>/dev/null && return 0
    
    return 1
}

# Delete a single asset (tries delete-asset first, then API fallback)
delete_asset() {
    local release="$1"
    local name="$2"
    local asset_id="${3:-}"
    
    if delete_asset_by_name "$release" "$name"; then
        return 0
    fi
    
    echo "  ⚠️  delete-asset failed for $name" >&2
    
    if [[ -n "$asset_id" ]]; then
        if delete_asset_by_id "$name" "$asset_id"; then
            return 0
        fi
        echo "  ⚠️  API fallback failed for $name (id=$asset_id)" >&2
    else
        echo "  ⚠️  no asset id available for $name; API fallback skipped" >&2
    fi
    
    return 1
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --release)
                RELEASE_TAG="$2"
                shift 2
                ;;
            --keep-file)
                KEEP_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                echo "Unknown argument: $1"
                echo "Usage: $0 --keep-file <file> [--release <tag>] [--dry-run]"
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$KEEP_FILE" ]]; then
        echo "Error: --keep-file is required"
        exit 1
    fi
    
    local owner_repo="${GITHUB_REPOSITORY:-}"
    
    # Load keep set
    local keep_json
    keep_json=$(load_keep_set "$KEEP_FILE")
    
    # Build keep set as simple list
    local keep_names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && keep_names+=("$name")
    done < <(echo "$keep_json" | jq -r '.[]?' 2>/dev/null || true)
    
    # Get release assets
    local assets_json
    assets_json=$(get_release_assets "$owner_repo")
    
    if [[ "$(echo "$assets_json" | jq 'length')" -eq 0 ]]; then
        echo "No existing APK assets to clean up."
        exit 0
    fi
    
    # Build keep prefixes set
    local keep_prefixes=()
    for name in "${keep_names[@]:-}"; do
        [[ -z "$name" ]] && continue
        keep_prefixes+=("$(identity_prefix "$name")")
    done
    
    # Find assets to delete
    local to_delete=()
    while IFS= read -r asset; do
        [[ -z "$asset" ]] && continue
        
        local name asset_id
        name=$(echo "$asset" | jq -r '.name // ""')
        asset_id=$(echo "$asset" | jq -r '.id // ""')
        
        [[ -z "$name" ]] && continue
        [[ " ${keep_names[*]:-} " =~ [[:space:]"${name}"[:space:]] ]] && continue
        
        local prefix
        prefix=$(identity_prefix "$name")
        
        local is_keep_prefix=false
        for kp in "${keep_prefixes[@]:-}"; do
            if [[ "$kp" == "$prefix" ]]; then
                is_keep_prefix=true
                break
            fi
        done
        
        $is_keep_prefix && to_delete+=("$asset")
    done < <(echo "$assets_json" | jq -c '.[]? // empty')
    
    if [[ ${#to_delete[@]} -eq 0 ]]; then
        echo "No superseded APK assets found."
        exit 0
    fi
    
    echo "Found ${#to_delete[@]} superseded APK asset(s) to remove:"
    
    local deleted=0
    for asset in "${to_delete[@]:-}"; do
        [[ -z "$asset" ]] && continue
        
        local name asset_id
        name=$(echo "$asset" | jq -r '.name')
        asset_id=$(echo "$asset" | jq -r '.id // ""')
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [dry-run] would delete: $name"
        else
            if delete_asset "$RELEASE_TAG" "$name" "$asset_id"; then
                echo "  🗑️  deleted: $name"
                ((deleted++))
            fi
        fi
    done
    
    local action="would delete"
    [[ "$DRY_RUN" != "true" ]] && action="deleted"
    echo "Done. $action $deleted superseded asset(s)."
    
    exit 0
}

main "$@"
