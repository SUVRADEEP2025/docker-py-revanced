#!/usr/bin/env python3
import json
import os
import subprocess
import sys


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    repo_slug = os.environ.get("GITHUB_REPOSITORY")

    # Debug info
    is_github_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    print(f"Diagnostics: file={sys.stderr}")
    print(f"  GITHUB_ACTIONS: {os.environ.get('GITHUB_ACTIONS')}", file=sys.stderr)
    print(f"  GITHUB_REPOSITORY: {repo_slug}", file=sys.stderr)
    print(f"  Token present: {'Yes' if token else 'No'}", file=sys.stderr)

    if not token:
        print(
            "GitHub auth validation failed: missing GITHUB_TOKEN/GH_TOKEN",
            file=sys.stderr,
        )
        return 1

    # In GitHub Actions, GITHUB_TOKEN is an installation token that works for API access
    # but gh auth commands (like 'status' or 'setup-git') often fail or behave differently.
    # We should rely on 'gh api' as the source of truth for token validity.

    env = os.environ.copy()
    env["GH_TOKEN"] = token
    # Try to access a basic API endpoint
    # 'rate_limit' is the most reliable endpoint that doesn't require repo permissions
    api = subprocess.run(
        ["gh", "api", "rate_limit"],
        env=env,
        capture_output=True,
        text=True,
    )

    if api.returncode != 0:
        print(
            "GitHub auth validation failed: gh api rate_limit failed", file=sys.stderr
        )
        print(api.stderr.strip() or api.stdout.strip(), file=sys.stderr)
        return 1

    try:
        payload = json.loads(api.stdout)
    except json.JSONDecodeError:
        print(
            "GitHub auth validation failed: could not parse gh api output",
            file=sys.stderr,
        )
        return 1

    # Extract meaningful identity
    # We can also check the token scope if needed via another call, but rate_limit success is usually enough
    identity = f"Authenticated via API (rate limit: {payload.get('resources', {}).get('core', {}).get('limit', 'unknown')} hourly)"

    print(f"GitHub auth OK: {identity}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
