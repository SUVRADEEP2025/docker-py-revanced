#!/bin/bash

# Check github connection stable or not:
check_connection() {
	wget -q $(curl -s "https://api.github.com/repos/revanced/revanced-patches/releases/latest" | jq -r '.assets[] | select(.name == "patches.json") | .browser_download_url') || rm -f "patches.json"
}
check_connection
