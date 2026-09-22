#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
SOURCE_DIR="${CHATGPT_EXPORT_SOURCE_DIR:-}"
[[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/pyproject.toml" ]] || { echo "CHATGPT_EXPORT_SOURCE_DIR is invalid." >&2; exit 1; }
# shellcheck source=install_lib.sh
. "$SOURCE_DIR/scripts/install_lib.sh"
. "$SOURCE_DIR/scripts/service_setup.sh"

INSTALL_ROOT="${CHATGPT_EXPORT_INSTALL_ROOT:-/opt/chatgpt-export}"
CONFIG_DIR="${CHATGPT_EXPORT_CONFIG_DIR:-/etc/chatgpt-export}"
STATE_DIR="${CHATGPT_EXPORT_STATE_DIR:-/var/lib/chatgpt-export}"
SERVICE="chatgpt-export"
SERVICE_USER="chatgpt-export"
PORT="${CHATGPT_EXPORT_PORT:-8788}"
DRY_RUN=0
NO_START=0
NEW_RELEASE=""
PREVIOUS_CURRENT=""
TRANSACTION=0
INIT=""
PKG=""
PYTHON=""
ROLLBACK_DIR=""
ROOT_EXISTED=0
CONFIG_EXISTED=0
STATE_EXISTED=0

usage(){ printf '%s\n' 'ChatGPT-Export installer' 'Usage: sudo bash install.sh [--dry-run] [--no-start]' 'Default bind: 127.0.0.1:8788'; }
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-start) NO_START=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run with sudo/root."

backup_optional(){
  local path="$1" name="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    touch "$ROLLBACK_DIR/$name.exists"
    cp -a "$path" "$ROLLBACK_DIR/$name"
  fi
}
restore_optional(){
  local path="$1" name="$2"
  rm -rf "$path" 2>/dev/null || true
  if [[ -e "$ROLLBACK_DIR/$name.exists" ]]; then
    mkdir -p "$(dirname "$path")"
    cp -a "$ROLLBACK_DIR/$name" "$path"
  fi
}
rollback(){
  warn "Installation failed; restoring the previous ChatGPT-Export state."
  if [[ "$INIT" == systemd ]] && have systemctl; then
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    if [[ ! -e "$ROLLBACK_DIR/systemd.service.exists" ]]; then systemctl disable "$SERVICE" >/dev/null 2>&1 || true; fi
  elif [[ "$INIT" == openrc ]] && have rc-service; then
    rc-service "$SERVICE" stop >/dev/null 2>&1 || true
    if [[ ! -e "$ROLLBACK_DIR/openrc.service.exists" ]] && have rc-update; then rc-update del "$SERVICE" default >/dev/null 2>&1 || true; fi
  fi

  if [[ -n "$PREVIOUS_CURRENT" && -e "$PREVIOUS_CURRENT" ]]; then ln -sfn "$PREVIOUS_CURRENT" "$INSTALL_ROOT/current" || true
  else rm -f "$INSTALL_ROOT/current" || true; fi

  restore_optional "$CONFIG_DIR/service.env" service.env
  restore_optional "$CONFIG_DIR/fernet.key" fernet.key
  restore_optional "$CONFIG_DIR/admin.token" admin.token
  restore_optional /usr/local/sbin/chatgpt-exportctl control-cli
  restore_optional /etc/systemd/system/$SERVICE.service systemd.service
  restore_optional /etc/init.d/$SERVICE openrc.service

  if [[ "$INIT" == systemd ]] && have systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    [[ -e "$ROLLBACK_DIR/systemd.service.exists" ]] && systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  elif [[ "$INIT" == openrc ]] && have rc-service; then
    [[ -e "$ROLLBACK_DIR/openrc.service.exists" ]] && rc-service "$SERVICE" restart >/dev/null 2>&1 || true
  fi

  [[ -n "$NEW_RELEASE" && -d "$NEW_RELEASE" ]] && rm -rf "$NEW_RELEASE" || true
  ((ROOT_EXISTED == 0)) && rm -rf "$INSTALL_ROOT" || true
  ((CONFIG_EXISTED == 0)) && rm -rf "$CONFIG_DIR" || true
  ((STATE_EXISTED == 0)) && rm -rf "$STATE_DIR" || true
}
cleanup(){
  local rc=$?
  if ((rc != 0 && TRANSACTION == 1)); then rollback; fi
  [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" ]] && rm -rf "$ROLLBACK_DIR" || true
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT
trap 'die "Interrupted"' INT TERM

step 1 "Detect server"
detect_system
info "package-manager=$PKG init=$INIT port=$PORT"
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1 && PORT<=65535)) || die "CHATGPT_EXPORT_PORT must be 1-65535."
[[ ! -d "$INSTALL_ROOT" || -e "$INSTALL_ROOT/.chatgpt-export-managed" ]] || die "$INSTALL_ROOT exists but is not managed by ChatGPT-Export."
if [[ ! -e "$INSTALL_ROOT/.chatgpt-export-managed" ]]; then
  [[ ! -e /etc/systemd/system/$SERVICE.service ]] || die "Foreign service exists."
  [[ ! -e /etc/init.d/$SERVICE ]] || die "Foreign OpenRC service exists."
  [[ ! -e /usr/local/sbin/chatgpt-exportctl ]] || die "Foreign /usr/local/sbin/chatgpt-exportctl exists."
fi
ok "Preflight paths are safe."

step 2 "Prerequisites"
need=0
select_python || need=1
for c in curl tar openssl; do have "$c" || need=1; done
if ((need)); then ((DRY_RUN)) && info "Would install missing prerequisites." || install_prereqs; fi
if ((!DRY_RUN)); then
  select_python || die "Python >=3.10 unavailable."
  venv_test="$(mktemp -d /tmp/chatgpt-export-venv-test.XXXXXX)"
  "$PYTHON" -m venv "$venv_test/venv" >/dev/null 2>&1 || { rm -rf "$venv_test"; die "Python venv support is missing."; }
  rm -rf "$venv_test"
fi
ok "Prerequisites ready."

step 3 "Network preflight"
if have curl; then
  curl -fsSIL --max-time 20 https://pypi.org/simple/fastapi/ >/dev/null || die "Cannot reach PyPI over HTTPS."
  curl -sSIL --max-time 20 https://chatgpt.com/ >/dev/null || warn "chatgpt.com HEAD probe was not clean; runtime requests will decide."
fi
ok "Network preflight passed."

step 4 "Prepare isolated release"
if ((DRY_RUN)); then
  info "Would build isolated release from the repository snapshot and stage transactional rollback."
else
  [[ -d "$INSTALL_ROOT" ]] && ROOT_EXISTED=1
  [[ -d "$CONFIG_DIR" ]] && CONFIG_EXISTED=1
  [[ -d "$STATE_DIR" ]] && STATE_EXISTED=1
  [[ -L "$INSTALL_ROOT/current" ]] && PREVIOUS_CURRENT="$(readlink -f "$INSTALL_ROOT/current" || true)"
  ROLLBACK_DIR="$(mktemp -d /tmp/chatgpt-export-rollback.XXXXXX)"
  backup_optional "$CONFIG_DIR/service.env" service.env
  backup_optional "$CONFIG_DIR/fernet.key" fernet.key
  backup_optional "$CONFIG_DIR/admin.token" admin.token
  backup_optional /usr/local/sbin/chatgpt-exportctl control-cli
  backup_optional /etc/systemd/system/$SERVICE.service systemd.service
  backup_optional /etc/init.d/$SERVICE openrc.service
  TRANSACTION=1

  release_id="$(date -u +%Y%m%dT%H%M%SZ)-$"
  NEW_RELEASE="$INSTALL_ROOT/releases/$release_id"
  # Create every path component explicitly: umask 077 must never make an
  # intermediate install directory inaccessible to the dedicated service user.
  install -d -m 755 "$INSTALL_ROOT" "$INSTALL_ROOT/releases" "$NEW_RELEASE"
  install -d -m 700 "$STATE_DIR" "$STATE_DIR/data"
  touch "$INSTALL_ROOT/.chatgpt-export-managed"
  cp -a "$SOURCE_DIR/." "$NEW_RELEASE/"
  rm -rf "$NEW_RELEASE/.git" "$NEW_RELEASE/__pycache__" || true
  "$PYTHON" -m venv "$NEW_RELEASE/.venv"
  "$NEW_RELEASE/.venv/bin/python" -m pip install --disable-pip-version-check --no-input --upgrade "pip<27" >/dev/null
  "$NEW_RELEASE/.venv/bin/python" -m pip install --disable-pip-version-check --no-input "$NEW_RELEASE" >/dev/null
  "$NEW_RELEASE/.venv/bin/python" -m compileall -q "$NEW_RELEASE/chatgpt_export"
  "$NEW_RELEASE/.venv/bin/python" -c 'import chatgpt_export, chatgpt_export.provider, chatgpt_export.exporter' >/dev/null
fi
ok "Release passes compile/import checks."

step 5 "Protected configuration"
if ((DRY_RUN)); then
  info "Would create a dedicated service user and protected secrets."
else
  ensure_service_user
  install -d -m 750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"

  # Release code stays root-owned but must be traversable/readable by the
  # dedicated service group. Python venv directories are commonly created as
  # 0700 under this installer's umask 077, so normalize the full release tree.
  chown root:"$SERVICE_USER" "$INSTALL_ROOT" "$INSTALL_ROOT/releases"
  chmod 750 "$INSTALL_ROOT" "$INSTALL_ROOT/releases"
  chown -R root:"$SERVICE_USER" "$NEW_RELEASE"
  chmod -R g+rX,o-rwx "$NEW_RELEASE"

  chown -R "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  [[ -f "$CONFIG_DIR/fernet.key" ]] || "$NEW_RELEASE/.venv/bin/python" - <<PY
from cryptography.fernet import Fernet
from pathlib import Path
p=Path('$CONFIG_DIR/fernet.key'); p.write_bytes(Fernet.generate_key()+b'\n')
PY
  [[ -f "$CONFIG_DIR/admin.token" ]] || openssl rand -hex 32 > "$CONFIG_DIR/admin.token"
  chown root:"$SERVICE_USER" "$CONFIG_DIR/fernet.key" "$CONFIG_DIR/admin.token"
  chmod 640 "$CONFIG_DIR/fernet.key" "$CONFIG_DIR/admin.token"
  cat > "$CONFIG_DIR/service.env.new" <<ENV
CHATGPT_EXPORT_STATE_DIR=$STATE_DIR
CHATGPT_EXPORT_DATA_DIR=$STATE_DIR/data
CHATGPT_EXPORT_CONFIG_DIR=$CONFIG_DIR
CHATGPT_EXPORT_KEY_FILE=$CONFIG_DIR/fernet.key
CHATGPT_EXPORT_ADMIN_TOKEN_FILE=$CONFIG_DIR/admin.token
CHATGPT_EXPORT_HOST=127.0.0.1
CHATGPT_EXPORT_PORT=$PORT
CHATGPT_EXPORT_CONCURRENCY=4
PYTHONDONTWRITEBYTECODE=1
ENV
  chown root:"$SERVICE_USER" "$CONFIG_DIR/service.env.new"
  chmod 640 "$CONFIG_DIR/service.env.new"
  mv -f "$CONFIG_DIR/service.env.new" "$CONFIG_DIR/service.env"
  ln -sfn "$NEW_RELEASE" "$INSTALL_ROOT/current"

  # Verify the exact runtime access model as the service UID/GID before
  # touching systemd/OpenRC. This catches CHDIR/permission failures early.
  "$PYTHON" - "$SERVICE_USER" "$INSTALL_ROOT/current" "$CONFIG_DIR" "$STATE_DIR" <<'PY'
import os
import pwd
import sys
from pathlib import Path

user, workdir, config_dir, state_dir = sys.argv[1:]
pw = pwd.getpwnam(user)
os.initgroups(user, pw.pw_gid)
os.setgid(pw.pw_gid)
os.setuid(pw.pw_uid)

work = Path(workdir)
os.chdir(work)

required_exec = work / ".venv" / "bin" / "chatgpt-export-server"
if not os.access(required_exec, os.R_OK | os.X_OK):
    raise SystemExit(f"service user cannot execute {required_exec}")

for name in ("service.env", "fernet.key", "admin.token"):
    path = Path(config_dir) / name
    with path.open("rb") as handle:
        handle.read(1)

probe = Path(state_dir) / ".permission-probe"
with probe.open("wb") as handle:
    handle.write(b"ok")
probe.unlink()
PY
fi
ok "Protected config and service-user access verified."

step 6 "Service supervision"
if ((DRY_RUN)); then info "Would create $INIT service integration."
else write_ctl; write_service_definition; fi
ok "Service definition prepared."

step 7 "Start and verify"
if ((DRY_RUN)); then ok "Dry-run complete; no changes were made."; TRANSACTION=0; exit 0; fi
start_and_verify || die "Service failed health verification; rollback will restore previous activation."
"$INSTALL_ROOT/current/.venv/bin/chatgpt-export" doctor || die "Post-install doctor failed."
TRANSACTION=0
NEW_RELEASE=""
ok "Service passed health/storage checks."

step 8 "Finish"
say "${GREEN}${BOLD}ChatGPT-Export installed successfully.${RESET}"
say "Local UI: ${BOLD}http://127.0.0.1:$PORT${RESET}"
say "Admin token: ${BOLD}sudo chatgpt-exportctl admin-token${RESET}"
say "Status: ${BOLD}sudo chatgpt-exportctl status${RESET}"
say "Doctor: ${BOLD}sudo chatgpt-exportctl doctor${RESET}"
say "Keep the service on loopback until a trusted authenticated HTTPS reverse proxy is configured."
