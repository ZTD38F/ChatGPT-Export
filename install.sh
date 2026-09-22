#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
REPO="ZTD38F/ChatGPT-Export"
BRANCH="main"
usage(){ printf '%s\n' 'ChatGPT-Export installer' 'Usage: sudo bash install.sh [--dry-run] [--no-start]' 'Default bind: 127.0.0.1:8788'; }
validate_source_tree(){
  local root="$1" file
  for file in "$root/install.sh" "$root/update.sh" "$root/uninstall.sh" "$root"/scripts/*.sh; do
    [[ -f "$file" ]] || continue
    if ! bash -n "$file"; then
      echo "Release shell syntax validation failed before installation: $file" >&2
      return 1
    fi
  done
}
for arg in "$@"; do case "$arg" in --help|-h) usage; exit 0;; esac; done
SOURCE_REF="${BASH_SOURCE[0]-}"
SCRIPT_DIR=""
if [[ -n "$SOURCE_REF" && "$SOURCE_REF" != "bash" && "$SOURCE_REF" != "/dev/stdin" ]]; then
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$SOURCE_REF")" 2>/dev/null && pwd || true)"
fi
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/pyproject.toml" && -f "$SCRIPT_DIR/scripts/install_impl.sh" ]]; then
  validate_source_tree "$SCRIPT_DIR" || exit 1
  CHATGPT_EXPORT_SOURCE_DIR="$SCRIPT_DIR" exec bash "$SCRIPT_DIR/scripts/install_impl.sh" "$@"
fi
TMP="$(mktemp -d /tmp/chatgpt-export-bootstrap.XXXXXX)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
command -v curl >/dev/null 2>&1 || { echo "curl is required for the bootstrap installer." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required for the bootstrap installer." >&2; exit 1; }
curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 \
  "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" -o "$TMP/source.tar.gz"
mkdir -p "$TMP/src"
tar -xzf "$TMP/source.tar.gz" -C "$TMP/src" --strip-components=1
[[ -f "$TMP/src/pyproject.toml" && -f "$TMP/src/scripts/install_impl.sh" ]] || { echo "Downloaded repository is incomplete." >&2; exit 1; }
validate_source_tree "$TMP/src" || exit 1
CHATGPT_EXPORT_SOURCE_DIR="$TMP/src" bash "$TMP/src/scripts/install_impl.sh" "$@"
