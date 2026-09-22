#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

DOMAIN="${1:-}"
APP_HOST="127.0.0.1"
CONFIG_DIR="${CHATGPT_EXPORT_CONFIG_DIR:-/etc/chatgpt-export}"
SERVICE_ENV="$CONFIG_DIR/service.env"
LOG_FILE="${CHATGPT_EXPORT_DOMAIN_LOG:-/var/log/chatgpt-export-domain.log}"

CADDYFILE="${CHATGPT_EXPORT_CADDYFILE:-/etc/caddy/Caddyfile}"
NGINX_AVAILABLE="${CHATGPT_EXPORT_NGINX_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_ENABLED="${CHATGPT_EXPORT_NGINX_ENABLED:-/etc/nginx/sites-enabled}"

TRAEFIK_CONTAINER="${CHATGPT_EXPORT_TRAEFIK_CONTAINER:-traefik}"
TRAEFIK_BRIDGE_PORT="${CHATGPT_EXPORT_TRAEFIK_BRIDGE_PORT:-18788}"
TRAEFIK_SOCKET_UNIT="/etc/systemd/system/chatgpt-export-traefik.socket"
TRAEFIK_SERVICE_UNIT="/etc/systemd/system/chatgpt-export-traefik.service"
TRAEFIK_DYNAMIC_DIR=""
TRAEFIK_DYNAMIC_FILE=""
TRAEFIK_NETWORK=""
TRAEFIK_GATEWAY=""
TRAEFIK_SUBNET=""
TRAEFIK_BRIDGE_IF=""
TRAEFIK_RESOLVER=""

PROXY=""
BACKUP_DIR=""
PROXY_WAS_ACTIVE=0
PROXY_WAS_ENABLED=0
TRAEFIK_SOCKET_WAS_ACTIVE=0
TRAEFIK_SOCKET_WAS_ENABLED=0
UFW_RULE_ADDED=0
NGINX_SITE=""
MUTATED=0

say(){ printf '%s\n' "$*"; }
ok(){ say "✓ $*"; }
warn(){ say "! $*"; }
die(){ say "✗ $*" >&2; say "  Details: $LOG_FILE" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
service_active(){ systemctl is-active --quiet "$1" 2>/dev/null; }
service_enabled(){ systemctl is-enabled --quiet "$1" 2>/dev/null; }

usage(){
  cat <<'EOF'
Usage:
  sudo bash setup-domain.sh chatgpt.example.com

Configures HTTPS reverse proxying to local ChatGPT-Export.
Supported edge proxies: Docker Traefik, Caddy, nginx.
Cloudflare: Proxy ON, SSL/TLS mode Full (strict).
EOF
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { say "✗ Run with sudo/root." >&2; exit 1; }
[[ -n "$DOMAIN" ]] || { usage; exit 2; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && "$DOMAIN" == *.* ]] ||
  { say "✗ Invalid fully-qualified domain name." >&2; exit 2; }
if [[ ! "$TRAEFIK_BRIDGE_PORT" =~ ^[0-9]+$ ]] || ((TRAEFIK_BRIDGE_PORT < 1 || TRAEFIK_BRIDGE_PORT > 65535)); then
  say "✗ Invalid CHATGPT_EXPORT_TRAEFIK_BRIDGE_PORT." >&2
  exit 2
fi

install -d -m 755 "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec 3>>"$LOG_FILE"
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&3; }
run_logged(){ log "RUN: $(printf '%q ' "$@")"; "$@" >&3 2>&1; }

log "domain setup started for $DOMAIN"
[[ -f "$SERVICE_ENV" ]] || die "ChatGPT-Export is not installed."

set -a
# shellcheck disable=SC1090
. "$SERVICE_ENV"
set +a
APP_PORT="${CHATGPT_EXPORT_PORT:-8788}"

curl -fsS --max-time 3 "http://$APP_HOST:$APP_PORT/healthz" >&3 2>&1 ||
  die "ChatGPT-Export is not healthy on $APP_HOST:$APP_PORT."

if ! getent ahosts "$DOMAIN" >&3 2>&1; then
  die "DNS for $DOMAIN does not resolve yet."
fi
ok "Application and DNS are ready."

capture_service_state(){
  local service="$1"
  if service_active "$service"; then PROXY_WAS_ACTIVE=1; else PROXY_WAS_ACTIVE=0; fi
  if service_enabled "$service"; then PROXY_WAS_ENABLED=1; else PROXY_WAS_ENABLED=0; fi
}

restore_service_state(){
  local service="$1"
  if ((PROXY_WAS_ENABLED)); then systemctl enable "$service" >&3 2>&1 || true
  else systemctl disable "$service" >&3 2>&1 || true
  fi
  if ((PROXY_WAS_ACTIVE)); then systemctl restart "$service" >&3 2>&1 || true
  else systemctl stop "$service" >&3 2>&1 || true
  fi
}

restore_traefik_state(){
  if [[ -f "$BACKUP_DIR/traefik-dynamic.exists" ]]; then
    cp -a "$BACKUP_DIR/traefik-dynamic" "$TRAEFIK_DYNAMIC_FILE" || true
  else
    rm -f "$TRAEFIK_DYNAMIC_FILE" || true
  fi

  if [[ -f "$BACKUP_DIR/traefik-socket.exists" ]]; then
    cp -a "$BACKUP_DIR/traefik-socket" "$TRAEFIK_SOCKET_UNIT" || true
  else
    rm -f "$TRAEFIK_SOCKET_UNIT" || true
  fi
  if [[ -f "$BACKUP_DIR/traefik-service.exists" ]]; then
    cp -a "$BACKUP_DIR/traefik-service" "$TRAEFIK_SERVICE_UNIT" || true
  else
    rm -f "$TRAEFIK_SERVICE_UNIT" || true
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  if ((TRAEFIK_SOCKET_WAS_ENABLED)); then
    systemctl enable chatgpt-export-traefik.socket >/dev/null 2>&1 || true
  else
    systemctl disable chatgpt-export-traefik.socket >/dev/null 2>&1 || true
  fi
  if ((TRAEFIK_SOCKET_WAS_ACTIVE)); then
    systemctl restart chatgpt-export-traefik.socket >/dev/null 2>&1 || true
  else
    systemctl stop chatgpt-export-traefik.socket >/dev/null 2>&1 || true
  fi

  if ((UFW_RULE_ADDED)) && have ufw; then
    ufw --force delete allow in on "$TRAEFIK_BRIDGE_IF" to "$TRAEFIK_GATEWAY"       port "$TRAEFIK_BRIDGE_PORT" proto tcp from "$TRAEFIK_SUBNET" >/dev/null 2>&1 || true
  fi
}

cleanup(){
  local rc=$?
  if ((rc != 0)) && ((MUTATED)) && [[ -n "$BACKUP_DIR" ]]; then
    log "failure detected; rolling back proxy=$PROXY"
    case "$PROXY" in
      traefik-docker) restore_traefik_state ;;
      caddy)
        if [[ -f "$BACKUP_DIR/Caddyfile.exists" ]]; then
          cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE" || true
        else
          rm -f "$CADDYFILE" || true
        fi
        restore_service_state caddy
        ;;
      nginx)
        if [[ -n "$NGINX_SITE" ]]; then
          rm -f "$NGINX_SITE" "$NGINX_ENABLED/$(basename "$NGINX_SITE")" || true
          if [[ -f "$BACKUP_DIR/nginx-site.exists" ]]; then
            cp -a "$BACKUP_DIR/nginx-site" "$NGINX_SITE" || true
            ln -sfn "$NGINX_SITE" "$NGINX_ENABLED/$(basename "$NGINX_SITE")" || true
          fi
        fi
        restore_service_state nginx
        ;;
    esac
  fi
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR" || true
  fi
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

docker_traefik_running(){
  have docker || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$TRAEFIK_CONTAINER" 2>/dev/null || true)" == "true" ]] || return 1
  docker inspect -f '{{.Config.Image}} {{.Name}}' "$TRAEFIK_CONTAINER" 2>/dev/null | grep -qi traefik
}

discover_docker_traefik(){
  have python3 || die "Python 3 is required to inspect Docker Traefik safely."

  local -a info
  local network_id
  mapfile -t info < <(
    docker inspect "$TRAEFIK_CONTAINER" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)[0]
dynamic = next((m.get("Source", "") for m in d.get("Mounts", []) if m.get("Destination") == "/dynamic"), "")
networks = d.get("NetworkSettings", {}).get("Networks", {})
network = next(((name, cfg.get("Gateway", "")) for name, cfg in networks.items() if cfg.get("Gateway")), ("", ""))
cmd = d.get("Config", {}).get("Cmd") or []
http = []
any_acme = []
for arg in cmd:
    m = re.match(r"^--certificatesresolvers\.([^.]+)\.acme\.httpchallenge\.", arg)
    if m:
        http.append(m.group(1))
    m = re.match(r"^--certificatesresolvers\.([^.]+)\.acme\.", arg)
    if m:
        any_acme.append(m.group(1))
resolver = (http or any_acme or [""])[0]
print(dynamic)
print(network[0])
print(network[1])
print(resolver)
'
  )
  TRAEFIK_DYNAMIC_DIR="${info[0]:-}"
  TRAEFIK_NETWORK="${info[1]:-}"
  TRAEFIK_GATEWAY="${info[2]:-}"
  TRAEFIK_RESOLVER="${info[3]:-}"

  [[ -n "$TRAEFIK_DYNAMIC_DIR" && -d "$TRAEFIK_DYNAMIC_DIR" ]] ||
    die "Traefik is running, but its /dynamic file-provider directory is not mounted."
  [[ -n "$TRAEFIK_NETWORK" && -n "$TRAEFIK_GATEWAY" ]] ||
    die "Could not discover Traefik's routable Docker network."
  [[ -n "$TRAEFIK_RESOLVER" ]] ||
    die "No Traefik ACME certificate resolver was discovered."

  TRAEFIK_SUBNET="$(docker network inspect "$TRAEFIK_NETWORK" | python3 -c '
import json, sys
d = json.load(sys.stdin)[0]
cfg = (d.get("IPAM", {}).get("Config") or [{}])[0]
print(cfg.get("Subnet", ""))
')"
  network_id="$(docker network inspect "$TRAEFIK_NETWORK" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("Id",""))')"
  [[ -n "$TRAEFIK_SUBNET" && -n "$network_id" ]] ||
    die "Could not discover Traefik Docker network metadata."

  TRAEFIK_BRIDGE_IF="br-${network_id:0:12}"
  [[ -d "/sys/class/net/$TRAEFIK_BRIDGE_IF" ]] ||
    die "Docker bridge interface $TRAEFIK_BRIDGE_IF was not found."

  TRAEFIK_DYNAMIC_FILE="$TRAEFIK_DYNAMIC_DIR/chatgpt-export.yml"
  log "traefik container=$TRAEFIK_CONTAINER network=$TRAEFIK_NETWORK gateway=$TRAEFIK_GATEWAY subnet=$TRAEFIK_SUBNET bridge=$TRAEFIK_BRIDGE_IF resolver=$TRAEFIK_RESOLVER"
}

port_listener_proxy(){
  have ss || { printf 'none'; return; }
  local out unknown=0 has_caddy=0 has_nginx=0 has_docker=0
  out="$(ss -H -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /:443$/ {print}' || true)"
  [[ -z "$out" ]] && { printf 'none'; return; }
  printf '%s\n' "$out" >&3

  if grep -Eqi 'caddy' <<<"$out"; then has_caddy=1; fi
  if grep -Eqi 'nginx' <<<"$out"; then has_nginx=1; fi
  if grep -Eqi 'docker-proxy' <<<"$out"; then has_docker=1; fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! grep -Eqi 'caddy|nginx|docker-proxy' <<<"$line"; then unknown=1; fi
  done <<<"$out"

  if ((unknown)); then printf 'unknown'; return; fi
  if ((has_docker)); then printf 'docker'; return; fi
  if ((has_caddy && has_nginx)); then printf 'mixed'; return; fi
  if ((has_caddy)); then printf 'caddy'; return; fi
  if ((has_nginx)); then printf 'nginx'; return; fi
  printf 'unknown'
}

choose_proxy(){
  local owner
  if docker_traefik_running; then
    printf 'traefik-docker'
    return
  fi
  if service_active caddy; then printf 'caddy'; return; fi
  if service_active nginx; then printf 'nginx'; return; fi

  owner="$(port_listener_proxy)"
  case "$owner" in
    docker)
      die "Docker owns port 80/443, but no running Traefik container named $TRAEFIK_CONTAINER was found." ;;
    caddy)
      have caddy || die "Port 80/443 is owned by Caddy, but the caddy binary is unavailable."
      printf 'caddy'; return ;;
    nginx)
      have nginx || die "Port 80/443 is owned by nginx, but the nginx binary is unavailable."
      printf 'nginx'; return ;;
    mixed) die "Both Caddy and nginx appear to own public web ports; refusing to guess." ;;
    unknown) die "Port 80/443 is already owned by an unsupported process." ;;
    none) ;;
    *) die "Could not determine the public port owner safely." ;;
  esac

  if have caddy; then printf 'caddy'; return; fi
  if have nginx; then printf 'nginx'; return; fi
  printf 'caddy'
}

socket_proxy_binary(){
  if have systemd-socket-proxyd; then
    command -v systemd-socket-proxyd
  elif [[ -x /lib/systemd/systemd-socket-proxyd ]]; then
    printf '/lib/systemd/systemd-socket-proxyd'
  elif [[ -x /usr/lib/systemd/systemd-socket-proxyd ]]; then
    printf '/usr/lib/systemd/systemd-socket-proxyd'
  else
    return 1
  fi
}

configure_traefik_docker(){
  PROXY="traefik-docker"
  discover_docker_traefik

  local proxyd
  proxyd="$(socket_proxy_binary)" || die "systemd-socket-proxyd is required for Docker Traefik integration."

  BACKUP_DIR="$(mktemp -d /tmp/chatgpt-export-domain.XXXXXX)"
  if [[ -f "$TRAEFIK_DYNAMIC_FILE" ]]; then
    touch "$BACKUP_DIR/traefik-dynamic.exists"
    cp -a "$TRAEFIK_DYNAMIC_FILE" "$BACKUP_DIR/traefik-dynamic"
  fi
  if [[ -f "$TRAEFIK_SOCKET_UNIT" ]]; then
    touch "$BACKUP_DIR/traefik-socket.exists"
    cp -a "$TRAEFIK_SOCKET_UNIT" "$BACKUP_DIR/traefik-socket"
  fi
  if [[ -f "$TRAEFIK_SERVICE_UNIT" ]]; then
    touch "$BACKUP_DIR/traefik-service.exists"
    cp -a "$TRAEFIK_SERVICE_UNIT" "$BACKUP_DIR/traefik-service"
  fi
  if service_active chatgpt-export-traefik.socket; then TRAEFIK_SOCKET_WAS_ACTIVE=1; fi
  if service_enabled chatgpt-export-traefik.socket; then TRAEFIK_SOCKET_WAS_ENABLED=1; fi

  cat >"$TRAEFIK_SOCKET_UNIT" <<EOF
[Unit]
Description=ChatGPT Export bridge socket for Traefik
After=network-online.target chatgpt-export.service
Wants=network-online.target

[Socket]
ListenStream=$TRAEFIK_GATEWAY:$TRAEFIK_BRIDGE_PORT
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

  cat >"$TRAEFIK_SERVICE_UNIT" <<EOF
[Unit]
Description=ChatGPT Export socket proxy to loopback backend
Requires=chatgpt-export-traefik.socket
After=chatgpt-export.service

[Service]
ExecStart=$proxyd $APP_HOST:$APP_PORT
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictSUIDSGID=yes
LockPersonality=yes
EOF

  systemd-analyze verify "$TRAEFIK_SOCKET_UNIT" "$TRAEFIK_SERVICE_UNIT" >&3 2>&1 ||
    die "Traefik bridge systemd units failed validation."
  systemctl daemon-reload
  systemctl enable --now chatgpt-export-traefik.socket >&3 2>&1
  MUTATED=1

  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status | grep -F "$TRAEFIK_BRIDGE_PORT/tcp" | grep -Fq "$TRAEFIK_SUBNET"; then
      ufw allow in on "$TRAEFIK_BRIDGE_IF" to "$TRAEFIK_GATEWAY" port "$TRAEFIK_BRIDGE_PORT"         proto tcp from "$TRAEFIK_SUBNET" comment 'ChatGPT Export via Traefik' >&3 2>&1
      UFW_RULE_ADDED=1
    fi
  fi

  local candidate expected_rule bt
  bt='`'
  candidate="$(mktemp "$TRAEFIK_DYNAMIC_DIR/.chatgpt-export.XXXXXX.yml")"
    printf '      rule: "Host(%s%s%s)"\n' "$bt" "$DOMAIN" "$bt"
  {
    printf '%s\n' 'http:'
    printf '%s\n' '  routers:'
    printf '%s\n' '    chatgpt-export:'
    printf '      rule: \"Host(%s%s%s)\"\\n' \"$bt\" \"$DOMAIN\" \"$bt\"
    printf '%s\n' '      entryPoints:'
    printf '%s\n' '        - websecure'
    printf '%s\n' '      tls:'
    printf '        certResolver: %s\n' "$TRAEFIK_RESOLVER"
    printf '%s\n' '      service: chatgpt-export'
    printf '%s\n' ''
    printf '%s\n' '  services:'
    printf '%s\n' '    chatgpt-export:'
    printf '%s\n' '      loadBalancer:'
    printf '%s\n' '        passHostHeader: true'
    printf '%s\n' '        servers:'
    printf '          - url: "http://%s:%s"\n' "$TRAEFIK_GATEWAY" "$TRAEFIK_BRIDGE_PORT"
  } >"$candidate"
  chmod 644 "$candidate"

  if ! grep -Fxq "$expected_rule" "$candidate"; then
    rm -f "$candidate"
    die "Generated Traefik router rule failed validation."
  fi
  if grep -Fq 'Host()' "$candidate"; then
    rm -f "$candidate"
    die "Generated Traefik router rule is empty."
  fi

  mv -f "$candidate" "$TRAEFIK_DYNAMIC_FILE"

  sleep 2
  if ! docker exec "$TRAEFIK_CONTAINER" traefik healthcheck --ping >&3 2>&1; then
    docker logs --tail 120 "$TRAEFIK_CONTAINER" >&3 2>&1 || true
    die "Traefik failed its health check."
  fi
  if ! docker exec "$TRAEFIK_CONTAINER" sh -lc       "wget -qO- -T 4 http://$TRAEFIK_GATEWAY:$TRAEFIK_BRIDGE_PORT/healthz" >&3 2>&1; then
    die "Traefik cannot reach the private ChatGPT-Export bridge."
  fi

  if service_active caddy && ss -H -ltnp 2>/dev/null | grep -Eq 'docker-proxy.*:(80|443)|:(80|443).*docker-proxy'; then
    systemctl disable --now caddy >&3 2>&1 || true
    systemctl reset-failed caddy >&3 2>&1 || true
  elif [[ "$(systemctl is-failed caddy 2>/dev/null || true)" == "failed" ]]; then
    systemctl disable caddy >&3 2>&1 || true
    systemctl reset-failed caddy >&3 2>&1 || true
  fi

  ok "Reverse proxy: Docker Traefik."
}

install_caddy(){
  have caddy && return 0
  have apt-get || die "Caddy is not installed and automatic installation currently requires apt."
  export DEBIAN_FRONTEND=noninteractive
  run_logged apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=4 update -qq
  run_logged apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=4 install -y --no-install-recommends     debian-keyring debian-archive-keyring apt-transport-https curl gpg ca-certificates

  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key |
      gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>>"$LOG_FILE"
  fi
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt       -o /etc/apt/sources.list.d/caddy-stable.list
  fi
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  run_logged apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=4 update -qq
  run_logged apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=4 install -y caddy
}

wait_service(){
  local service="$1"
  for _ in $(seq 1 20); do
    if service_active "$service"; then return 0; fi
    sleep 1
  done
  journalctl -u "$service" -n 120 --no-pager >&3 2>&1 || true
  return 1
}

configure_caddy(){
  PROXY="caddy"
  install_caddy
  capture_service_state caddy
  BACKUP_DIR="$(mktemp -d /tmp/chatgpt-export-domain.XXXXXX)"
  install -d -m 755 "$(dirname "$CADDYFILE")"
  if [[ -f "$CADDYFILE" ]]; then
    touch "$BACKUP_DIR/Caddyfile.exists"
    cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile"
  else
    : > "$CADDYFILE"
  fi

  local begin="# BEGIN CHATGPT-EXPORT $DOMAIN"
  local end="# END CHATGPT-EXPORT $DOMAIN"
  local tmp
  tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  ' "$CADDYFILE" >"$tmp"
  cat >>"$tmp" <<EOF

$begin
$DOMAIN {
    encode zstd gzip
    reverse_proxy $APP_HOST:$APP_PORT
}
$end
EOF
  install -m 644 "$tmp" "$CADDYFILE"
  rm -f "$tmp"
  MUTATED=1

  run_logged caddy fmt --overwrite "$CADDYFILE"
  run_logged caddy validate --config "$CADDYFILE" --adapter caddyfile

  if service_active caddy; then
    run_logged systemctl reload caddy
  else
    run_logged systemctl reset-failed caddy || true
    run_logged systemctl enable caddy
    run_logged systemctl start caddy || true
    wait_service caddy || die "Caddy did not stay running."
  fi
  ok "Reverse proxy: Caddy."
}

install_certbot(){
  have certbot && return 0
  have apt-get || die "nginx is installed but certbot is missing; automatic setup requires apt."
  export DEBIAN_FRONTEND=noninteractive
  run_logged apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=4 update -qq
  run_logged apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=4 install -y --no-install-recommends     certbot python3-certbot-nginx
}

configure_nginx(){
  PROXY="nginx"
  install_certbot
  capture_service_state nginx
  BACKUP_DIR="$(mktemp -d /tmp/chatgpt-export-domain.XXXXXX)"
  install -d -m 755 "$NGINX_AVAILABLE" "$NGINX_ENABLED"

  local safe
  safe="$(printf '%s' "$DOMAIN" | tr '.-' '__')"
  NGINX_SITE="$NGINX_AVAILABLE/chatgpt-export-$safe.conf"
  if [[ -f "$NGINX_SITE" ]]; then
    touch "$BACKUP_DIR/nginx-site.exists"
    cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx-site"
  fi

  cat >"$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    client_max_body_size 2m;

    location / {
        proxy_pass http://$APP_HOST:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
EOF
  ln -sfn "$NGINX_SITE" "$NGINX_ENABLED/$(basename "$NGINX_SITE")"
  MUTATED=1

  run_logged nginx -t
  if service_active nginx; then
    run_logged systemctl reload nginx
  else
    run_logged systemctl reset-failed nginx || true
    run_logged systemctl enable nginx
    run_logged systemctl start nginx || true
    wait_service nginx || die "nginx did not stay running."
  fi

  run_logged certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos     --register-unsafely-without-email --redirect
  run_logged nginx -t
  run_logged systemctl reload nginx
  ok "Reverse proxy: nginx."
}

PROXY="$(choose_proxy)"
log "selected proxy=$PROXY"
case "$PROXY" in
  traefik-docker) configure_traefik_docker ;;
  caddy) configure_caddy ;;
  nginx) configure_nginx ;;
  *) die "No supported reverse proxy could be selected." ;;
esac

origin_ok=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/healthz" >&3 2>&1; then
    origin_ok=1
    break
  fi
  sleep 2
done
((origin_ok)) || die "Origin HTTPS did not become healthy."

public_ok=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 "https://$DOMAIN/healthz" 2>>"$LOG_FILE" | grep -q '"ok":true'; then
    public_ok=1
    break
  fi
  sleep 2
done
if ((public_ok == 0)); then
  curl -sS --max-time 10 -D - "https://$DOMAIN/healthz" -o /dev/null >&3 2>&1 || true
  die "Origin is healthy, but public HTTPS through Cloudflare is not."
fi

install -d -m 750 "$CONFIG_DIR"
printf '%s\n' "$DOMAIN" >"$CONFIG_DIR/public-domain"
if getent group chatgpt-export >/dev/null 2>&1; then
  chown root:chatgpt-export "$CONFIG_DIR/public-domain"
fi
chmod 640 "$CONFIG_DIR/public-domain"

MUTATED=0
say ""
ok "https://$DOMAIN is live."
say "Cloudflare: Proxy ON · SSL/TLS Full (strict)"
