#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
REPO="ZTD38F/ChatGPT-Export"
BRANCH="main"
usage(){ printf '%s\n' 'ChatGPT-Export installer' 'Usage: sudo bash install.sh [--dry-run] [--no-start]' 'Default bind: 127.0.0.1:8788'; }
for arg in "$@"; do case "$arg" in --help|-h) usage; exit 0;; esac; done
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/pyproject.toml" && -f "$SCRIPT_DIR/scripts/install_impl.sh" ]]; then
  CHATGPT_EXPORT_SOURCE_DIR="$SCRIPT_DIR" exec bash "$SCRIPT_DIR/scripts/install_impl.sh" "$@"
fi
TMP="$(mktemp -d /tmp/chatgpt-export-bootstrap.XXXXXX)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
command -v curl >/dev/null 2>&1 || { echo "curl is required for the bootstrap installer." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required for the bootstrap installer." >&2; exit 1; }
curl -fL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 \
  "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" -o "$TMP/source.tar.gz"
mkdir -p "$TMP/src"
tar -xzf "$TMP/source.tar.gz" -C "$TMP/src" --strip-components=1
[[ -f "$TMP/src/pyproject.toml" && -f "$TMP/src/scripts/install_impl.sh" ]] || { echo "Downloaded repository is incomplete." >&2; exit 1; }
CHATGPT_EXPORT_SOURCE_DIR="$TMP/src" bash "$TMP/src/scripts/install_impl.sh" "$@"
