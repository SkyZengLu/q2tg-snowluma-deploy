#!/usr/bin/env bash
# =============================================================================
# SnowLuma 公网暴露（nginx 反代 + TLS + Basic Auth）—— 需要 root
#
# 前提：已执行 install-snowluma.sh，WebUI 在 127.0.0.1:5099 监听。
#
# 用法（二选一）：
#   有域名：sudo bash expose-snowluma.sh --domain bot.example.com [--tls certbot|selfsigned]
#   仅 IP ：sudo bash expose-snowluma.sh --ip 你的服务器IP [--port 8443]
#
# 可选：--auth-user admin --auth-pass '强密码'   （不传则随机生成并打印）
# 安全组：域名方案放行 443 + 80；IP 方案放行所配端口。
# 设计：只反代 WebUI(5099)。noVNC(6081)/OneBot(3000,3001) 保持仅本机。
# =============================================================================
set -Eeuo pipefail

MODE=""            # domain | ip
DOMAIN=""
IP=""
PORT=8443
TLS_MODE="selfsigned"   # selfsigned | certbot
AUTH_USER="admin"
AUTH_PASS=""
UPSTREAM="127.0.0.1:5099"
SITE_NAME="snowluma"
CRED_FILE="/opt/snowluma/credentials.txt"

log()  { printf '\033[1;32m[expose]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[expose][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[expose][fail]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    MODE=domain; DOMAIN="${2:?}"; shift 2 ;;
    --ip)        MODE=ip; IP="${2:?}"; shift 2 ;;
    --port)      PORT="${2:?}"; shift 2 ;;
    --tls)       TLS_MODE="${2:?}"; shift 2 ;;
    --auth-user) AUTH_USER="${2:?}"; shift 2 ;;
    --auth-pass) AUTH_PASS="${2:?}"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "必须 root：sudo bash $0 ..."
[[ -n $MODE ]] || die "必须指定 --domain 或 --ip"
command -v nginx >/dev/null || die "未安装 nginx"
install -d -m 0755 /etc/nginx/ssl

if ! ss -tln 2>/dev/null | grep -q "127.0.0.1:5099"; then
  warn "127.0.0.1:5099 没有监听——SnowLuma 可能还没启动，先把 install-snowluma.sh 跑完"
fi

# ---------- 证书 ----------
CERT="" KEY="" LISTEN_LINE="" SERVER_NAME="" REDIRECT_BLOCK="" URL=""

make_selfsigned() {
  local cn="$1" crt="/etc/nginx/ssl/${SITE_NAME}.crt" key="/etc/nginx/ssl/${SITE_NAME}.key"
  if [[ -f $crt && -f $key ]]; then log "复用已有自签证书 $crt"; return 0; fi
  if [[ $MODE == ip ]]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$key" -out "$crt" -subj "/CN=${IP}" \
      -addext "subjectAltName=IP:${IP}" >/dev/null 2>&1
  else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$key" -out "$crt" -subj "/CN=${cn}" \
      -addext "subjectAltName=DNS:${cn}" >/dev/null 2>&1
  fi
  chmod 600 "$key"; chmod 644 "$crt"
  log "自签证书：$crt"
}

issue_certbot() {
  command -v certbot >/dev/null || apt-get install -y certbot || die "certbot 安装失败"
  install -d -m 0755 /var/www/letsencrypt
  local acme_conf=/etc/nginx/sites-available/${SITE_NAME}-acme.conf
  cat > "$acme_conf" <<EOF
# 临时 ACME 校验用
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
}
EOF
  ln -sfn "$acme_conf" /etc/nginx/sites-enabled/${SITE_NAME}-acme.conf
  nginx -t && systemctl reload nginx
  log "为 ${DOMAIN} 申请 Let's Encrypt 证书..."
  certbot certonly --webroot -w /var/www/letsencrypt -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    || die "证书申请失败：域名是否已 A 记录到本机？安全组 80 是否放行？"
  rm -f /etc/nginx/sites-enabled/${SITE_NAME}-acme.conf "$acme_conf"
  nginx -t && systemctl reload nginx || true
}

if [[ $MODE == ip ]]; then
  make_selfsigned ""
  CERT=/etc/nginx/ssl/${SITE_NAME}.crt; KEY=/etc/nginx/ssl/${SITE_NAME}.key
  LISTEN_LINE="listen ${PORT} ssl;"
  SERVER_NAME="$IP"
  URL="https://${IP}:${PORT}/"
else
  SERVER_NAME="$DOMAIN"; URL="https://${DOMAIN}/"
  if [[ $TLS_MODE == certbot ]]; then
    issue_certbot
    CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  else
    make_selfsigned "$DOMAIN"
    CERT=/etc/nginx/ssl/${SITE_NAME}.crt; KEY=/etc/nginx/ssl/${SITE_NAME}.key
  fi
  LISTEN_LINE="listen 443 ssl;
    listen [::]:443 ssl;"
  REDIRECT_BLOCK="server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}"
fi

# ---------- Basic Auth ----------
if [[ -z $AUTH_PASS ]]; then
  AUTH_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
fi
HASH="$(openssl passwd -apr1 "$AUTH_PASS")"
printf '%s:%s\n' "$AUTH_USER" "$HASH" > /etc/nginx/.htpasswd-${SITE_NAME}
chmod 640 /etc/nginx/.htpasswd-${SITE_NAME}
chown root:www-data /etc/nginx/.htpasswd-${SITE_NAME}

# ---------- 站点 ----------
CONF=/etc/nginx/sites-available/${SITE_NAME}.conf
cat > "$CONF" <<EOF
# 由 expose-snowluma.sh 生成 $(date -Is)
${REDIRECT_BLOCK}
server {
    ${LISTEN_LINE}
    server_name ${SERVER_NAME};

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;

    auth_basic           "snowluma";
    auth_basic_user_file /etc/nginx/.htpasswd-${SITE_NAME};

    client_max_body_size 100m;
    server_tokens off;

    location / {
        proxy_pass http://${UPSTREAM};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}
EOF
ln -sfn "$CONF" /etc/nginx/sites-enabled/${SITE_NAME}.conf
nginx -t || die "nginx 配置校验失败，已保留文件供排查：$CONF"
systemctl reload nginx
log "nginx 已 reload：$CONF"

# ---------- 宿主机防火墙 ufw ----------
open_firewall() {
  command -v ufw >/dev/null || { warn "未装 ufw，跳过"; return 0; }
  ufw status 2>/dev/null | grep -q 'Status: active' || { log "ufw 未启用，跳过"; return 0; }
  local ports=()
  if [[ $MODE == ip ]]; then ports=("$PORT"); else ports=(80 443); fi
  local p
  for p in "${ports[@]}"; do
    ufw allow "${p}/tcp" >/dev/null && log "ufw 放行 ${p}/tcp"
  done
}
open_firewall

# ---------- 凭据落盘 ----------
install -d -m 0755 /opt/snowluma 2>/dev/null || true
{
  echo
  echo "# 公网入口（$(date -Is)）"
  echo "URL=$URL"
  echo "BASIC_AUTH_USER=$AUTH_USER"
  echo "BASIC_AUTH_PASS=$AUTH_PASS"
  echo "# WebUI 自身登录：admin + credentials.txt 里的 WEBUI_ADMIN_PASSWORD"
  echo "# 证书：$CERT"
} >> "$CRED_FILE"
chmod 600 "$CRED_FILE"

cat <<EOF

================ 公网入口就绪 ================
 URL        : $URL
 Basic Auth : $AUTH_USER / $AUTH_PASS
 凭据汇总   : $CRED_FILE

 仍需你在云控制台确认安全组：
   $( [[ $MODE == ip ]] && echo "放行 TCP ${PORT}" || echo "放行 TCP 443（80 已用于证书/跳转）" )
==============================================
EOF
warn "noVNC(6081)/OneBot(3000,3001) 未暴露，保持仅 127.0.0.1——这是有意的安全设计。"
warn "首次扫码请用 SSH 隧道：ssh -L 6081:127.0.0.1:6081 -L 5099:127.0.0.1:5099 user@你的服务器IP"
