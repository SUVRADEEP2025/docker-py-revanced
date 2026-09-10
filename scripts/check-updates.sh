#!/usr/bin/env bash
# Check for app updates (incremental build planning)
# Determines which apps need to be rebuilt based on version changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/builder.sh"
source "$SCRIPT_DIR/lib/github-helpers.sh"

# Configuration
PATCH_CONFIG="patch-config.json"
ARCH_CONFIG="arch-config.json"
SOURCES_DIR="sources"
APPS_DIR="apps"
MANIFEST_NAME="manifest.json"
RELEASE_TAG="latest"

# Force rebuild flag
FORCE_FULL="${FORCE_FULL_REBUILD:-false}"
if [[ "${FORCE_FULL,,}" == "true" ]] || [[ "${FORCE_FULL}" == "1" ]]; then
    FORCE_FULL=true
else
    FORCE_FULL=false
fi

# GITHUB_OUTPUT handling
write_gh_output() {
    local key="$1"
    local value="$2"
    local out="${GITHUB_OUTPUT:-}"
    
    if [[ -z "$out" ]]; then
        # Local execution - just print
        local preview="$value"
        if [[ ${#preview} -gt 200 ]]; then
            preview="${preview:0:200}..."
        fi
        echo "[gh-output] ${key}=${preview}"
        return
    fi
    
    # GitHub Actions - write to output file
    if [[ "$value" == *$'\n'* ]]; then
        {
            echo "${key}<<EOF_GH"
            echo "$value"
            echo "EOF_GH"
        } >> "$out"
    else
        echo "${key}=${value}" >> "$out"
    fi
}

# Run gh command with timeout
run_gh() {
    local timeout="${GH_TIMEOUT:-120}"
    
    local token
    token=$(get_gh_token)
    
    if [[ -n "$token" ]]; then
        GH_TOKEN="$token" timeout "$timeout" gh "$@" 2>&1 || true
    else
        timeout "$timeout" gh "$@" 2>&1 || true
    fi
}

# Load patch config
load_patch_config() {
    if [[ ! -f "$PATCH_CONFIG" ]]; then
        echo "[]"
        return
    fi
    
    jq -c '.patch_list[]?' "$PATCH_CONFIG" 2>/dev/null || echo "[]"
}

# Load arch config
load_arch_config() {
    if [[ ! -f "$ARCH_CONFIG" ]]; then
        echo "{}"
        return
    fi
    
    cat "$ARCH_CONFIG"
}

# Get app config version
get_app_config_version() {
    local app_name="$1"
    local config_file
    
    for platform in apkmirror apkpure uptodown aptoide; do
        config_file="${APPS_DIR}/${platform}/${app_name}.json"
        if [[ -f "$config_file" ]]; then
            jq -r '.version // ""' "$config_file" | tr -d '[:space:]'
            return
        fi
    done
    
    echo ""
}

# Get app config and platform
get_app_config_with_platform() {
    local app_name="$1"
    
    for platform in apkmirror apkpure uptodown aptoide; do
        local config_file="${APPS_DIR}/${platform}/${app_name}.json"
        if [[ -f "$config_file" ]]; then
            echo "$platform"
            cat "$config_file"
            return
        fi
    done
    
    echo "null"
}

# Fetch latest app version from store
fetch_latest_app_version() {
    local app_name="$1"
    local config platform
    
    read -r platform config < <(get_app_config_with_platform "$app_name")
    
    if [[ "$platform" == "null" ]] || [[ -z "$config" ]]; then
        echo ""
        return
    fi
    
    # Source the appropriate platform module
    local platform_script="${SCRIPT_DIR}/lib/platforms/${platform}.sh"
    if [[ -f "$platform_script" ]]; then
        # shellcheck source=lib/platforms/apkmirror.sh
        source "$platform_script"
        
        local version
        version=$(get_latest_version "$app_name" "$config" 2>/dev/null || true)
        
        if [[ -n "$version" ]]; then
            echo "$version"
            return
        fi
    fi
    
    # Fallback to APKCombo
    if [[ -f "${SCRIPT_DIR}/lib/platforms/apkcombo.sh" ]]; then
        source "${SCRIPT_DIR}/lib/platforms/apkcombo.sh"
        local version
        version=$(get_latest_version "$app_name" "$config" 2>/dev/null || true)
        if [[ -n "$version" ]]; then
            echo "$version"
            return
        fi
    fi
    
    echo ""
}

# Get source signature (for change detection)
get_source_signature() {
    local source="$1"
    local source_file="${SOURCES_DIR}/${source}.json"
    
    if [[ ! -f "$source_file" ]]; then
        echo "missing-source:${source}"
        return
    fi
    
    local data
    data=$(cat "$source_file")
    
    # Handle bundle format
    if echo "$data" | jq -e 'has("bundle_url")' >/dev/null 2>&1; then
        local bundle_url
        bundle_url=$(echo "$data" | jq -r '.bundle_url')
        
        # Fetch bundle and create signature from content
        local bundle_data
        bundle_data=$(gh api "$bundle_url" --jq '.' 2>/dev/null || curl -sL "$bundle_url" || true)
        
        if [[ -n "$bundle_data" ]]; then
            local tokens=()
            while IFS= read -r item; do
                local url name key
                url=$(echo "$item" | jq -r '.url // ""')
                name=$(echo "$item" | jq -r '.name // ""')
                key=$(echo "$item" | jq -r 'keys[0]')
                [[ -n "$url" || -n "$name" ]] && tokens+=("${key}:${name}:${url}")
            done < <(echo "$bundle_data" | jq -c '.patches[], .integrations[]? // empty')
            
            if [[ ${#tokens[@]} -gt 0 ]]; then
                printf 'bundle:%s' "$(IFS=','; echo "${tokens[*]}")" | tr ' ' '_'
                return
            fi
        fi
        
        echo "bundle:${bundle_url}@empty"
        return
    fi
    
    # Handle list format - build signature from each repo
    local parts=()
    
    while IFS= read -r entry; do
        local provider tag user repo project
        provider=$(echo "$entry" | jq -r '(.provider // "github") | ascii_downcase')
        tag=$(echo "$entry" | jq -r '.tag // "latest"')
        user=$(echo "$entry" | jq -r '.user // ""')
        repo=$(echo "$entry" | jq -r '.repo // ""')
        project=$(echo "$entry" | jq -r '.project // ""')
        
        # Skip metadata-only entries
        if [[ -z "$user" ]] && [[ -z "$repo" ]] && [[ -z "$project" ]]; then
            continue
        fi
        
        local sig identity
        if [[ "$provider" == "gitlab" ]] && [[ -n "$project" ]]; then
            identity="gitlab:${project}"
            # Get GitLab release signature
            sig=$(curl -sL "https://gitlab.com/api/v4/projects/${project//\//%2F}/releases/${tag:+${tag}}/" 2>/dev/null | \
                jq -r '.tag_name + "@" + (.released_at // .created_at // "?")' 2>/dev/null || echo "@err")
            sig="${identity}@${sig}"
        elif [[ "$provider" == "codeberg" ]] && [[ -n "$user" ]] && [[ -n "$repo" ]]; then
            identity="codeberg:${user}/${repo}"
            sig=$(curl -sL "https://codeberg.org/api/v1/repos/${user}/${repo}/releases/${tag:+${tag}}/" 2>/dev/null | \
                jq -r '.tag_name + "@" + (.published_at // "?")' 2>/dev/null || echo "@err")
            sig="${identity}@${sig}"
        elif [[ "$provider" == "github" ]] && [[ -n "$user" ]] && [[ -n "$repo" ]]; then
            identity="github:${user}/${repo}"
            # Get GitHub release signature
            local release
            release=$(detect_github_release "$user" "$repo" "$tag" 2>/dev/null || true)
            
            if [[ -n "$release" ]] && [[ "$release" != "null" ]]; then
                local tag_name published updated
                tag_name=$(echo "$release" | jq -r '.tag_name // "?"')
                published=$(echo "$release" | jq -r '.published_at // .created_at // "?"')
                updated=$(echo "$release" | jq -r '.updated_at // ""')
                
                # Build asset signature
                local asset_parts=()
                while IFS= read -r asset; do
                    local name digest updated_at size
                    name=$(echo "$asset" | jq -r '.name // ""')
                    digest=$(echo "$asset" | jq -r '.digest // ""')
                    updated_at=$(echo "$asset" | jq -r '.updated_at // ""')
                    size=$(echo "$asset" | jq -r '.size // ""')
                    
                    [[ -z "$name" ]] && continue
                    
                    local token
                    if [[ -n "$digest" ]]; then
                        token="$digest"
                    elif [[ -n "$size" ]] && [[ -n "$updated_at" ]]; then
                        token="${size}@${updated_at}"
                    elif [[ -n "$updated_at" ]]; then
                        token="$updated_at"
                    else
                        token="$size"
                    fi
                    
                    asset_parts+=("${name}:${token}")
                done < <(echo "$release" | jq -c '.assets[]? // empty')
                
                local assets_sig
                assets_sig=$(IFS=','; echo "${asset_parts[*]:-}")
                
                # Get default branch SHA
                local sha
                sha=$(run_gh api "repos/${user}/${repo}" --jq '.default_branch' 2>/dev/null | tr -d '[:space:]' || echo "")
                local branch
                branch=$(echo "$sha" | head -1 || echo "main")
                local sha_val
                sha_val=$(run_gh api "repos/${user}/${repo}/commits/${branch:-main}" --jq '.sha[:12]' 2>/dev/null || echo "")
                
                sig="${tag_name}@${published}@${updated}|${assets_sig}|sha:${sha_val:-}"
            else
                # Try to get commit SHA as fallback
                local sha
                sha=$(run_gh api "repos/${user}/${repo}" --jq '.default_branch' 2>/dev/null | tr -d '[:space:]' || echo "main")
                local sha_val
                sha_val=$(run_gh api "repos/${user}/${repo}/commits/${sha:-main}" --jq '.sha[:12]' 2>/dev/null || echo "")
                sig="@|sha:${sha_val:-}"
            fi
            
            sig="${identity}@${sig}"
        fi
        
        parts+=("$sig")
    done < <(echo "$data" | jq -c '.[]? // empty')
    
    if [[ ${#parts[@]} -gt 0 ]]; then
        printf '%s' "$(IFS=';'; echo "${parts[*]}")"
    else
        echo "empty:${source}"
    fi
}

# Fetch recommended version from patch list
fetch_recommended_version() {
    local app_name="$1"
    local source="$2"
    
    local config_file="${APPS_DIR}"
    local app_config=""
    local package=""
    
    for platform in apkmirror apkpure uptodown aptoide; do
        local cfg_file="${config_file}/${platform}/${app_name}.json"
        if [[ -f "$cfg_file" ]]; then
            app_config=$(cat "$cfg_file")
            package=$(echo "$app_config" | jq -r '.package // ""')
            break
        fi
    done
    
    if [[ -z "$package" ]]; then
        echo ""
        return
    fi
    
    local source_file="${SOURCES_DIR}/${source}.json"
    if [[ ! -f "$source_file" ]]; then
        echo ""
        return
    fi
    
    local source_data
    source_data=$(cat "$source_file")
    
    # Only GitHub sources have parseable patch list JSON
    while IFS= read -r entry; do
        local entry_provider user repo tag
        entry_provider=$(echo "$entry" | jq -r '(.provider // "github") | ascii_downcase')
        user=$(echo "$entry" | jq -r '.user // ""')
        repo=$(echo "$entry" | jq -r '.repo // ""')
        tag=$(echo "$entry" | jq -r '.tag // "latest"')
        
        if [[ "$entry_provider" != "github" ]] || [[ -z "$user" ]] || [[ -z "$repo" ]]; then
            continue
        fi
        
        # Get release
        local release
        release=$(detect_github_release "$user" "$repo" "$tag" 2>/dev/null || true)
        
        if [[ -z "$release" ]] || [[ "$release" == "null" ]]; then
            continue
        fi
        
        # Find patch list JSON asset
        local patch_asset_url
        patch_asset_url=$(echo "$release" | jq -r '.assets[]? | select(
            (.name | endswith(".json")) and
            (.name | test("patch|list"; "i"))
        ) | .browser_download_url' | head -1)
        
        if [[ -z "$patch_asset_url" ]]; then
            continue
        fi
        
        # Download and parse patch list
        local patch_data
        patch_data=$(curl -sL "$patch_asset_url" 2>/dev/null || true)
        
        if [[ -z "$patch_data" ]]; then
            continue
        fi
        
        # Find highest non-experimental version for this package
        local stable_versions=()
        while IFS= read -r ver; do
            [[ -z "$ver" ]] && continue
            local is_exp
            is_exp=$(echo "$patch_data" | jq -r --arg v "$ver" \
                '.patches[]? | .compatiblePackages[]? | select(.packageName == $v) | .targets[]? | select(.version == $v) | .isExperimental // false' 2>/dev/null || true)
            
            if [[ "$is_exp" != "true" ]]; then
                stable_versions+=("$ver")
            fi
        done < <(echo "$patch_data" | jq -r --arg pkg "$package" \
            '.patches[]? | .compatiblePackages[]? | select(.packageName == $pkg) | .targets[].version' 2>/dev/null || true)
        
        if [[ ${#stable_versions[@]} -gt 0 ]]; then
            # Sort and get highest
            printf '%s\n' "${stable_versions[@]}" | sort -V | tail -1
            return
        fi
    done < <(echo "$source_data" | jq -c '.[]? // empty')
    
    echo ""
}

# Check if source signature is unreliable
is_unreliable_sig() {
    local sig="$1"
    local lower_sig
    lower_sig=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
    
    [[ "$lower_sig" == *"@err:"* ]] || \
    [[ "$lower_sig" == *"@badjson:"* ]] || \
    [[ "$lower_sig" == missing-source:* ]] || \
    [[ "$lower_sig" == unparseable:* ]]
}

# Get existing release APK names
get_existing_apk_names() {
    local owner_repo
    owner_repo=$(echo "${GITHUB_REPOSITORY:-}" | tr -d '[:space:]')
    
    if [[ -z "$owner_repo" ]] || [[ "$owner_repo" != */* ]]; then
        echo ""
        return
    fi
    
    local owner name
    owner=${owner_repo%/*}
    name=${owner_repo#*/}
    
    # Get release assets via API
    local assets
    assets=$(gh api "repos/${owner}/${name}/releases/tags/${RELEASE_TAG}" --jq '.assets[]? | select(.name | endswith(".apk")) | .name' 2>/dev/null || true)
    
    if [[ -n "$assets" ]]; then
        echo "$assets"
        return
    fi
    
    echo ""
}

# Recover APK from release by app/arch
recover_apk_from_release() {
    local app="$1"
    local arch="$2"
    shift 2
    local existing_apks=("$@")
    
    local app_lower arch_lower
    app_lower=$(echo "$app" | tr '[:upper:]' '[:lower:]')
    arch_lower=$(echo "$arch" | tr '[:upper:]' '[:lower:]')
    
    local candidates=()
    for apk in "${existing_apks[@]}"; do
        local lower_apk
        lower_apk=$(echo "$apk" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_apk" == ${app_lower}-${arch_lower}-* ]]; then
            candidates+=("$apk")
        fi
    done
    
    if [[ ${#candidates[@]} -gt 0 ]]; then
        # Return the last one (highest version)
        printf '%s\n' "${candidates[@]}" | sort | tail -1
    fi
}

# Main planning function
plan_incremental() {
    local full_matrix_json="$1"
    local old_manifest_json="$2"
    shift 2
    local existing_apks=("$@")
    
    local old_entries
    old_entries=$(echo "$old_manifest_json" | jq -r '.entries // {}' 2>/dev/null || echo "{}")
    
    local existing_apk_set=()
    while IFS= read -r line; do
        existing_apk_set+=("$line")
    done < <(printf '%s\n' "${existing_apks[@]:-}")
    
    local build_matrix=()
    local carry_over=()
    local new_entries_json="{"
    local first_entry=true
    
    # Parse full matrix
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        
        local app src arch mkey
        app=$(echo "$entry" | jq -r '.app_name')
        src=$(echo "$entry" | jq -r '.source')
        arch=$(echo "$entry" | jq -r '.arch')
        mkey="${app}|${src}|${arch}"
        
        local cur_app_ver cur_src_sig
        cur_app_ver=$(get_app_config_version "$app")
        cur_src_sig=$(get_source_signature "$src")
        
        local old old_src_sig carried_apk old_built_ver
        old=$(echo "$old_entries" | jq -r --arg k "$mkey" '.[$k] // null' 2>/dev/null || echo "null")
        old_src_sig=$(echo "$old" | jq -r '.source_sig // ""' 2>/dev/null || echo "")
        carried_apk=$(echo "$old" | jq -r '.apk // ""' 2>/dev/null || echo "")
        old_built_ver=$(echo "$old" | jq -r '.built_version // ""' 2>/dev/null || echo "")
        
        # If signature is unreliable, keep old one
        if [[ -n "$old_src_sig" ]] && is_unreliable_sig "$cur_src_sig"; then
            cur_src_sig="$old_src_sig"
        fi
        
        # Recover APK if needed
        if [[ -n "$carried_apk" ]] && [[ ! " ${existing_apk_set[*]:-} " =~ [[:space:]"${carried_apk}"[:space:]] ]]; then
            local recovered
            recovered=$(recover_apk_from_release "$app" "$arch" "${existing_apks[@]:-}")
            if [[ -n "$recovered" ]]; then
                carried_apk="$recovered"
                old_built_ver=$(extract_version_from_filename "$recovered")
            fi
        fi
        
        # Extract built version from filename if not set
        if [[ -z "$old_built_ver" ]] && [[ -n "$carried_apk" ]]; then
            old_built_ver=$(extract_version_from_filename "$carried_apk")
        fi
        
        # Determine if rebuild is needed
        local rebuild=false
        local reasons=()
        
        if $FORCE_FULL; then
            rebuild=true
            reasons+=("force-rebuild")
        fi
        
        if [[ "$old" == "null" ]] || [[ -z "$old" ]]; then
            rebuild=true
            reasons+=("new-entry")
        else
            local old_config_ver
            old_config_ver=$(echo "$old" | jq -r '.config_version // ""' 2>/dev/null || echo "")
            
            if [[ "$old_config_ver" != "$cur_app_ver" ]]; then
                rebuild=true
                reasons+=("app-version:${old_config_ver}->${cur_app_ver}")
            fi
            
            if [[ "$old_src_sig" != "$cur_src_sig" ]]; then
                rebuild=true
                reasons+=("patch-source-updated")
            fi
            
            if [[ -z "$old_built_ver" ]]; then
                rebuild=true
                reasons+=("legacy-manifest-missing-built-version")
            fi
            
            # Check for new version when config is "latest" (empty)
            if [[ -z "$cur_app_ver" ]] && [[ -n "$old_built_ver" ]]; then
                local target_ver
                target_ver=$(fetch_recommended_version "$app" "$src")
                
                if [[ -n "$target_ver" ]]; then
                    # Compare versions
                    if [[ "$(printf '%s\n' "$target_ver" "$old_built_ver" | sort -V | tail -1)" == "$target_ver" ]] && \
                       [[ "$target_ver" != "$old_built_ver" ]]; then
                        rebuild=true
                        reasons+=("new-version:built ${old_built_ver} -> patch ${target_ver}")
                    fi
                fi
            fi
            
            # Check if APK is missing from release
            if [[ -n "$carried_apk" ]] && [[ ! " ${existing_apk_set[*]:-} " =~ [[:space:]"${carried_apk}"[:space:]] ]]; then
                rebuild=true
                reasons+=("apk-missing-from-release")
            fi
            
            if [[ -z "$carried_apk" ]]; then
                rebuild=true
                reasons+=("no-apk-recorded")
            fi
        fi
        
        if $rebuild; then
            log_info "REBUILD ${app}/${src}/${arch}: ${reasons[*]}"
            build_matrix+=("$(printf '%s' "$entry")")
            
            # For rebuild entries, keep old source_sig (will be updated after successful build)
            if ! $first_entry; then new_entries_json+=","; fi
            first_entry=false
            new_entries_json+=$(printf '"%s":{"app_name":"%s","source":"%s","arch":"%s","config_version":"%s","source_sig":"%s","pending_source_sig":"%s","apk":"%s","built_version":"%s"}' \
                "$mkey" "$app" "$src" "$arch" "$cur_app_ver" "$old_src_sig" "$cur_src_sig" "$carried_apk" "$old_built_ver")
        else
            # Carry-over
            if [[ -n "$carried_apk" ]] && [[ " ${existing_apk_set[*]:-} " =~ [[:space:]"${carried_apk}"[:space:]] ]]; then
                carry_over+=("$carried_apk")
                log_info "carry  ${app}/${src}/${arch}: ${carried_apk}"
            else
                # Can't carry over, must rebuild
                log_info "REBUILD ${app}/${src}/${arch}: no carry-over apk"
                build_matrix+=("$(printf '%s' "$entry")")
            fi
            
            if ! $first_entry; then new_entries_json+=","; fi
            first_entry=false
            new_entries_json+=$(printf '"%s":{"app_name":"%s","source":"%s","arch":"%s","config_version":"%s","source_sig":"%s","apk":"%s","built_version":"%s"}' \
                "$mkey" "$app" "$src" "$arch" "$cur_app_ver" "$cur_src_sig" "$carried_apk" "$old_built_ver")
        fi
    done < <(echo "$full_matrix_json" | jq -c '.[]? // empty')
    
    new_entries_json+="}"
    
    # Deduplicate build matrix on (app, source) pair
    local deduped=()
    local seen=()
    for entry in "${build_matrix[@]:-}"; do
        [[ -z "$entry" ]] && continue
        local pair
        pair=$(echo "$entry" | jq -r '[.app_name, .source] | @tsv')
        
        local found=false
        for s in "${seen[@]:-}"; do
            if [[ "$s" == "$pair" ]]; then
                found=true
                break
            fi
        done
        
        if ! $found; then
            seen+=("$pair")
            # Strip arch from entry
            local app src
            app=$(echo "$entry" | jq -r '.app_name')
            src=$(echo "$entry" | jq -r '.source')
            deduped+=("{\"app_name\":\"$app\",\"source\":\"$src\"}")
        fi
    done
    
    # Filter carry-overs for rebuilding pairs
    local filtered_carry=()
    for apk in "${carry_over[@]:-}"; do
        [[ -z "$apk" ]] && continue
        
        local owner_pair=""
        while IFS= read -r eval_; do
            [[ "$eval_" == *"\"apk\":\"$apk\""* ]] && {
                owner_pair=$(echo "$eval_" | jq -r '[.app_name, .source] | @tsv')
                break
            }
        done < <(echo "$new_entries_json" | jq -c '.[]?' 2>/dev/null)
        
        local should_keep=true
        for pair in "${seen[@]:-}"; do
            if [[ "$pair" == "$owner_pair" ]]; then
                should_keep=false
                log_info "drop carry ${apk}: its (app,source) is rebuilding"
                break
            fi
        done
        
        $should_keep && filtered_carry+=("$apk")
    done
    
    # Output results
    echo "${deduped[*]:-}" > build_matrix.json 2>/dev/null || true
    printf '%s\n' "${filtered_carry[@]:-}" > carry_over.json 2>/dev/null || true
    echo "$new_entries_json" | jq '{entries: .}' > new_manifest.json 2>/dev/null || true
    
    write_gh_output "build_matrix" "$(cat build_matrix.json 2>/dev/null || echo "[]")"
    write_gh_output "has_updates" "$([ ${#deduped[@]} -gt 0 ] && echo "true" || echo "false")"
    write_gh_output "update_count" "${#deduped[@]}"
    write_gh_output "total_count" "$(echo "$full_matrix_json" | jq 'length')"
    write_gh_output "carry_count" "${#filtered_carry[@]}"
    write_gh_output "incremental" "true"
    
    log_info "============================================================"
    log_info "  Total entries:     $(echo "$full_matrix_json" | jq 'length')"
    log_info "  Need rebuild:      ${#deduped[@]}"
    log_info "  Carry over:        ${#filtered_carry[@]}"
    log_info "============================================================"
}

# Emit full rebuild (fallback)
emit_full_rebuild() {
    local reason="$1"
    log_warn "Falling back to FULL rebuild: $reason"
    
    local full
    full=$(load_patch_config | jq -s '[.[] | {app_name, source}]' 2>/dev/null || echo "[]")
    
    # Expand with arches
    local expanded="["
    local first=true
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local app src
        app=$(echo "$entry" | jq -r '.app_name')
        src=$(echo "$entry" | jq -r '.source')
        
        local arches
        arches=$(load_arch_config | jq -r --arg a "$app" --arg s "$src" '.[$a+"|"+$s] // ["universal"] | .[]' 2>/dev/null || echo "universal")
        
        while IFS= read -r arch; do
            [[ -z "$arch" ]] && continue
            if ! $first; then expanded+=","; fi
            first=false
            expanded+="{\"app_name\":\"$app\",\"source\":\"$src\",\"arch\":\"$arch\"}"
        done <<< "$arches"
    done < <(echo "$full" | jq -c '.[]? // empty')
    expanded+="]"
    
    echo "$expanded" > build_matrix.json
    echo "[]" > carry_over.json
    echo '{"entries":{}}' > new_manifest.json
    
    write_gh_output "build_matrix" "$expanded"
    write_gh_output "has_updates" "$([ ${#expanded} -gt 2 ] && echo "true" || echo "false")"
    write_gh_output "update_count" "$(echo "$expanded" | jq 'length')"
    write_gh_output "total_count" "$(echo "$expanded" | jq 'length')"
    write_gh_output "carry_count" "0"
    write_gh_output "incremental" "false"
}

# Main
main() {
    log_info "Starting incremental update check..."
    
    local full
    full=$(load_patch_config)
    
    # Expand to full matrix with arches
    local full_matrix="["
    local first=true
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local app src
        app=$(echo "$entry" | jq -r '.app_name')
        src=$(echo "$entry" | jq -r '.source')
        
        local arches
        arches=$(load_arch_config | jq -r --arg a "$app" --arg s "$src" '.[$a+"|"+$s] // ["universal"] | .[]' 2>/dev/null || echo "universal")
        
        while IFS= read -r arch; do
            [[ -z "$arch" ]] && continue
            if ! $first; then full_matrix+=","; fi
            first=false
            full_matrix+="{\"app_name\":\"$app\",\"source\":\"$src\",\"arch\":\"$arch\"}"
        done <<< "$arches"
    # $full is already NDJSON (one object per line from load_patch_config)
    done <<< "$full"
    full_matrix+="]"
    
    log_info "Full matrix: $(echo "$full_matrix" | jq 'length') (app, source, arch) entries"
    
    if $FORCE_FULL; then
        log_info "FORCE_FULL_REBUILD=true -> rebuilding everything"
        old_manifest_json="null"
    else
        # Try to fetch existing manifest
        if gh release download "$RELEASE_TAG" --pattern "$MANIFEST_NAME" --clobber 2>/dev/null; then
            old_manifest_json=$(cat "$MANIFEST_NAME" 2>/dev/null || echo "null")
        else
            old_manifest_json="null"
            log_info "No existing manifest found"
        fi
    fi
    
    # Get existing APK names
    local existing_apks=()
    while IFS= read -r line; do
        existing_apks+=("$line")
    done < <(get_existing_apk_names)
    log_info "Existing release has ${#existing_apks[@]} APK assets"
    
    if [[ "$old_manifest_json" == "null" ]] && ! $FORCE_FULL; then
        log_info "No manifest in existing release (first incremental run)"
        emit_full_rebuild "no manifest in existing release (first incremental run)"
        return 0
    fi
    
    plan_incremental "$full_matrix" "$old_manifest_json" "${existing_apks[@]:-}"
    
    return 0
}

main "$@"
