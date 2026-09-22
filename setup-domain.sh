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

PROXY=""
BACKUP_DIR=""
PROXY_WAS_ACTIVE=0
PROXY_WAS_ENABLED=0
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
Cloudflare: Proxy ON, SSL/TLS mode Full (strict).
EOF
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { say "✗ Run with sudo/root." >&2; exit 1; }
[[ -n "$DOMAIN" ]] || { usage; exit 2; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && "$DOMAIN" == *.* ]] ||
  { say "✗ Invalid fully-qualified domain name." >&2; exit 2; }

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
  service_active "$service" && PROXY_WAS_ACTIVE=1 || PROXY_WAS_ACTIVE=0
  service_enabled "$service" && PROXY_WAS_ENABLED=1 || PROXY_WAS_ENABLED=0
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

cleanup(){
  local rc=$?
  if ((rc != 0)) && ((MUTATED)) && [[ -n "$BACKUP_DIR" ]]; then
    log "failure detected; rolling back proxy=$PROXY"
    if [[ "$PROXY" == "caddy" ]]; then
      if [[ -f "$BACKUP_DIR/Caddyfile.exists" ]]; then
        cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE" || true
      else
        rm -f "$CADDYFILE" || true
      fi
      restore_service_state caddy
    elif [[ "$PROXY" == "nginx" ]]; then
      if [[ -n "$NGINX_SITE" ]]; then
        rm -f "$NGINX_SITE" "$NGINX_ENABLED/$(basename "$NGINX_SITE")" || true
        if [[ -f "$BACKUP_DIR/nginx-site.exists" ]]; then
          cp -a "$BACKUP_DIR/nginx-site" "$NGINX_SITE" || true
          ln -sfn "$NGINX_SITE" "$NGINX_ENABLED/$(basename "$NGINX_SITE")" || true
        fi
      fi
      restore_service_state nginx
    fi
  fi
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR" || true
  fi
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

port_listener_proxy(){
  have ss || { printf 'none'; return; }
  local out unknown=0 has_caddy=0 has_nginx=0
  out="$(ss -H -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /:443$/ {print}' || true)"
  [[ -z "$out" ]] && { printf 'none'; return; }
  printf '%s\n' "$out" >&3

  if grep -Eqi 'caddy' <<<"$out"; then has_caddy=1; fi
  if grep -Eqi 'nginx' <<<"$out"; then has_nginx=1; fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! grep -Eqi 'caddy|nginx' <<<"$line"; then unknown=1; fi
  done <<<"$out"

  if ((unknown)); then printf 'unknown'; return; fi
  if ((has_caddy && has_nginx)); then printf 'mixed'; return; fi
  if ((has_caddy)); then printf 'caddy'; return; fi
  if ((has_nginx)); then printf 'nginx'; return; fi
  printf 'unknown'
}

choose_proxy(){
  local owner
  if service_active caddy; then printf 'caddy'; return; fi
  if service_active nginx; then printf 'nginx'; return; fi

  owner="$(port_listener_proxy)"
  case "$owner" in
    caddy)
      have caddy || die "Port 80/443 is owned by Caddy, but the caddy binary is unavailable."
      printf 'caddy'; return ;;
    nginx)
      have nginx || die "Port 80/443 is owned by nginx, but the nginx binary is unavailable."
      printf 'nginx'; return ;;
    mixed)
      die "Both Caddy and nginx appear to own public web ports; refusing to guess." ;;
    unknown)
      die "Port 80/443 is already owned by an unsupported process." ;;
    none) ;;
    *) die "Could not determine the public port owner safely." ;;
  esac

  if have caddy; then printf 'caddy'; return; fi
  if have nginx; then printf 'nginx'; return; fi
  printf 'caddy'
}

install_caddy(){
  have caddy && return 0
  have apt-get || die "Caddy is not installed and automatic installation currently requires apt."
  log "installing caddy"
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
    service_active "$service" && return 0
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
  ' "$CADDYFILE" > "$tmp"
  cat >> "$tmp" <<EOF

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
  run_logged apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=4 install -y --no-install-recommends certbot python3-certbot-nginx
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

  cat > "$NGINX_SITE" <<EOF
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
  caddy) configure_caddy ;;
  nginx) configure_nginx ;;
  *) die "No supported reverse proxy could be selected." ;;
esac

# First verify origin HTTPS directly. This distinguishes origin/proxy failures
# from Cloudflare edge configuration failures.
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
  curl -sSIL --max-time 10 "https://$DOMAIN/healthz" >&3 2>&1 || true
  die "Origin is healthy, but public HTTPS through Cloudflare is not."
fi

install -d -m 750 "$CONFIG_DIR"
printf '%s\n' "$DOMAIN" > "$CONFIG_DIR/public-domain"
chmod 640 "$CONFIG_DIR/public-domain"

MUTATED=0
say ""
ok "https://$DOMAIN is live."
say "Cloudflare: Proxy ON · SSL/TLS Full (strict)"
