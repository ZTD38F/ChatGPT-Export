#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }
SERVICE=chatgpt-export
if command -v systemctl >/dev/null && [[ -f /etc/systemd/system/$SERVICE.service ]]; then systemctl disable --now $SERVICE >/dev/null 2>&1 || true; rm -f /etc/systemd/system/$SERVICE.service; systemctl daemon-reload; fi
if command -v rc-service >/dev/null && [[ -f /etc/init.d/$SERVICE ]]; then rc-service $SERVICE stop >/dev/null 2>&1 || true; rc-update del $SERVICE default >/dev/null 2>&1 || true; rm -f /etc/init.d/$SERVICE; fi
rm -rf /opt/chatgpt-export
rm -f /usr/local/sbin/chatgpt-exportctl
printf '%s\n' "ChatGPT-Export application removed." "Preserved intentionally: /etc/chatgpt-export and /var/lib/chatgpt-export" "Delete those manually only after verifying your backups."
