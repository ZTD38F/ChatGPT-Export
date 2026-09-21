#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
URL="https://raw.githubusercontent.com/ZTD38F/ChatGPT-Export/main/install.sh"
TMP="$(mktemp /tmp/chatgpt-export-update.XXXXXX)"
cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT INT TERM
command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }
curl -fL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 120 "$URL" -o "$TMP"
bash "$TMP" "$@"
