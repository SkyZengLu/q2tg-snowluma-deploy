#!/usr/bin/env bash
# =============================================================================
# SnowLuma 一键安装（Ubuntu 22.04 / Debian 12，需要 root）
#   官方文档：https://snowluma.github.io/zh/docs/guide/deploy/docker
#
# 做的事：
#   1. 装 Docker Engine + compose 插件（阿里云 docker-ce 源，可按需改源）
#   2. 配 Docker Hub 镜像加速（大陆网络下 registry-1.docker.io 不通）
#   3. 生成随机 VNC 密码，写好 compose 与 .env
#   4. 拉官方镜像 motricseven7/snowluma:latest（自动走镜像前缀回退）
#   5. 仅绑定 127.0.0.1 启动，导出一次性 WebUI 管理员密码
#
# 用法：
#   sudo bash install-snowluma.sh
# 幂等：重复执行不会删数据卷、不会重新生成密码、不会重建已运行的容器。
# =============================================================================
set -Eeuo pipefail

APP_DIR=/opt/snowluma
CONTAINER=snowluma
IMAGE=motricseven7/snowluma:latest
MIRRORS=(docker.1ms.run docker.m.daocloud.io docker.xuanyuan.me)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m[snowluma]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[snowluma][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[snowluma][fail]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "必须用 root 运行：sudo bash $0"

# ---------- 1. Docker --------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker 已安装：$(docker --version)"
    return 0
  fi
  log "安装 Docker Engine（阿里云源）..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://mirrors.aliyun.com/docker-ce/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

configure_mirrors() {
  local f=/etc/docker/daemon.json
  install -d -m 0755 /etc/docker
  if [[ -f $f ]]; then
    warn "$f 已存在，跳过镜像加速配置（如拉取超时，请手动合并 registry-mirrors）"
    return 0
  fi
  log "写入 registry-mirrors 加速..."
  cat > "$f" <<'JSON'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://docker.xuanyuan.me"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
  systemctl restart docker
  sleep 3
}

# ---------- 2. 配置目录 ------------------------------------------------------
prepare_dir() {
  install -d -m 0755 "$APP_DIR"
  cp -f "$SRC_DIR/../deploy/snowluma/docker-compose.yml" "$APP_DIR/docker-compose.yml"

  if [[ ! -f $APP_DIR/.env ]]; then
    local vnc_pass
    vnc_pass="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
    cat > "$APP_DIR/.env" <<EOF
# 由 install-snowluma.sh 于 $(date -Is) 生成
TZ=Asia/Shanghai
SNOWLUMA_IMAGE=$IMAGE
SNOWLUMA_CONTAINER=$CONTAINER
VNC_PASSWD=$vnc_pass
SNOWLUMA_UID=1000
SNOWLUMA_GID=1000
SNOWLUMA_WEBUI_HOST_PORT=5099
NOVNC_PORT=6081
ONEBOT_HTTP_PORT=3000
ONEBOT_WS_PORT=3001
SNOWLUMA_LOG_LEVEL=info
EOF
    chmod 600 "$APP_DIR/.env"
    log "已生成 .env（含随机 VNC 密码）"
  else
    log "复用已有 .env"
  fi

  # 与 Q2TG 共享的网络和卷（Q2TG compose 以 external 引用，先建好）
  docker network create qq-bridge 2>/dev/null || true
  docker volume create q2tg-cache 2>/dev/null || true
}

# ---------- 3. 拉镜像 --------------------------------------------------------
pull_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "本地已有镜像 $IMAGE"
    return 0
  fi
  local m
  for m in "${MIRRORS[@]}"; do
    log "尝试镜像前缀：$m"
    if docker pull "$m/$IMAGE" >/dev/null 2>&1; then
      docker tag "$m/$IMAGE" "$IMAGE"
      log "拉取成功（$m）"
      return 0
    fi
    warn "$m 拉取失败，换下一个"
  done
  log "尝试直连 Docker Hub..."
  docker pull "$IMAGE" || die "镜像拉取全部失败。请在云控制台配置镜像加速后重跑本脚本。"
}

# ---------- 4. 启动 ----------------------------------------------------------
start_container() {
  cd "$APP_DIR"
  docker compose up -d
  log "等待容器就绪..."
  local i
  for i in $(seq 1 40); do
    if docker logs "$CONTAINER" 2>&1 | grep -qE '临时密码|initial credentials'; then break; fi
    sleep 3
  done
  docker compose ps
}

collect_credentials() {
  local out="$APP_DIR/credentials.txt"
  local vnc webui
  vnc="$(grep -E '^VNC_PASSWD=' "$APP_DIR/.env" | cut -d= -f2-)"
  webui="$(docker logs "$CONTAINER" 2>&1 \
    | sed -nE 's/.*(临时密码: |initial credentials: user=admin password=)([^[:space:]]+).*/\2/p' \
    | tail -n 1 || true)"

  {
    echo "# SnowLuma 凭据（$(date -Is)）"
    echo "# noVNC 用（SSH 隧道到本机后访问 http://127.0.0.1:6081/vnc.html）"
    echo "VNC_PASSWD=$vnc"
    echo
    echo "# WebUI 初始管理员密码（仅全新数据卷首启打印一次）"
    echo "WEBUI_ADMIN_PASSWORD=${webui:-<日志里未找到，可能已初始化过：docker logs $CONTAINER | grep -E \"临时密码|initial credentials\">}"
  } > "$out"
  chmod 600 "$out"

  echo
  log "================ 完成 ================"
  echo " WebUI    : http://127.0.0.1:5099/  (用户 admin)"
  echo " noVNC    : http://127.0.0.1:6081/vnc.html"
  echo " OneBot   : http://127.0.0.1:3000  / ws://127.0.0.1:3001"
  echo " 凭据文件 : $out"
  echo " 数据卷   : qq-gateway-data / qq-client-config / qq-client-data（升级勿删）"
  echo "======================================"
  echo
  warn "以上端口都只绑 127.0.0.1。公网访问请按 README 第九节配置反向代理 + 鉴权，"
  warn "不要把 6081/5099 裸放公网。"
}

main() {
  install_docker
  configure_mirrors
  prepare_dir
  pull_image
  start_container
  collect_credentials
}

main "$@"
