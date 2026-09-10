#!/usr/bin/env bash
# Record per-build APK filenames into manifest entries

set -euo pipefail

REC_DIR="build_records"

detect_arch_from_filename() {
    local apk_name="$1"
    local default="${2:-universal}"
    
    if [[ -z "$apk_name" ]]; then
        echo "$default"
        return
    fi
    
    local base
    base=$(echo "$apk_name" | tr '[:upper:]' '[:lower:]')
    
    case "$base" in
        *arm64-v8a*)
            echo "arm64-v8a"
            return
            ;;
        *armeabi-v7a*)
            echo "armeabi-v7a"
            return
            ;;
        *x86_64*)
            echo "x86_64"
            return
            ;;
        *x86*)
            echo "x86"
            return
            ;;
        *universal*)
            echo "universal"
            return
            ;;
    esac
    
    echo "$default"
}

extract_version_from_filename() {
    local apk_name="$1"
    
    if [[ -z "$apk_name" ]]; then
        echo ""
        return
    fi
    
    # Remove .apk extension
    local stem="${apk_name%.apk}"
    
    # Find the last -v followed by a dotted version
    # Pattern: -v<digit>.<digit>... (versions always have dots)
    local version
    version=$(echo "$stem" | grep -oP '-v(\d+\.\d[\w.+\-() ]*)$' | tail -1 | sed 's/-v//')
    
    if [[ -n "$version" ]]; then
        echo "$version"
        return
    fi
    
    echo ""
}

main() {
    local app="${APP_NAME:-}"
    local src="${SOURCE:-}"
    local apk_path="${APK_PATH:-}"
    local arch_env="${ARCH:-}"
    
    if [[ -z "$app" ]] || [[ -z "$src" ]]; then
        echo "APP_NAME / SOURCE missing; skipping manifest record"
        exit 0
    fi
    
    local apk_name
    apk_name=$(basename "$apk_path" 2>/dev/null || echo "")
    
    # Determine arch
    local arch
    if [[ -n "$arch_env" ]]; then
        arch="$arch_env"
    else
        arch=$(detect_arch_from_filename "$apk_name")
    fi
    [[ -z "$arch" ]] && arch="universal"
    
    # Extract version from filename
    local resolved_version
    resolved_version=$(extract_version_from_filename "$apk_name")
    
    # Create record directory
    mkdir -p "$REC_DIR"
    
    local safe_name="${app}__${src}__${arch}"
    safe_name="${safe_name//\//_}"
    
    local record_file="${REC_DIR}/${safe_name}.json"
    
    # Write JSON record
    jq -n \
        --arg key "${app}|${src}|${arch}" \
        --arg apk "$apk_name" \
        --arg resolved_version "$resolved_version" \
        --arg app_name "$app" \
        --arg source "$src" \
        --arg arch "$arch" \
        '{
            key: $key,
            apk: $apk,
            resolved_version: $resolved_version,
            app_name: $app_name,
            source: $source,
            arch: $arch
        }' > "$record_file"
    
    echo "Recorded build: $record_file -> {
  key: \"${app}|${src}|${arch}\",
  apk: \"$apk_name\",
  resolved_version: \"$resolved_version\",
  app_name: \"$app\",
  source: \"$src\",
  arch: \"$arch\"
}"
    
    exit 0
}

main "$@"
