#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ -t 1 ]]; then RESET=$'\033[0m'; BOLD=$'\033[1m'; GREEN=$'\033[32m'; BLUE=$'\033[34m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; else RESET=""; BOLD=""; GREEN=""; BLUE=""; YELLOW=""; RED=""; fi
say(){ printf '%b\n' "$*"; }; info(){ say "${BLUE}●${RESET} $*"; }; ok(){ say "${GREEN}✓${RESET} $*"; }; warn(){ say "${YELLOW}!${RESET} $*"; }; die(){ say "${RED}✗${RESET} $*" >&2; exit 1; }
step(){ say ""; say "${BOLD}${BLUE}[$1/8]${RESET} ${BOLD}$2${RESET}"; }
have(){ command -v "$1" >/dev/null 2>&1; }
python_ok(){ "$1" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3,10) else 1)
PY
}
select_python(){ local p; PYTHON=""; for p in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do if have "$p" && python_ok "$p"; then PYTHON="$(command -v "$p")"; return 0; fi; done; return 1; }
detect_system(){
  [[ "$(uname -s)" == Linux ]] || die "Linux is required."
  case "$(uname -m)" in x86_64|amd64|aarch64|arm64) :;; *) die "Unsupported architecture: $(uname -m)";; esac
  if have apt-get; then PKG=apt; elif have dnf; then PKG=dnf; elif have yum; then PKG=yum; elif have apk; then PKG=apk; elif have pacman; then PKG=pacman; elif have zypper; then PKG=zypper; else PKG=none; fi
  if have systemctl && [[ -d /run/systemd/system ]]; then INIT=systemd; elif have rc-service; then INIT=openrc; else INIT=manual; fi
}
install_prereqs(){
  case "$PKG" in
    apt) env DEBIAN_FRONTEND=noninteractive apt-get update -qq; env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-venv python3-pip curl tar openssl ca-certificates;;
    dnf) dnf install -y python3 python3-pip curl tar openssl ca-certificates;;
    yum) yum install -y python3 python3-pip curl tar openssl ca-certificates;;
    apk) apk add --no-cache python3 py3-pip py3-virtualenv curl tar openssl ca-certificates;;
    pacman) pacman -Sy --noconfirm --needed python python-pip curl tar openssl ca-certificates;;
    zypper) zypper --non-interactive install --no-recommends python3 python3-pip python3-virtualenv curl tar openssl ca-certificates;;
    *) die "Install Python >=3.10 with venv, curl, tar, openssl, ca-certificates and rerun.";;
  esac
}
ensure_service_user(){
  id -u "$SERVICE_USER" >/dev/null 2>&1 && return 0
  if have useradd; then useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null || useradd -r -d /nonexistent -s /sbin/nologin "$SERVICE_USER"
  elif have adduser; then adduser -S -H -D "$SERVICE_USER" 2>/dev/null || adduser --system --no-create-home "$SERVICE_USER"
  else die "Cannot create dedicated service user $SERVICE_USER."; fi
}
write_ctl(){ cat > /usr/local/sbin/chatgpt-exportctl <<CTL
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-status}" in
 status) if command -v systemctl >/dev/null && [[ -f /etc/systemd/system/$SERVICE.service ]]; then exec systemctl status $SERVICE --no-pager; elif command -v rc-service >/dev/null && [[ -f /etc/init.d/$SERVICE ]]; then exec rc-service $SERVICE status; else echo 'No supported service manager'; exit 1; fi;;
 logs) if command -v journalctl >/dev/null && [[ -f /etc/systemd/system/$SERVICE.service ]]; then exec journalctl -u $SERVICE -n "\${2:-120}" --no-pager; else exec tail -n "\${2:-120}" /var/log/$SERVICE.log; fi;;
 restart) if command -v systemctl >/dev/null && [[ -f /etc/systemd/system/$SERVICE.service ]]; then exec systemctl restart $SERVICE; else exec rc-service $SERVICE restart; fi;;
 stop) if command -v systemctl >/dev/null && [[ -f /etc/systemd/system/$SERVICE.service ]]; then exec systemctl stop $SERVICE; else exec rc-service $SERVICE stop; fi;;
 doctor) set -a; . $CONFIG_DIR/service.env; set +a; exec $INSTALL_ROOT/current/.venv/bin/chatgpt-export doctor;;
 export-status) set -a; . $CONFIG_DIR/service.env; set +a; exec $INSTALL_ROOT/current/.venv/bin/chatgpt-export status;;
 admin-token) cat $CONFIG_DIR/admin.token;;
 data-dir) echo $STATE_DIR/data;;
 *) echo 'Usage: chatgpt-exportctl {status|logs [N]|restart|stop|doctor|export-status|admin-token|data-dir}' >&2; exit 2;;
esac
CTL
chmod 755 /usr/local/sbin/chatgpt-exportctl; }
