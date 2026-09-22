#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

DOMAIN="${1:-}"
APP_HOST="127.0.0.1"
CONFIG_DIR="${CHATGPT_EXPORT_CONFIG_DIR:-/etc/chatgpt-export}"
SERVICE_ENV="$CONFIG_DIR/service.env"
BACKUP_DIR=""
PROXY=""
CADDYFILE="/etc/caddy/Caddyfile"
NGINX_SITE=""

say(){ printf '%s\n' "$*"; }
ok(){ say "✓ $*"; }
warn(){ say "! $*"; }
die(){ say "✗ $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<'EOF'
Usage:
  sudo bash setup-domain.sh chatgpt.example.com

This configures HTTPS reverse proxying to the local ChatGPT-Export service.
Cloudflare recommendation: Proxy ON + SSL/TLS mode Full (strict).
EOF
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run with sudo/root."
[[ -n "$DOMAIN" ]] || { usage; exit 2; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || die "Invalid domain."
[[ "$DOMAIN" == *.* ]] || die "Use a fully-qualified domain name."

[[ -f "$SERVICE_ENV" ]] || die "ChatGPT-Export is not installed: $SERVICE_ENV not found."
set -a
# shellcheck disable=SC1090
. "$SERVICE_ENV"
set +a
APP_PORT="${CHATGPT_EXPORT_PORT:-8788}"

curl -fsS --max-time 3 "http://$APP_HOST:$APP_PORT/healthz" >/dev/null ||
  die "ChatGPT-Export is not healthy on $APP_HOST:$APP_PORT."

if ! getent ahosts "$DOMAIN" >/dev/null 2>&1; then
  die "DNS for $DOMAIN does not resolve yet. Check the Cloudflare record and retry."
fi
ok "Application and DNS preflight passed."

cleanup(){
  local rc=$?
  if (( rc != 0 )) && [[ -n "$BACKUP_DIR" ]]; then
    warn "Domain setup failed; restoring previous proxy configuration."
    if [[ "$PROXY" == "caddy" ]]; then
      [[ -f "$BACKUP_DIR/Caddyfile" ]] && cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE"
      caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || true
      systemctl reload caddy >/dev/null 2>&1 || true
    elif [[ "$PROXY" == "nginx" ]]; then
      [[ -n "$NGINX_SITE" ]] && rm -f "$NGINX_SITE" "/etc/nginx/sites-enabled/$(basename "$NGINX_SITE")"
      [[ -f "$BACKUP_DIR/site.conf" && -n "$NGINX_SITE" ]] && {
        cp -a "$BACKUP_DIR/site.conf" "$NGINX_SITE"
        ln -sfn "$NGINX_SITE" "/etc/nginx/sites-enabled/$(basename "$NGINX_SITE")"
      }
      nginx -t >/dev/null 2>&1 || true
      systemctl reload nginx >/dev/null 2>&1 || true
    fi
  fi
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] && rm -rf "$BACKUP_DIR"
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

install_caddy_debian(){
  have apt-get || die "No supported reverse proxy is installed and automatic Caddy installation currently requires apt."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https curl gpg ca-certificates >/dev/null
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key |
      gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt       -o /etc/apt/sources.list.d/caddy-stable.list
  fi
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  apt-get update -qq
  apt-get install -y caddy >/dev/null
}

configure_caddy(){
  PROXY="caddy"
  install -d -m 755 /etc/caddy
  touch "$CADDYFILE"
  BACKUP_DIR="$(mktemp -d /tmp/chatgpt-export-domain.XXXXXX)"
  cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile"

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

  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null
  systemctl enable --now caddy >/dev/null
  systemctl reload caddy
  ok "Caddy configuration activated."
}

install_certbot_debian(){
  have certbot && return 0
  have apt-get || die "nginx detected but certbot is missing; automatic certificate setup currently requires apt."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends certbot python3-certbot-nginx >/dev/null
}

configure_nginx(){
  PROXY="nginx"
  install_certbot_debian
  local safe
  safe="$(printf '%s' "$DOMAIN" | tr '.-' '__')"
  NGINX_SITE="/etc/nginx/sites-available/chatgpt-export-$safe.conf"
  BACKUP_DIR="$(mktemp -d /tmp/chatgpt-export-domain.XXXXXX)"
  [[ -f "$NGINX_SITE" ]] && cp -a "$NGINX_SITE" "$BACKUP_DIR/site.conf"

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
  ln -sfn "$NGINX_SITE" "/etc/nginx/sites-enabled/$(basename "$NGINX_SITE")"
  nginx -t >/dev/null
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx

  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos     --register-unsafely-without-email --redirect >/dev/null

  nginx -t >/dev/null
  systemctl reload nginx
  ok "nginx HTTPS configuration activated."
}

if have caddy; then
  configure_caddy
elif have nginx; then
  configure_nginx
else
  install_caddy_debian
  configure_caddy
fi

ok "Reverse proxy is configured."

verified=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 "https://$DOMAIN/healthz" | grep -q '"ok":true'; then
    verified=1
    break
  fi
  sleep 2
done

if (( verified == 0 )); then
  die "HTTPS verification for https://$DOMAIN/healthz failed. Check Cloudflare Proxy and SSL/TLS settings."
fi

install -d -m 750 "$CONFIG_DIR"
printf '%s\n' "$DOMAIN" > "$CONFIG_DIR/public-domain"
chmod 640 "$CONFIG_DIR/public-domain"

say ""
ok "https://$DOMAIN is live."
say "Cloudflare: keep Proxy ON and SSL/TLS mode Full (strict)."
