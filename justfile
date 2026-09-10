# https://just.systems

# Default: show help
default:
    @just --list

# Install mise tools
install:
    mise install

# Validate GitHub auth
validate-auth:
    bash scripts/validate-auth.sh


# Build a single app
build:
    bash scripts/build.sh build

# Check for app updates (incremental build planning)
check-updates:
    bash scripts/check-updates.sh

# Record a build result
record-build:
    bash scripts/record-build.sh

# Merge build records into manifest
merge-manifest:
    bash scripts/merge-manifest.sh

# Clean up old APK assets from release
cleanup-apks keep_file='keep_apks.txt':
    bash scripts/cleanup-apks.sh --keep-file {{keep_file}}

# Generate app configs (from workflow)
generate-configs:
    mkdir -p apps/{apkmirror,apkpure,uptodown}
    # Configs are created by the workflow, not here
    @echo "Use .github/workflows/generate-configs.yml for config generation"

# Download source resources (patches, CLI, APKEditor, etc.)
download-source source:
    bash scripts/build.sh download {{source}}

# Full build pipeline (check + build)
build-all:
    just check-updates
    # Build jobs are triggered by workflow based on matrix

# Clean build artifacts
clean:
    rm -rf build_records/
    rm -f build_matrix.json carry_over.json new_manifest.json manifest.json
    rm -f *.apk *.apkm *.xapk *.jar *.mpp 2>/dev/null || true
    @echo "Cleaned build artifacts"

# Run tests (if any)
test:
    @echo "No tests configured"
    @exit 0
