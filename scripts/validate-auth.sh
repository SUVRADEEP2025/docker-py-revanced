#!/usr/bin/env bash
# Validate GitHub authentication

set -euo pipefail

token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
repo_slug="${GITHUB_REPOSITORY:-}"
is_github_actions="${GITHUB_ACTIONS:-false}"

# Debug info
echo "Diagnostics:" >&2
echo "  GITHUB_ACTIONS: $is_github_actions" >&2
echo "  GITHUB_REPOSITORY: $repo_slug" >&2
echo "  Token present: $([ -n "$token" ] && echo "Yes" || echo "No")" >&2

if [[ -z "$token" ]]; then
    echo "GitHub auth validation failed: missing GITHUB_TOKEN/GH_TOKEN" >&2
    exit 1
fi

# Use gh api as source of truth for token validity
# rate_limit is the most reliable endpoint that doesn't require repo permissions
if ! api_response=$(gh api rate_limit 2>&1) || [[ -z "$api_response" ]]; then
    echo "GitHub auth validation failed: gh api rate_limit failed" >&2
    echo "$api_response" >&2
    exit 1
fi

# Try to parse the response
rate_limit=$(echo "$api_response" | jq -r '.resources.core.limit // "unknown"' 2>/dev/null || echo "unknown")

if [[ -z "$rate_limit" ]] || [[ "$rate_limit" == "null" ]]; then
    echo "GitHub auth validation failed: could not parse gh api output" >&2
    exit 1
fi

echo "GitHub auth OK: Authenticated via API (rate limit: ${rate_limit} hourly)"
exit 0
