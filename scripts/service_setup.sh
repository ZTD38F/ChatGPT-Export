#!/usr/bin/env bash
set -Eeuo pipefail

write_service_definition(){
  if [[ "$INIT" == systemd ]]; then
    cat > /etc/systemd/system/$SERVICE.service <<UNIT
[Unit]
Description=ChatGPT Export self-hosted backup server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$CONFIG_DIR/service.env
WorkingDirectory=$INSTALL_ROOT/current
ExecStart=$INSTALL_ROOT/current/.venv/bin/chatgpt-export-server
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$STATE_DIR
ProtectHome=true
RestrictSUIDSGID=true
LockPersonality=true
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload; systemctl enable "$SERVICE" >/dev/null
  elif [[ "$INIT" == openrc ]]; then
    cat > /etc/init.d/$SERVICE <<RC
#!/sbin/openrc-run
name="ChatGPT Export"
command="$INSTALL_ROOT/current/.venv/bin/chatgpt-export-server"
command_background=yes
command_user="$SERVICE_USER:$SERVICE_USER"
pidfile="/run/$SERVICE.pid"
output_log="/var/log/$SERVICE.log"
error_log="/var/log/$SERVICE.log"
start_pre(){ set -a; . "$CONFIG_DIR/service.env"; set +a; }
depend(){ need net; after firewall; }
RC
    chmod 755 /etc/init.d/$SERVICE; rc-update add "$SERVICE" default >/dev/null
  else
    warn "No systemd/OpenRC detected; 24/7 supervision was not configured."
  fi
}

start_and_verify(){
  if ((NO_START)); then warn "Start skipped by --no-start."; return 0; fi
  if [[ "$INIT" == systemd ]]; then
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE"
  elif [[ "$INIT" == openrc ]]; then rc-service "$SERVICE" restart
  else return 0
  fi
  local healthy=0
  for _ in {1..30}; do
    if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then healthy=$((healthy+1)); ((healthy>=3)) && return 0
    else healthy=0; fi
    sleep 1
  done
  [[ "$INIT" == systemd ]] && journalctl -u "$SERVICE" -n 100 --no-pager >&2 || true
  return 1
}
