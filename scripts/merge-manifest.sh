#!/usr/bin/env bash
# Merge per-build records into the final manifest.json

set -euo pipefail

NEW_MANIFEST="new_manifest.json"
REC_DIR="build_records"
OUTPUT_MANIFEST="manifest.json"

main() {
    # Check for new_manifest.json
    if [[ ! -f "$NEW_MANIFEST" ]]; then
        echo "No new_manifest.json found; nothing to merge"
        exit 0
    fi
    
    # Start with new_manifest.json
    local manifest
    manifest=$(cat "$NEW_MANIFEST")
    
    # Process build records
    if [[ -d "$REC_DIR" ]]; then
        for rec_file in "$REC_DIR"/*.json; do
            [[ -f "$rec_file" ]] || continue
            
            local rec
            rec=$(cat "$rec_file" 2>/dev/null || true)
            [[ -z "$rec" ]] && continue
            
            local key apk resolved_version
            key=$(echo "$rec" | jq -r '.key // ""' 2>/dev/null || echo "")
            apk=$(echo "$rec" | jq -r '.apk // ""' 2>/dev/null || echo "")
            resolved_version=$(echo "$rec" | jq -r '.resolved_version // ""' 2>/dev/null || echo "")
            
            [[ -z "$key" ]] && continue
            
            # Update the entry in manifest
            manifest=$(echo "$manifest" | jq --arg k "$key" \
                --arg a "$apk" \
                --arg v "$resolved_version" \
                --arg app "$(echo "$rec" | jq -r '.app_name // ""' 2>/dev/null || echo "")" \
                --arg src "$(echo "$rec" | jq -r '.source // ""' 2>/dev/null || echo "")" \
                --arg arch "$(echo "$rec" | jq -r '.arch // "universal"' 2>/dev/null || echo "universal")" \
                '
                .entries[$k] = (
                    if .entries[$k] then .entries[$k] 
                    else {
                        app_name: $app,
                        source: $src,
                        arch: $arch,
                        config_version: "",
                        source_sig: "",
                        apk: "",
                        built_version: ""
                    }
                    end
                ) |
                .entries[$k].apk = ($a // .entries[$k].apk) |
                .entries[$k].built_version = ($v // .entries[$k].built_version)
                ')
            
            echo "  merged ${key} -> apk=${apk} built_version=${resolved_version}"
        done
    fi
    
    # Promote pending_source_sig to source_sig
    manifest=$(echo "$manifest" | jq '
        .entries |= with_entries(
            if .value.pending_source_sig then
                .value.source_sig = .value.pending_source_sig |
                .value.pending_source_sig = null
            else . end
        )
    ')
    
    # Write output
    echo "$manifest" | jq '.' > "$OUTPUT_MANIFEST"
    
    local entry_count
    entry_count=$(echo "$manifest" | jq '.entries | length')
    echo "Wrote $OUTPUT_MANIFEST with $entry_count entries"
    
    exit 0
}

main "$@"
